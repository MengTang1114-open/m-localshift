from pathlib import Path
import json,sys
from PIL import Image
from pypdf import PdfReader
out=Path(sys.argv[1]);reports=[]
def check(name,passed,**details):reports.append({'name':name,'passed':bool(passed),**details})
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

report={'passed':sum(r['passed'] for r in reports),'failed':sum(not r['passed'] for r in reports),'cases':reports}
(out/'raster-content-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(report['passed'],'passed,',report['failed'],'failed')
if report['failed']:raise SystemExit(1)
