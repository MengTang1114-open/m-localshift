#!/usr/bin/env python3
"""Verify pinned vendor downloads and actual local capabilities; never touches the app bundle."""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,zipfile
root=Path(__file__).resolve().parent
BASE='https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/'
EXPECTED={'ffmpeg':'c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924','ffprobe':'fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6'}
ENCODERS=['libx264','libvpx-vp9','wmv2','mpeg4','libmp3lame','pcm_s16le','pcm_s16be','flac','vorbis','libopus','wmav2','aac','libaom-av1','libwebp','png','mjpeg','tiff','bmp','gif']
FILTERS=['loudnorm','trim','setpts','atrim','asetpts','silenceremove','areverse','crop','scale','atempo','aeval','setsar','fps','split','palettegen','paletteuse','anullsrc','pad','aresample','apad','concat','showwaves','format','overlay','boxblur','drawbox','colorkey','null']
logs=root/'verification-logs';logs.mkdir(exist_ok=True)
smoke=root/'smoke';smoke.mkdir(exist_ok=True)
env={'PATH':'/usr/bin:/bin','HOME':str(root),'TMPDIR':'/tmp','LANG':'en_US.UTF-8'}
def run(label,args,timeout=45):
    r=subprocess.run([str(a) for a in args],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=env,timeout=timeout)
    (logs/(label+'.txt')).write_text(r.stdout)
    if r.returncode:raise RuntimeError(label+' failed: '+r.stdout[-1200:])
    return r.stdout
records={}
for name in EXPECTED:
    zpath=root/(name+'.zip');digest=hashlib.sha256(zpath.read_bytes()).hexdigest()
    if digest!=EXPECTED[name] or (root/(name+'.zip.sha256')).read_text().split()[0]!=digest:raise RuntimeError('Vendor SHA256 mismatch')
    binary=root/name
    with zipfile.ZipFile(zpath) as z:
        if z.namelist()!=[name] or z.read(name)!=binary.read_bytes():raise RuntimeError('Extracted binary differs from validated ZIP')
    arch=run(name+'-file',['/usr/bin/file',binary]);build=run(name+'-vtool',['/usr/bin/vtool','-show-build',binary]);deptext=run(name+'-otool',['/usr/bin/otool','-L',binary]);signature=run(name+'-codesign',['/usr/bin/codesign','--verify','--strict','--verbose=2',binary])
    if 'arm64' not in arch:raise RuntimeError('Not arm64')
    minimum=re.findall(r'\bminos\s+(\d+(?:\.\d+)*)',build)
    if not minimum or any(tuple(map(int,m.split('.')))> (13,0) for m in minimum):raise RuntimeError('Unsupported deployment target')
    dependencies=[l.strip().split(' (compatibility')[0] for l in deptext.splitlines()[1:] if l.strip()]
    if any(not d.startswith(('/usr/lib/','/System/Library/')) for d in dependencies):raise RuntimeError('Non-system dependency')
    version=run(name+'-version',[binary,'-hide_banner','-version'])
    records[name]={'zip_url':BASE+name+'.zip','sha256_url':BASE+name+'.zip.sha256','zip_sha256':digest,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'binary_size':binary.stat().st_size,'architecture':'arm64','minos':minimum,'system_only_dependencies':dependencies,'version':version.splitlines()[0],'signature_verified':True}
ff=root/'ffmpeg';probe=root/'ffprobe'
enc=run('ffmpeg-encoders',[ff,'-hide_banner','-encoders']);filters=run('ffmpeg-filters',[ff,'-hide_banner','-filters']);formats=run('ffmpeg-formats',[ff,'-hide_banner','-formats']);license=run('ffmpeg-license',[ff,'-hide_banner','-L'])
(root/'FFMPEG-LICENSE.txt').write_text(license)
for names,text,label in [(ENCODERS,enc,'encoder'),(FILTERS,filters,'filter')]:
    missing=[n for n in names if not re.search(r'\s'+re.escape(n)+r'\s',text)]
    if missing:raise RuntimeError('Missing '+label+': '+','.join(missing))
checks=[]
def conversion(label,args,output):
    run(label,[ff,'-nostdin','-hide_banner','-v','error','-y',*args,output])
    info=json.loads(run(label+'-probe',[probe,'-v','error','-show_streams','-show_format','-of','json',output]))
    if not info.get('streams'):raise RuntimeError(label+' has no actual streams')
    run(label+'-decode',[ff,'-nostdin','-v','error','-protocol_whitelist','file,pipe','-i',output,'-f','null','-'])
    checks.append({'name':label,'passed':True,'streams':[(s.get('codec_type'),s.get('codec_name')) for s in info['streams']]})
video=['-f','lavfi','-i','testsrc2=s=160x90:r=15:d=0.5','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=0.5','-shortest']
for ext,v,a in [('mp4','libx264','aac'),('mov','libx264','aac'),('mkv','libx264','aac'),('webm','libvpx-vp9','libopus'),('avi','mpeg4','libmp3lame'),('wmv','wmv2','wmav2')]:
    args=video+['-c:v',v,'-c:a',a,'-pix_fmt','yuv420p']
    if a=='wmav2':args+=['-ar','44100','-ac','2']
    conversion('encode-'+ext,args,smoke/('video.'+ext))
for ext,c in [('mp3','libmp3lame'),('m4a','aac'),('wav','pcm_s16le'),('flac','flac'),('ogg','vorbis'),('opus','libopus'),('aiff','pcm_s16be'),('wma','wmav2')]:
    args=['-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=0.5','-c:a',c]
    if c=='vorbis':args+=['-strict','experimental','-ac','2']
    if c=='wmav2':args+=['-ar','44100','-ac','2']
    conversion('encode-'+ext,args,smoke/('audio.'+ext))
for ext,c in [('avif','libaom-av1'),('webp','libwebp')]:
    args=['-f','lavfi','-i','testsrc2=s=160x90:r=1:d=1','-frames:v','1','-c:v',c]
    if ext=='avif':args+=['-still-picture','1','-cpu-used','6','-crf','30']
    conversion('encode-'+ext,args,smoke/('image.'+ext))
conversion('filter-visualizer',['-f','lavfi','-i','sine=frequency=440:duration=0.5','-filter_complex','[0:a]showwaves=s=160x60:mode=cline:rate=15,pad=160:90:0:15:color=black,format=yuv420p[v]','-map','[v]','-map','0:a','-shortest','-c:v','libx264','-c:a','aac'],smoke/'visualizer.mp4')
run('filter-audio',[ff,'-nostdin','-v','error','-i',smoke/'audio.wav','-af','atrim=0:0.3,asetpts=PTS-STARTPTS,atempo=1.5,loudnorm=I=-18:TP=-1.5:LRA=11,aeval=exprs=val(0),silenceremove=start_periods=1:start_duration=0.01:start_threshold=-60dB,areverse,areverse','-f','null','-'])
checks.append({'name':'filter-audio','passed':True})
conversion('filter-redaction',['-i',smoke/'video.mp4','-filter_complex','[0:v]split[b][r];[r]crop=40:40:10:10,boxblur=2:1[blur];[b][blur]overlay=10:10,drawbox=x=80:y=10:w=30:h=30:color=black:t=fill[v]','-map','[v]','-map','0:a','-c:v','libx264','-c:a','aac'],smoke/'redaction.mp4')
report={'vendor':'Martin Riedl FFmpeg static release builds','vendor_home':'https://ffmpeg.martin-riedl.de/','build_sources':'https://git.martin-riedl.de/ffmpeg/build-script','release':'9.0.2','verified_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'host_macos':run('host-swvers',['/usr/bin/sw_vers','-productVersion']).strip(),'target_macos':'13.0','binaries':records,'required_encoders':ENCODERS,'required_filters':FILTERS,'missing_encoders':[],'missing_filters':[],'smoke_checks':checks,'license':'GPL version3 or later,as reported by ffmpeg -L;retain license/provenance;publication still requires complete corresponding source/license review','macos13_device_test':'not run;Mach-O minos12.0 and only system dependencies are verified,actual runtime smoke executed on host stated above','app_bundle_modified':False}
(root/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'smoke_passed':len(checks),'minos':{n:r['minos'] for n,r in records.items()},'required_encoders':len(ENCODERS),'required_filters':len(FILTERS)},indent=2))
