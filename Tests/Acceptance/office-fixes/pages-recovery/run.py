from pathlib import Path
import sys,os,json,subprocess,shutil,zipfile,xml.etree.ElementTree as E,uuid,hashlib
from PIL import Image
from pypdf import PdfReader
root,resources,binary,out=map(Path,sys.argv[1:]);out.mkdir(parents=True,exist_ok=True);results=[]
production_script=(resources/'OfficePages.applescript').read_text()
def osa(script,args=(),timeout=40):
 return subprocess.run(['/usr/bin/osascript','-e',script,*map(str,args)],capture_output=True,text=True,timeout=timeout)
def check(name,passed,**details):results.append({'name':name,'passed':bool(passed),**details});print(name,passed,flush=True)
def run(source,target,folder,res=resources,cancel=False):
 env=os.environ.copy();env['LOCALSHIFT_RESOURCE_DIR']=str(res);env['PYTHONDONTWRITEBYTECODE']='1'
 command=[str(binary),str(source),target,str(folder)]
 if cancel:command.append('cancel-after-open')
 r=subprocess.run(command,env=env,capture_output=True,text=True,timeout=300)
 if not (folder/'engine-result.json').is_file():raise RuntimeError(r.stdout+r.stderr)
 return json.loads((folder/'engine-result.json').read_text())
def output_text(path):
 if path.suffix in ['.txt','.md','.html']:return path.read_text(encoding='utf8')
 if path.suffix=='.pdf':return '\n'.join(p.extract_text() for p in PdfReader(path).pages)
 if path.suffix=='.docx':
  with zipfile.ZipFile(path) as z:return ''.join(E.fromstring(z.read('word/document.xml')).itertext())
 if path.suffix=='.epub':
  with zipfile.ZipFile(path) as z:return '\n'.join(z.read(n).decode('utf8') for n in z.namelist() if n.endswith(('.xhtml','.html')))
 return ''
def zip_ok(path):
 try:
  with zipfile.ZipFile(path) as z:return z.testzip() is None
 except Exception:return False
# Private unrelated document acts as a sentinel; production cleanup must leave it alone.
canary='LocalShift-UnrelatedCanary-'+str(uuid.uuid4());canary_dir=out/'canary';canary_dir.mkdir()
canary_file=canary_dir/(canary+'.pages');shutil.copy2(root/'work/functional/fixtures/sample.pages',canary_file)
subprocess.run(['/usr/bin/open','-g','-a','Pages',str(canary_file)],check=True,timeout=30)
canary_query='on run argv\n tell application "Pages"\n repeat 100 times\n repeat with d in documents\n if (name of d) starts with (item 1 of argv) then return "present"\n end repeat\n delay 0.1\n end repeat\n return "absent"\n end tell\nend run'
r=osa(canary_query,[canary]);check('unrelated-canary-open',r.returncode==0 and r.stdout.strip()=='present')
try:
 for index,job in enumerate(json.loads((root/'Tests/Acceptance/office-fixes/pages-recovery/jobs.json').read_text())):
  folder=out/'real'/str(index);result=run(root/job['source'],job['target'],folder);details={'conversion':result};passed=result['converted']
  if passed:
   output=Path(result['outputs'][0]);target=job['target']
   if target=='pages':
    readback=run(output,'txt',folder/'readback');text=output_text(Path(readback['outputs'][0])) if readback['converted'] else '';details['readback']=readback;details['contains_LocalShift']='localshift' in text.lower();passed=zip_ok(output) and details['contains_LocalShift']
   elif target in ['png','jpg']:
    im=Image.open(output).convert('RGB');passed=len(im.getcolors(im.width*im.height) or [])>1
   elif target=='pdf':
    text=output_text(output);compact=''.join(text.split()).lower();details['stable_body_sentinels']={v:v in compact for v in ['conversion','editabletext','123']};passed=all(details['stable_body_sentinels'].values())
   else:
    text=output_text(output);details['contains_LocalShift']='localshift' in text.lower();passed=details['contains_LocalShift']
  check(job['name'],passed,**details)
 # Fault injection exists only in private script copies, never in production code.
 recorder='''
on testRecord(label, inputPath)
    set handle to open for access (POSIX file (inputPath & ".faultlog")) with write permission
    write (label & linefeed) to handle starting at eof
    close access handle
end testRecord
'''
 once='''
    set injectedAlready to false
    try
        get info for (POSIX file (inputPath & ".injected"))
        set injectedAlready to true
    end try
    if not injectedAlready then
        set handle to open for access (POSIX file (inputPath & ".injected")) with write permission
        write "once" to handle
        close access handle
        error "DETERMINISTIC_PRIVATE_609" number -609
    end if
'''
 cases=[('before-once609','before',once,True,2),('reply-once609','after',once,True,1),('close-once609','close',once,True,1),('persistent609','before','error "DETERMINISTIC_PERSISTENT" number -609',False,2),('other2700-before','before','error "DETERMINISTIC_OTHER" number -2700',False,1),('other2700-after','after','error "DETERMINISTIC_OTHER_AFTER" number -2700',False,1)]
 for name,phase,injection,expected,attempts in cases:
  res=out/'fault-resources'/name;res.mkdir(parents=True)
  shutil.copy2(resources/'office-helper.py',res/'office-helper.py')
  for directory in ['bin','OfficeRuntime']:(res/directory).symlink_to(resources/directory)
  script=production_script.replace('-- LOCALSHIFT_TEST_BEFORE_EXPORT','my testRecord("convert", inputPath)\n    -- LOCALSHIFT_TEST_BEFORE_EXPORT').replace('-- LOCALSHIFT_TEST_AFTER_EXPORT','my testRecord("export", inputPath)\n                -- LOCALSHIFT_TEST_AFTER_EXPORT')
  marker={'before':'-- LOCALSHIFT_TEST_BEFORE_EXPORT','after':'-- LOCALSHIFT_TEST_AFTER_EXPORT','close':'-- LOCALSHIFT_TEST_CLOSE'}[phase]
  script=script.replace(marker,injection)+recorder
  (res/'OfficePages.applescript').write_text(script)
  folder=out/'fault'/name;result=run(root/'work/functional/fixtures/sample.docx','pages',folder,res)
  logs=[p.read_text(errors='replace') for p in folder.rglob('*.faultlog')];log=''.join(logs);count=log.splitlines().count('convert');exports=log.splitlines().count('export')
  expected_output=folder/'sample-converted.pages';stages=list(folder.glob('pages-*/export/LocalShift-*.pages'))
  good=result['converted']==expected and count==attempts
  if expected:good=good and expected_output.exists() and zip_ok(expected_output) and exports==1
  else:good=good and not expected_output.exists() and not result.get('outputs')
  if 'other2700' in name:good=good and '(-2700)' in result.get('error','')
  check(name,good,conversion=result,convert_attempts=count,exports=exports,expected_attempts=attempts,private_stage_count=len(stages),fault_log=log)
 # Cancel only after Pages has located the owned document, before export.
 name='cancel-after-open';res=out/'fault-resources'/name;res.mkdir(parents=True)
 shutil.copy2(resources/'office-helper.py',res/'office-helper.py')
 for directory in ['bin','OfficeRuntime']:(res/directory).symlink_to(resources/directory)
 assert '-- LOCALSHIFT_TEST_DOCUMENT_READY' in production_script
 script=production_script.replace('-- LOCALSHIFT_TEST_DOCUMENT_READY','my testRecord("blocked", inputPath)\n                delay 30')+recorder
 (res/'OfficePages.applescript').write_text(script)
 folder=out/'fault'/name;result=run(root/'work/functional/fixtures/sample.docx','pages',folder,res,cancel=True)
 passed=not result['converted'] and result.get('cancelled') and result.get('cancel_requested') and result['elapsed_seconds']<15 and not (folder/'sample-converted.pages').exists() and not result.get('outputs')
 check(name,passed,conversion=result,canonical_exists=(folder/'sample-converted.pages').exists())
 r=osa(canary_query,[canary]);check('unrelated-canary-survived-all-cases',r.returncode==0 and r.stdout.strip()=='present')
 # Our UUID-owned documents must all be closed. Keep every unrelated document.
 r=osa('tell application "Pages" to get name of every document');names=r.stdout.strip();owned=[]
 for folder in (out/'real').glob('*'):
  for p in folder.rglob('pages-*'):
   if p.is_dir():
    for candidate in p.glob('LocalShift-*'):
     if candidate.stem in names:owned.append(candidate.stem)
 for folder in (out/'fault').glob('*'):
  for p in folder.glob('pages-*/LocalShift-*'):
   if p.stem in names:owned.append(p.stem)
 check('no-owned-documents-left-open',r.returncode==0 and not owned,owned_names=owned,document_name_digest=hashlib.sha256(names.encode()).hexdigest())
finally:
 # This is our separately created canary, never a pre-existing user document.
 osa('on run argv\n tell application "Pages"\n repeat with d in (get documents)\n if (name of d) starts with (item 1 of argv) then close d saving no\n end repeat\n end tell\nend run',[canary])
report={'passed':sum(x['passed'] for x in results),'failed':sum(not x['passed'] for x in results),'cases':results,'scope':'22 actual Pages matrix/repetition directions, every Pages result roundtripped to real TXT; deterministic private-script609, other-error and after-open cancellation cases; unrelated canary and UUID cleanup protection.'}
(out/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(report['passed'],'passed,',report['failed'],'failed',flush=True)
if report['failed']:raise SystemExit(1)
