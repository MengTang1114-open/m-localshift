from pathlib import Path
import argparse,json,re,zipfile,xml.etree.ElementTree as E
from openpyxl import load_workbook
ap=argparse.ArgumentParser();ap.add_argument('--output',required=True);ap.add_argument('--expect-all',action='store_true');a=ap.parse_args();O=Path(a.output);rows=[]
for item in json.loads((O/'engine-results.json').read_text()):
 name=item['name'];text='';error=item.get('error','')
 if item['converted']:
  p=Path(item['outputs'][0])
  if p.suffix=='.xlsx':
   w=load_workbook(p);text='\n'.join(str(c.value) for s in w for row in s for c in row if c.value is not None)
  else:
   with zipfile.ZipFile(p) as z:
    names=['word/document.xml'] if p.suffix=='.docx' else [n for n in z.namelist() if re.match(r'ppt/slides/slide[0-9]+\.xml$',n)]
    text='\n'.join(''.join(E.fromstring(z.read(n)).itertext()) for n in names)
 normalized=re.sub(r'\s+',' ',text).upper();phrases=['INVOICE NUMBER 24680','TOTAL AMOUNT 12345','SCANNED BODY MUST SURVIVE'];checks={p:normalized.count(p)==1 for p in phrases}
 if not name.startswith('pure-scan'):checks['native footer exactly once']=normalized.count('SCANNED BY LOCALSHIFT')==1
 rows.append({'name':name,'passed':item['converted'] and all(checks.values()),'content_checks':checks,'actual_text':text,'conversion_error':error})
r={'cases':rows,'passed':sum(x['passed'] for x in rows),'failed':sum(not x['passed'] for x in rows),'scope':'Actual editable Word paragraphs,PowerPoint text boxes and Excel cells,not image attachments; exact expected phrases and duplicate counts.'};(O/'content-results.json').write_text(json.dumps(r,indent=2)+'\n');print(r['passed'],'passed,',r['failed'],'failed')
if a.expect_all and r['failed']:raise SystemExit(1)
