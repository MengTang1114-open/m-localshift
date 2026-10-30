from pathlib import Path
import sys,json,csv,re,zipfile,subprocess,xml.etree.ElementTree as E
from PIL import Image
from pypdf import PdfReader
from openpyxl import load_workbook
out,resources=map(Path,sys.argv[1:]);reports=[]
def check(name,passed,**details):reports.append({'name':name,'passed':bool(passed),**details})
def normalized(text):return ''.join(text.split())
def editable_text(path):
 if path.suffix=='.xlsx':
  w=load_workbook(path);return '\n'.join(str(c.value) for s in w for row in s for c in row if c.value is not None)
 with zipfile.ZipFile(path) as z:
  names=['word/document.xml'] if path.suffix=='.docx' else [n for n in z.namelist() if re.fullmatch(r'ppt/slides/slide[0-9]+\.xml',n)]
  return '\n'.join(''.join(E.fromstring(z.read(n)).itertext()) for n in names)
def image_count(resources,depth=0):
 if not resources or depth>16:return 0
 count=0
 for obj in resources.get('/XObject',{}).values():
  item=obj.get_object()
  if item.get('/Subtype')=='/Image':count+=1
  elif item.get('/Subtype')=='/Form':count+=image_count(item.get('/Resources'),depth+1)
 return count
for row in json.loads((out/'engine/svg/engine-results.json').read_text()):
 name=row['name'];stem=name.rsplit('-',1)[0]
 expected=(192,96) if stem=='inches' else (96,48) if stem in ['millimeters','points','quarter-millimeters'] else (320,180)
 if row['target']=='pdf':expected=tuple(x*.75 for x in expected)
 dims=row.get('width'),row.get('height')
 passed=row['converted'] and all(isinstance(x,(int,float)) and abs(x-y)<.0001 for x,y in zip(dims,expected))
 details={'actual_size':dims,'expected_size':expected,'error':row.get('error','')}
 if passed and row['target']=='pdf':
  page=PdfReader(row['output']).pages[0];vectors=image_count(page.get('/Resources',{}))==0
  if stem=='original':details['vector_text_retained']='LocalShift' in (page.extract_text() or '');passed=passed and details['vector_text_retained']
  passed=passed and vectors and bool(page.get_contents().get_data());details['no_image_xobjects']=vectors
 elif passed:
  original=Image.open(row['output']);dpi=tuple(map(float,original.info.get('dpi',()))) or None;im=original.convert('RGB');w,h=im.size
  if row['target'] in ['png','jpg']:
   details['dpi']=dpi;passed=passed and dpi is not None and all(abs(x-96)<.02 for x in dpi)
  samples=[((10,10),(30,67,60)),((80,90),(255,138,50))] if stem=='original' else [((w//8,h//8),(224,32,32)),((7*w//8,7*h//8),(32,32,224)),((int(w*.4),h//2),(20,100,50))]
  details['positioned_color_checks']=[max(abs(a-b) for a,b in zip(im.getpixel(point),color))<60 for point,color in samples]
  passed=passed and all(details['positioned_color_checks'])
 check('svg:'+name,passed,**details)
for row in json.loads((out/'engine/rich/engine-results.json').read_text()):
 text=editable_text(Path(row['outputs'][0])) if row['converted'] else ''
 if row['name'].startswith('rich-'):
  expected=['LocalShift内容验收','中文内容不能丢失'];content={s:normalized(text).count(s)==1 for s in expected};passed=all(content.values())
 else:content={'matches_native_control':normalized(text)==normalized(row['source_pdfkit_text'])};passed=all(content.values())
 check('cjk:'+row['name'],row['converted'] and passed,actual_text=text,content_checks=content,error=row.get('error',''))
expected_multi=[[['项目','金额'],['中文数据','123.45'],['保留前导零','00123'],['SUM','133.45']],[['尾页数据','789']]]
for row in json.loads((out/'engine/spreadsheet/engine-results.json').read_text()):
 name=row['name']
 if name.startswith('unsafe.'):
  check('sheets:'+name,not row['converted'],error=row.get('error',''));continue
 if name=='precision.csv-pdf':
  text='\n'.join(p.extract_text() for p in PdfReader(row['outputs'][0]).pages) if row['converted'] else ''
  source=out/'inputs/precision.csv';values=[c for r in csv.reader(source.open(encoding='utf-8-sig',newline='')) for c in r]
  content={v:normalized(v) in normalized(text) for v in values}
  check('print:'+name,row['converted'] and all(content.values()),content_checks=content,actual_text=text);continue
 actual=[]
 for file in row.get('outputs',[]):
  with Path(file).open(encoding='utf-8-sig',newline='') as f:actual.append(list(csv.reader(f,delimiter='\t' if file.endswith('.tsv') else ',')))
 expected=[[['Single sheet','00123']]] if name.startswith('single.') else expected_multi
 names=[Path(f).name for f in row.get('outputs',[])]
 safe=all('/' not in n and '\\' not in n and len(n.encode('utf8'))<=255 for n in names)
 order=len(names)==1 or all('-sheet-'+str(i+1).zfill(4)+'-' in n for i,n in enumerate(names))
 check('sheets:'+name,row['converted'] and actual==expected and safe and order,actual_tables=actual,output_names=names,error=row.get('error',''))
for row in json.loads((out/'engine/raster/engine-results.json').read_text()):
 name=row['name'];stem=name.rsplit('-',1)[0]
 if stem.endswith('limit'):
  check('pdf:'+name,not row['converted'] and '上限' in row.get('error',''),error=row.get('error',''));continue
 expected=[(2550,3300)]*13 if stem=='many-pages' else [(300,600),(600,300)] if stem=='multipage' else [(750,1334)] if 'rot90' in stem or 'rot270' in stem else [(1334,750)]
 checks=[];actual=[]
 for index,file in enumerate(row.get('outputs',[])):
  im=Image.open(file);dpi=tuple(map(float,im.info.get('dpi',()))) or None;image=im.convert('RGB');w,h=im.size
  dimensions=index<len(expected) and im.size==expected[index];metadata=dpi is not None and all(abs(x-300)<.02 for x in dpi)
  if 'rot90' in stem:red,blue=(.875,.125),(.125,.875)
  elif 'rot270' in stem:red,blue=(.125,.875),(.875,.125)
  else:red,blue=(.125,.125),(.875,.875)
  colors=all(max(abs(a-b) for a,b in zip(image.getpixel((int(w*x),int(h*y))),color))<60 for (x,y),color in [(red,(224,32,32)),(blue,(32,32,224))])
  if stem=='many-pages':colors=colors and max(abs(a-b) for a,b in zip(image.getpixel((w//2,h//2)),(16*(index+1),255-16*(index+1),128)))<5
  checks.append(dimensions and metadata and colors);actual.append({'size':im.size,'dpi':dpi,'colors_correct':colors})
 check('pdf:'+name,row['converted'] and len(checks)==len(expected) and all(checks),pages=actual,expected_sizes=expected,error=row.get('error',''))
row=json.loads((out/'engine/ordinary-office/engine-results.json').read_text())[0]
files=row.get('outputs',[]);actual=[];passed=row['converted'] and len(files)==1
for file in files:
 im=Image.open(file);dpi=tuple(map(float,im.info.get('dpi',()))) or None;intermediate=next(Path(file).parent.glob('document-work/lo-*/output/*.pdf'));box=PdfReader(intermediate).pages[0].mediabox
 import math
 expected=(math.ceil(float(box.width)*2-1e-8),math.ceil(float(box.height)*2-1e-8))
 passed=passed and im.size==expected and dpi is not None and all(abs(x-144)<.02 for x in dpi);actual.append({'size':im.size,'dpi':dpi,'expected':expected})
check('office:unchanged144dpi',passed,actual=actual,error=row.get('error',''))
negative=out/'negative-svg';negative.mkdir()
base='<svg xmlns="http://www.w3.org/2000/svg" {attrs}>{body}</svg>'
cases={
 'percent':('width="100%" height="180" viewBox="0 0 320 180"',''),
 'font-relative':('width="20em" height="10em"',''),
 'calculated':('style="width:calc(100px + 20px);height:10px"',''),
 'missing-size':('','<rect width="10" height="10"/>'),
 'zero':('width="0" height="10"',''),
 'negative':('width="-10" height="10"',''),
 'nonfinite':('width="NaN" height="10"',''),
 'invalid-viewbox':('viewBox="0 0 10 bad"',''),
 'negative-viewbox':('viewBox="0 0 -10 20"',''),
 'oversized':('width="16385" height="1"',''),
 'excess-pixels':('width="11000" height="10000"',''),
 'script':('width="10" height="10"','<script>alert(1)</script>'),
 'external':('width="10" height="10"','<use href="https://example.com/evil.svg"/>'),
 'style-resource':('width="10" height="10"','<style>rect{fill:url(https://example.com/x)}</style>'),
 'stylesheet-size':('width="10" height="10"','<style>svg{width:20px}</style>')}
for name,(attrs,body) in cases.items():
 source=negative/(name+'.svg');dest=negative/(name+'-safe.svg');source.write_text(base.format(attrs=attrs,body=body))
 result=subprocess.run([sys.executable,str(resources/'office-helper.py'),'svg',str(source),str(dest)],capture_output=True,text=True,timeout=20)
 check('reject:'+name,result.returncode!=0 and not dest.exists(),error=result.stderr.strip())
# Fractional units use outward pixel rounding, without changing exact PDF size.
source=negative/'fractional.svg';dest=negative/'fractional-safe.svg';source.write_text(base.format(attrs='width="1cm" height="0.5cm"',body=''))
result=subprocess.run([sys.executable,str(resources/'office-helper.py'),'svg',str(source),str(dest)],capture_output=True,text=True,timeout=20)
try:details=json.loads(result.stdout);passed=result.returncode==0 and details['pixelWidth']==38 and details['pixelHeight']==19
except Exception:details={};passed=False
check('svg:fractional-cm-rounding',passed,actual=details)
report={'passed':sum(r['passed'] for r in reports),'failed':sum(not r['passed'] for r in reports),'cases':reports,'scope':'Actual engine outputs: geometry/color positions and vector PDF, native CJK order with exact character multiset, RTL/vertical controls, all spreadsheet sheet values, all original precision CSV cells in PDF, PDF300dpi rotation/nonzero/multipage and ordinary Office144dpi, and SVG offline/size rejection.'}
(out/'content-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(report['passed'],'passed,',report['failed'],'failed')
if report['failed']:raise SystemExit(1)
