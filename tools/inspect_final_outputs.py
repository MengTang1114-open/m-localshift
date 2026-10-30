#!/usr/bin/env python3
from pathlib import Path
import json,subprocess,math,argparse
from PIL import Image,ImageChops,ImageStat
from pypdf import PdfReader
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--matrix',default='work/final-matrix/results.json');parser.add_argument('--tools',default='work/final-tools/results.json');parser.add_argument('--report',default='Evidence/output-semantics.json');args=parser.parse_args()
resources=root/'LocalShift.app/Contents/Resources'
ff=resources/'bin/ffmpeg';probe=resources/'bin/ffprobe'
report=json.loads((root/args.tools).read_text());cases=report['cases'];rows=[]
def check(name,condition,detail=None):rows.append({'name':name,'passed':bool(condition),'detail':detail})
def outputs(index):return [Path(p) for p in cases[index]['outputs']]
def one(index):return outputs(index)[0]
def media(p):return json.loads(subprocess.check_output([str(probe),'-v','error','-show_streams','-show_format','-of','json',str(p)]))
def duration(p):return float(media(p)['format']['duration'])
# Validate the requested container, including directory outputs such as PDF page images.
jobs=json.loads((root/'work/functional/matrix-jobs.json').read_text());actual=json.loads((root/args.matrix).read_text())['cases'];wrong=[]
for job,case in zip(jobs,actual):
 target=job['option'].removeprefix('format_')
 if not case.get('passed') or not case.get('outputs'):wrong.append(case['name']);continue
 for raw in case['outputs']:
  p=Path(raw)
  relevant=[p] if p.is_file() else [f for f in p.rglob('*') if f.is_file() and f.suffix=='.'+target]
  if not relevant or any(f.suffix.lower()!='.'+target for f in relevant):wrong.append(case['name'])
check('Matrix has all 275 unique requested directions',len(jobs)==275 and len(actual)==275 and len({c['name'] for c in actual})==275 and [c['name'] for c in actual]==[j['name'] for j in jobs] and all(c.get('passed') for c in actual))
check('All275 requested target containers match actual outputs',not wrong,wrong)
check('Target-size JPEG is at most40000bytes',one(0).stat().st_size<=40000,one(0).stat().st_size)
for i in [8,11,31]:check(cases[i]['name']+' exact160x90',Image.open(one(i)).size==(160,90),Image.open(one(i)).size)
for i in [9,12]:check(cases[i]['name']+' preserves source dimensions',Image.open(one(i)).size==(320,180),Image.open(one(i)).size)
check('Frame adds10px padding on every side',Image.open(one(10)).size==(340,200),Image.open(one(10)).size)
base=Image.open(root/'work/functional/fixtures/sample.png').convert('RGB').resize((160,90))
for i in [8,9,12]:
 value=sum(ImageStat.Stat(ImageChops.difference(base,Image.open(one(i)).convert('RGB'))).mean)
 check(cases[i]['name']+' changes actual pixels',value>0.1,value)
muted=media(one(14));check('Mute video contains no audio stream',not any(s['codec_type']=='audio' for s in muted['streams']))
for i in [15,28]:check(cases[i]['name']+' actual0.6s range',abs(duration(one(i))-.6)<.12,duration(one(i)))
check('Audio channels outputs mono',next(s for s in media(one(29))['streams'] if s['codec_type']=='audio')['channels']==1)
check('Video speed changes actual duration',abs(duration(one(22))-duration(root/'work/functional/fixtures/sample.mp4')/1.5)<.15,duration(one(22)))
check('Join videos keeps both durations',abs(duration(one(26))-sum(duration(root/'work/functional/fixtures'/('sample.'+x)) for x in ['mp4','mov']))<.2,duration(one(26)))
check('Video crop preserves normalized224x126 region',[(s.get('width'),s.get('height')) for s in media(one(21))['streams'] if s['codec_type']=='video']==[(224,126)])
check('Visualizer has both audio and video',set(s['codec_type'] for s in media(one(27))['streams'])=={'audio','video'})
check('Snapshots produce two actual images',len(outputs(23))==2 and all(Image.open(p).width>0 for p in outputs(23)))
check('Split video produces3 actual segments',len(outputs(24))==3 and all(duration(p)>0 for p in outputs(24)))
organizer=PdfReader(one(17));check('PDF organizer duplicates/reorders pages',len(organizer.pages)==3 and 'Second page' in organizer.pages[0].extract_text() and 'LocalShift' in organizer.pages[1].extract_text() and 'LocalShift' in organizer.pages[2].extract_text())
check('PDF absolute rotation follows output index',[p.rotation for p in organizer.pages]==[90,0,0],[p.rotation for p in organizer.pages])
check('PDF split produces3 selected pages',len(outputs(16))==3 and all(len(PdfReader(p).pages)==1 for p in outputs(16)))
check('Images to PDF preserves input count',len(PdfReader(one(19)).pages)==2)
check('PDF merge preserves4 pages',len(PdfReader(one(20)).pages)==4)
check('PDF metadata title/author roundtrip',PdfReader(one(7)).metadata.title=='本地转换' and PdfReader(one(7)).metadata.author=='LocalShift Test')
for i in [5,6]:
 tags=media(one(i))['format'].get('tags',{});tags={k.lower():v for k,v in tags.items()}
 check(cases[i]['name']+' title/author roundtrip',tags.get('title')=='本地转换' and (tags.get('author')=='LocalShift Test' or tags.get('artist')=='LocalShift Test'),tags)
# Measured loudness must actually reach the requested -18LUFS on the generated tone.
p=subprocess.run([str(ff),'-hide_banner','-i',str(one(13)),'-af','loudnorm=I=-18:print_format=json','-f','null','-'],capture_output=True,text=True)
try:
 loudness=json.JSONDecoder().raw_decode(p.stderr[p.stderr.rindex('{'):])[0];measured=float(loudness['input_i']);check('Audio normalization measured near-18LUFS',abs(measured+18)<1.2,measured)
except Exception as e:check('Audio normalization measurable',False,str(e))
result={'passed':sum(r['passed'] for r in rows),'failed':sum(not r['passed'] for r in rows),'cases':rows,'scope':'Independent structural, duration, channel, metadata, pixel and loudness readback of final outputs'}
(root/args.report).write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps({"passed":result["passed"],"failed":result["failed"],"failures":[r for r in rows if not r["passed"]]},ensure_ascii=False));raise SystemExit(1 if result['failed'] else 0)
