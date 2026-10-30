from pathlib import Path
import json,subprocess,os,sys
import numpy as np
project=Path(__file__).resolve().parents[3];root=project/'work/release-audit/media-fixes';ff=str(project/'LocalShift.app/Contents/Resources/bin/ffmpeg');fp=str(project/'LocalShift.app/Contents/Resources/bin/ffprobe')
source=root/'fixtures/distinct-stereo.mkv'
if not source.exists():
 subprocess.run([ff,'-nostdin','-v','error','-y','-i',str(root/'fixtures/multi.mkv'),'-f','lavfi','-i','sine=frequency=880:sample_rate=48000:duration=1.6','-f','lavfi','-i','sine=frequency=1320:sample_rate=48000:duration=1.6','-filter_complex','[1:a][2:a]amerge=inputs=2[stereo]','-map','0:v:0','-map','0:a:0','-map','[stereo]','-c:v','copy','-c:a','pcm_s16le','-metadata:s:a:0','language=eng','-metadata:s:a:1','language=deu',str(source)],check=True)
jobs=[]
for fmt in ['mp4','mov','mkv','webm','avi','wmv']:
 jobs.append(dict(name='distinct-'+fmt,option='format_'+fmt,inputs=[str(source)]))
for option in ['compress','trimVideo','changeVideoSpeed','splitVideo','cropVideo','redactVideo','joinVideos']:
 job=dict(name='distinct-'+option,option=option,inputs=[str(source)]*(2 if option=='joinVideos' else 1),start=.25,end=1.25,crop=[.25,.25,.5,.5])
 if option=='redactVideo':job['redaction']=[.1,.1,.2,.2]
 jobs.append(job)
jobsfile=root/'stereo-jobs.json';jobsfile.write_text(json.dumps(jobs,indent=2))
phase=root/sys.argv[1];output=phase/'stereo-outputs'
env=os.environ.copy();env['LOCALSHIFT_RESOURCE_DIR']=str(project/'LocalShift.app/Contents/Resources')
if not (output/'runner-report.json').exists():
 with (phase/'stereo-run.log').open('w') as log:subprocess.run([str(phase/'media-tests'),str(jobsfile),str(output)],check=True,env=env,stdout=log,stderr=subprocess.STDOUT)
report=json.loads((output/'runner-report.json').read_text());rows=[]
for case in report['cases']:
 checks=[]
 if not case['success']:checks.append(dict(name='engine-succeeded',passed=False,error=case.get('error')))
 else:
  checks.append(dict(name='source-bytes-unchanged',passed=case['sources_unchanged']))
  for path in case['outputs']:
   p=json.loads(subprocess.check_output([fp,'-v','error','-show_streams','-of','json',path]));tracks=[s for s in p['streams'] if s['codec_type']=='audio'];checks.append(dict(name='all-tracks-preserved',passed=len(tracks)==2,actual=len(tracks)))
   if len(tracks)<2:continue
   checks.append(dict(name='second-track-stays-stereo',passed=tracks[1]['channels']==2,actual=tracks[1]['channels']))
   raw=subprocess.check_output([ff,'-v','error','-i',path,'-ss','0.1','-t','0.2','-map','0:a:1','-ar','48000','-ac','2','-f','f32le','pipe:1']);samples=np.frombuffer(raw,dtype='<f4').reshape(-1,2)
   for channel,expected in enumerate([880,1320]):
    spectrum=np.abs(np.fft.rfft(samples[:,channel]*np.hanning(len(samples))));actual=int(np.argmax(spectrum)*48000/len(samples));checks.append(dict(name='independent-stereo-channel-content',channel=channel,passed=abs(actual-expected)<8,expected_hz=expected,actual_hz=actual))
   if case['name'].endswith(('trimVideo','changeVideoSpeed','splitVideo')):
    expected=1 if case['name'].endswith('trimVideo') else .8 if case['name'].endswith('changeVideoSpeed') else [.5,.5,.6][case['outputs'].index(path)]
    raw=subprocess.check_output([ff,'-v','error','-i',path,'-map','0:a:1','-ar','48000','-ac','2','-f','f32le','pipe:1']);actual=len(raw)/8/48000;checks.append(dict(name='filter-applied-to-stereo-track',passed=abs(actual-expected)<.12,expected_seconds=expected,actual_seconds=actual))
 rows.append(dict(name=case['name'],passed=all(c['passed'] for c in checks),checks=checks))
result=dict(passed=sum(c['passed'] for c in rows),failed=sum(not c['passed'] for c in rows),cases=rows);(phase/'stereo-validation.json').write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='cases'}))
for row in rows:
 if not row['passed']:print(row)
