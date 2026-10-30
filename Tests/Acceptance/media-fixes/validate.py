from pathlib import Path
from fractions import Fraction
from PIL import ImageColor
import json,subprocess,math,sys
import numpy as np
project=Path(__file__).resolve().parents[3];root=project/'work/release-audit/media-fixes'
phase=Path(sys.argv[1]);ff=str(project/'LocalShift.app/Contents/Resources/bin/ffmpeg');fp=str(project/'LocalShift.app/Contents/Resources/bin/ffprobe')
jobs={j['name']:j for j in json.loads((root/'jobs.json').read_text())};runner=json.loads((phase/'runner-report.json').read_text());rows=[]
def probe(path):return json.loads(subprocess.check_output([fp,'-v','error','-show_streams','-show_format','-of','json',path]))
def video_info(p):return next(s for s in p['streams'] if s['codec_type']=='video')
def ratio(value):
 try:return float(Fraction(value.replace(':','/')))
 except:return 0

def frame(path,time,width,height):
 b=subprocess.check_output([ff,'-nostdin','-v','error','-i',path,'-ss',str(time),'-frames:v','1','-pix_fmt','rgb24','-f','rawvideo','pipe:1'])
 return np.frombuffer(b,dtype=np.uint8).reshape(height,width,3)
def pcm(path,index,start=.1,duration=.2):
 b=subprocess.check_output([ff,'-nostdin','-v','error','-i',path,'-ss',str(start),'-t',str(duration),'-map',f'0:a:{index}','-ac','1','-ar','48000','-f','f32le','pipe:1'])
 return np.frombuffer(b,dtype='<f4')
def frequency(samples):
 if not len(samples):return 0
 spectrum=np.abs(np.fft.rfft(samples*np.hanning(len(samples))));return float(np.argmax(spectrum)*48000/len(samples))
def check(row,name,passed,**details):row['checks'].append(dict(name=name,passed=bool(passed),**details))
for result in runner['cases']:
 name=result['name'];job=jobs[name];row=dict(name=name,checks=[])
 if name=='tracks-join-conflict':
  check(row,'language-order-conflict-is-explicit',not result['success'],error=result.get('error'));row['passed']=all(x['passed'] for x in row['checks']);rows.append(row);continue
 if not result['success']:
  check(row,'engine-succeeded',False,error=result.get('error'));row['passed']=False;rows.append(row);continue
 check(row,'source-bytes-unchanged',result.get('sources_unchanged',False))
 for out_index,path in enumerate(result['outputs']):
  p=probe(path);v=video_info(p) if any(s['codec_type']=='video' for s in p['streams']) else None
  if v is not None:
   width,height=int(v['width']),int(v['height'])
   if name.startswith(('mask-','blur-')):
    x,y,w,h=job['redaction'];x0=math.floor(x*width+1e-7);y0=math.floor(y*height+1e-7);x1=math.ceil((x+w)*width-1e-7);y1=math.ceil((y+h)*height-1e-7)
    pixels=frame(path,.4,width,height)[y0:y1,x0:x1,:];lo,hi=int(pixels.min()),int(pixels.max())
    valid=(lo>=30 and hi<=225) if name.startswith('blur-') else hi<=48
    check(row,'full-selected-rectangle-covered',valid,rectangle=[x0,y0,x1,y1],minimum=lo,maximum=hi)
    if name=='mask-timed':
     for time in [.1,.8]:
      before=frame(path,time,width,height)[y0:y1,x0:x1,:];check(row,'outside-selected-time-remains-white',int(before.min())>=235,time=time,minimum=int(before.min()))
   if name.startswith('sar-'):
    expected=4/3 if name in ['sar-crop-exact','sar-crop-default'] else 8/3
    actual=width/height if name=='sar-snapshot' else ratio(v.get('display_aspect_ratio','')) or width/height*ratio(v.get('sample_aspect_ratio','1:1'))
    check(row,'display-aspect-ratio',abs(actual-expected)<=.025,expected=expected,actual=actual,width=width,height=height,sar=v.get('sample_aspect_ratio'))
   if name.startswith('fast-gif-') or name in ['still-gif','variable-gif']:
    duration=float(p.get('format',{}).get('duration') or v.get('duration') or 0);expected=.1 if name.startswith('fast-gif-') else 1
    check(row,'GIF-total-duration',abs(duration-expected)<=.012,expected=expected,actual=duration)
    raw=subprocess.check_output([ff,'-nostdin','-v','error','-i',path,'-map','0:v:0','-fps_mode','passthrough','-vf','scale=1:1','-pix_fmt','rgb24','-f','rawvideo','pipe:1']);pixels=np.frombuffer(raw,dtype=np.uint8).reshape(-1,3)
    if name.startswith('fast-gif-'):
     expected_colors=[ImageColor.getrgb(c) for c in json.loads((root/'fixture-spec.json').read_text())['fast_colors']]
     count_ok=len(pixels)==10;errors=[int(np.abs(pixels[i].astype(int)-np.array(expected_colors[i])).max()) for i in range(min(10,len(pixels)))]
     check(row,'GIF-every-10ms-frame-color',count_ok and max(errors or [999])<25,frames=len(pixels),maximum_color_errors=errors)
    if name=='variable-gif':
     samples=[(10,(255,0,0)),(35,(0,255,0)),(80,(0,0,255))]
     errors=[int(np.abs(pixels[index].astype(int)-np.array(color)).max()) if index<len(pixels) else 999 for index,color in samples]
     check(row,'GIF-variable-delays-retained',len(pixels)==100 and max(errors)<25,frames=len(pixels),errors=errors)
  if name.startswith('tracks-'):
   tracks=[s for s in p['streams'] if s['codec_type']=='audio'];expected=0 if name=='tracks-muteVideo' else 1 if name=='tracks-extract' else 2
   check(row,'audio-track-count',len(tracks)==expected,expected=expected,actual=len(tracks),tags=[s.get('tags',{}) for s in tracks],channels=[s.get('channels') for s in tracks])
   for index in range(min(expected,len(tracks))):
    start=.05 if job['option']=='splitVideo' else .1
    samples=pcm(path,index,start,.2);actual=frequency(samples);freq=440 if index==0 else 880
    if name=='tracks-join-missing' and index==1:
     rms=float(np.sqrt(np.mean(samples**2))) if len(samples) else 0;check(row,'missing-initial-track-is-silent',rms<.001,rms=rms)
     samples=pcm(path,index,1.8,.2);actual=frequency(samples)
    check(row,'track-content-frequency',abs(actual-freq)<8,index=index,expected_hz=freq,actual_hz=actual)
    if name=='tracks-join-silent':
     samples=pcm(path,index,1.8,.2);rms=float(np.sqrt(np.mean(samples**2))) if len(samples) else 999;check(row,'silent-joined-file-has-silence-on-every-track',rms<.001,index=index,rms=rms)
    if job['option'] in ['trimVideo','changeVideoSpeed','splitVideo']:
     expected_duration=1 if job['option']=='trimVideo' else .8 if job['option']=='changeVideoSpeed' else [.5,.5,.6][out_index]
     samples=pcm(path,index,0,5);duration=len(samples)/48000;check(row,'filter-applies-to-each-audio-track',abs(duration-expected_duration)<.12,index=index,expected=expected_duration,actual=duration)
   if name=='tracks-compress-target':check(row,'target-bytes-not-exceeded',Path(path).stat().st_size<=60000,bytes=Path(path).stat().st_size)
  decode=subprocess.run([ff,'-nostdin','-v','error','-i',path,'-f','null','-'],capture_output=True,text=True)
  check(row,'complete-decode',decode.returncode==0,error=decode.stderr[-500:])
 row['passed']=all(x['passed'] for x in row['checks']);rows.append(row)
report={'phase':str(phase),'passed':sum(r['passed'] for r in rows),'failed':sum(not r['passed'] for r in rows),'cases':rows}
(phase/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='cases'},ensure_ascii=False))
for row in rows:
 if not row['passed']:print(row['name'],[x for x in row['checks'] if not x['passed']])
