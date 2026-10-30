from pathlib import Path
import sys,json,subprocess,re,unicodedata
from PIL import Image,ImageChops,ImageFilter
area=Path(sys.argv[1]);base=area/'pdf-route';cases=json.loads((base/'results.json').read_text())['cases'];rows=[]
norm=lambda s:re.sub(r'\s+','',unicodedata.normalize('NFKC',s))
phrases=json.loads((Path(__file__).resolve().parents[2]/'work/release-audit/fixtures/baseline.json').read_text())['rich_phrases']
text=Path(cases[0]['outputs'][0]).read_text();missing=[p for p in ['LocalShift 内容验收']+phrases if norm(p) not in norm(text)]
rows.append({'name':'Production PDF to TXT keeps all multilingual text in visible reading order','passed':not missing,'missing':missing})
subprocess.run(['/opt/homebrew/bin/pdftoppm','-r','300','-singlefile','-png',str(base/'rotated.pdf'),str(base/'reference')],check=True,capture_output=True)
ref=Image.open(base/'reference.png').convert('L');ink=ref.point(lambda p:255 if p<210 else 0);count=ink.histogram()[255]
for case in cases[1:]:
 files=[]
 for raw in case['outputs']:
  p=Path(raw);files.extend(p.glob('*') if p.is_dir() else [p])
 im=Image.open(files[0]);dpi=tuple(float(v) for v in im.info.get('dpi',(0,0)));size=im.size
 overlap=0;ratio=0
 if size==ref.size:
  raw=im.convert('L').point(lambda p:255 if p<210 else 0);ratio=raw.histogram()[255]/max(1,count);actual=raw.filter(ImageFilter.MaxFilter(5));intersection=ImageChops.multiply(ink,actual);overlap=intersection.histogram()[255]/max(1,count)
 rows.append({'name':case['name']+' dimensions DPI and actual visible orientation','passed':len(files)==1 and size==(750,1334) and all(abs(v-300)<.1 for v in dpi) and count>100 and overlap>.8 and .6<ratio<1.6,'size':size,'dpi':dpi,'reference_ink_covered':overlap,'ink_count_ratio':ratio})
r={'passed':sum(c['passed'] for c in rows),'failed':sum(not c['passed'] for c in rows),'cases':rows,'scope':'Production ConverterEngine routing, multilingual TXT and independently rendered rotated-page PNG/JPEG geometry, DPI and ink placement.'}
(base/'report.json').write_text(json.dumps(r,ensure_ascii=False,indent=2));print(json.dumps(r,ensure_ascii=False));raise SystemExit(bool(r['failed']))
