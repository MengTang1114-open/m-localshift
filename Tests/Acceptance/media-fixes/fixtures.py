from pathlib import Path
from PIL import Image
import subprocess,json,os
project=Path(__file__).resolve().parents[3]
root=project/'work/release-audit/media-fixes';fixtures=root/'fixtures';fixtures.mkdir(parents=True,exist_ok=True)
ff=project/'LocalShift.app/Contents/Resources/bin/ffmpeg'
def run(args):subprocess.run([str(ff),'-nostdin','-v','error','-y',*args],check=True,capture_output=True)
def make(name,args):
 p=fixtures/name
 if not p.exists():run([*args,str(p)])
 return str(p)
white=make('white.mkv',['-f','lavfi','-i','color=white:s=160x120:r=30:d=1','-c:v','ffv1'])
im=Image.new('RGB',(160,120));im.putdata([(255,255,255) if (x+y)%2==0 else (0,0,0) for y in range(120) for x in range(160)]);im.save(fixtures/'checker.png')
checker=make('checker.mkv',['-loop','1','-i',str(fixtures/'checker.png'),'-t','1','-r','30','-c:v','ffv1'])
sar=make('sar.mkv',['-f','lavfi','-i','testsrc2=s=160x120:r=30:d=1.6','-vf','setsar=2/1','-c:v','ffv1'])
multi=make('multi.mkv',['-f','lavfi','-i','testsrc2=s=160x120:r=30:d=1.6','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=1.6','-f','lavfi','-i','sine=frequency=880:sample_rate=44100:duration=1.6','-map','0:v','-map','1:a','-map','2:a','-c:v','ffv1','-c:a','pcm_s16le','-ac:a:0','1','-ac:a:1','2','-metadata:s:a:0','language=eng','-metadata:s:a:0','title=English440','-metadata:s:a:1','language=deu','-metadata:s:a:1','title=German880','-disposition:a:0','default','-disposition:a:1','0'])
mono=make('mono.mkv',['-i',multi,'-map','0:v:0','-map','0:a:0','-c','copy'])
swapped=make('swapped.mkv',['-i',multi,'-map','0:v:0','-map','0:a:1','-map','0:a:0','-c','copy'])
colors=['red','lime','blue','yellow','magenta','cyan','white','orange','purple','gray']
frames=[Image.new('RGB',(160,120),c) for c in colors]
frames[0].save(fixtures/'fast.gif',save_all=True,append_images=frames[1:],duration=[10]*10,loop=0,optimize=False)
frames[:3][0].save(fixtures/'variable.gif',save_all=True,append_images=frames[1:3],duration=[200,300,500],loop=0,optimize=False)
frames[0].save(fixtures/'still.gif')
jobs=[]
def add(name,option,inputs,**kwargs):jobs.append(dict(name=name,option=option,inputs=inputs,**kwargs))
for name,rect in [('odd',[17/160,19/120,7/160,9/120]),('last-pixel',[159/160,119/120,1/160,1/120]),('first-pixel',[0,0,1/160,1/120]),('fractional',[17.25/160,19.25/120,.2/160,.2/120])]:
 add('mask-'+name,'redactVideo',[white],redaction=rect)
 add('blur-'+name,'redactVideo',[checker],redaction=rect,style='blur')
add('mask-timed','redactVideo',[white],redaction=[17/160,19/120,7/160,9/120],redactStart=.2,redactEnd=.7)
for fmt in ['mp4','mov','mkv','webm','avi','wmv']:
 add('sar-'+fmt,'format_'+fmt,[sar]);add('tracks-'+fmt,'format_'+fmt,[multi]);add('fast-gif-'+fmt,'format_'+fmt,[str(fixtures/'fast.gif')])
for option in ['compress','trimVideo','changeVideoSpeed','splitVideo','cropVideo','muteVideo','redactVideo']:
 kwargs=dict(start=.25,end=1.25,crop=[.25,.25,.5,.5])
 if option=='redactVideo':kwargs['redaction']=[.1,.1,.2,.2]
 add('tracks-'+option,option,[multi],**kwargs)
 add('sar-'+option,option,[sar],**kwargs)
add('tracks-extract','format_mp3',[multi]);add('sar-crop-exact','cropVideo',[sar],crop=[.25,.25,.5,.5],exactSize=True,width=80,height=60)
add('sar-crop-default','cropVideo',[sar]);add('sar-snapshot','videoSnapshots',[sar])
add('tracks-compress-target','compress',[multi],compressionMode='target',targetBytes=60000)
add('tracks-join','joinVideos',[multi,multi]);add('tracks-join-silent','joinVideos',[multi,white]);add('tracks-join-missing','joinVideos',[mono,multi]);add('tracks-join-conflict','joinVideos',[multi,swapped])
add('sar-join','joinVideos',[sar,sar])
add('still-gif','format_mp4',[str(fixtures/'still.gif')]);add('variable-gif','format_mp4',[str(fixtures/'variable.gif')])
(root/'jobs.json').write_text(json.dumps(jobs,indent=2));(root/'fixture-spec.json').write_text(json.dumps({'fast_colors':colors,'fast_delays_ms':[10]*10,'variable_delays_ms':[200,300,500],'sar_expected_dar':'8:3','multi_frequencies':[440,880],'root':str(root)},indent=2))
print(f'{len(jobs)} jobs ready; ffmpeg={ff}')
