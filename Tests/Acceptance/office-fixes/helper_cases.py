#!/usr/bin/env python3
from pathlib import Path
import argparse,csv,hashlib,json,os,runpy,subprocess,sys,zipfile,xml.etree.ElementTree as ET
ap=argparse.ArgumentParser();ap.add_argument('--helper',required=True);ap.add_argument('--output',required=True);ap.add_argument('--soffice',required=True);ap.add_argument('--expect-all',action='store_true');a=ap.parse_args()
F=Path(__file__).resolve().parent/'fixtures';O=Path(a.output).resolve();O.mkdir(parents=True,exist_ok=True);helper=Path(a.helper).resolve();rows=[]
env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
def convert(source,target,name):
 out=O/(name+'.'+target);r=subprocess.run([sys.executable,str(helper),'convert',str(source),str(out),target],capture_output=True,text=True,env=env,timeout=90)
 return out,r

def record(name,passed,**details):rows.append({'name':name,'passed':bool(passed),**details})
order=['DOC-START','OUTER-START','INNER-SDT','CELL-BEFORE','CELL-SDT','NESTED-TABLE-CELL','CELL-AFTER','SECOND-CELL','OUTER-END','DOC-END']
p,r=convert(F/'nested-sdt.docx','txt','nested-sdt');text=p.read_text() if p.exists() else '';positions=[text.find(s) for s in order];record('nested-sdt-block-table-order',r.returncode==0 and all(i>=0 for i in positions) and positions==sorted(positions),actual=text,expected_order=order,stderr=r.stderr)
p,r=convert(F/'cell-separators.docx','txt','cell-separators');text=p.read_text() if p.exists() else '';record('table-tab-br-cr',r.returncode==0 and text=='A\tB\nC\nD\n',actual=text,expected='A\tB\nC\nD\n',stderr=r.stderr)
for src in F.glob('chapter-*.epub'):
 for target in ['txt','docx']:
  p,r=convert(src,target,src.stem+'-'+target);actual=''
  if r.returncode==0:
   if target=='txt':actual=p.read_text()
   else:
    with zipfile.ZipFile(p) as z:actual=''.join(ET.fromstring(z.read('word/document.xml')).itertext())
  record(src.stem+'-'+target,r.returncode==0 and 'UNICODE BODY 本地文字 Ω' in actual,actual=actual,returncode=r.returncode,stderr=r.stderr)
p,r=convert(F/'whitespace.csv','ods','whitespace');out=O/'lo-csv';out.mkdir(exist_ok=True)
args=[sys.executable,str(helper),'office',a.soffice,'-env:UserInstallation='+str((O/'lo-profile').as_uri()),'--headless','--nologo','--nodefault','--norestore','--nolockcheck','--convert-to','csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,0','--outdir',str(out),str(p)]
lo=subprocess.run(args,capture_output=True,text=True,env=env,timeout=180) if r.returncode==0 else r
back=out/'whitespace.csv';actual=list(csv.reader(back.open(encoding='utf-8-sig',newline=''))) if back.exists() else [];expected=json.loads((F/'whitespace-expected.json').read_text());record('ods-csv-exact-whitespace-roundtrip',r.returncode==0 and lo.returncode==0 and actual==expected,actual_rows=actual,expected_rows=expected,stderr=lo.stderr,stdout=lo.stdout)
# Preserve the leader's existing precision and formula-as-text behavior.
source=O/'precision.csv';original=['0.1234567890123456789012345','1234567890123456','00123','=1+1','123.5'];source.write_text('\n'.join(original)+'\n')
p,r=convert(source,'xlsx','precision');values=[];types=[]
if r.returncode==0:
 from openpyxl import load_workbook
 w=load_workbook(p);values=[c[0].value for c in w.active];types=[c[0].data_type for c in w.active]
record('precision-and-formula-regression',r.returncode==0 and values[:4]==original[:4] and values[4]==123.5 and types[:4]==['s']*4,values=values,types=types)
module=runpy.run_path(str(helper),run_name='office_fixes_helper')
for encoding in ['utf-8','utf-16-le','utf-16-be']:
 data='<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e "BAD">]><x>&e;</x>'.encode(encoding)
 if encoding=='utf-16-le':data=b'\xff\xfe'+data
 if encoding=='utf-16-be':data=b'\xfe\xff'+data
 try:module['xml'](data);rejected=False
 except Exception:rejected=True
 record('xml-dtd-rejected-'+encoding,rejected)
report={'helper':str(helper),'helper_sha256':hashlib.sha256(helper.read_bytes()).hexdigest(),'cases':rows,'passed':sum(r['passed'] for r in rows),'failed':sum(not r['passed'] for r in rows),'scope':'Actual helper exports and LibreOffice ODS-to-CSV roundtrip; helper path is explicit;tests never modify shared app resources.'}
(O/'helper-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(report['passed'],'passed,',report['failed'],'failed')
if a.expect_all and report['failed']:raise SystemExit(1)
