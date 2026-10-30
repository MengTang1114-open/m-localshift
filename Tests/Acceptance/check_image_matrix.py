from pathlib import Path
import argparse,json,subprocess,re,tempfile,math
from PIL import Image
from pypdf import PdfReader
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--matrix',required=True,type=Path);p.add_argument('--report',required=True,type=Path);a=p.parse_args()
jobs=json.loads((root/'work/functional/matrix-jobs.json').read_text());cases=json.loads(a.matrix.read_text())['cases'];rows=[]
image_types={'jpg','png','webp','heic','tiff','avif','bmp','svg'}
def pixels(path):
    if path.suffix.lower()=='.heic':
        text=subprocess.check_output(['/usr/bin/sips','-g','pixelWidth','-g','pixelHeight',str(path)],text=True)
        return tuple(int(re.search(key+r':\s*(\d+)',text)[1]) for key in ['pixelWidth','pixelHeight'])
    with Image.open(path) as im:return im.size
def sample(path):
    if path.suffix.lower()=='.heic':
        with tempfile.TemporaryDirectory(prefix='localshift-oracle-') as tmp:
            png=Path(tmp)/'decoded.png';subprocess.run(['/usr/bin/sips','-s','format','png',str(path),'--out',str(png)],check=True,capture_output=True)
            return sample(png)
    with Image.open(path) as im:
        rgb=im.convert('RGB');return [rgb.getpixel((round((rgb.width-1)*x),round((rgb.height-1)*y))) for x,y in [(.03,.03),(.05,.85)]]
for job,case in zip(jobs,cases):
    source=Path(job['inputs'][0]);ext=source.suffix.lower()[1:];target=job['option'].removeprefix('format_')
    if ext=='pdf' and target in {'png','jpg'}:
        files=[]
        for raw in case.get('outputs',[]):
            out=Path(raw);files.extend(sorted(out.glob('*.'+target)) if out.is_dir() else [out])
        pages=PdfReader(source).pages;details=[]
        for idx,file in enumerate(files):
            with Image.open(file) as im:
                dpi=tuple(float(v) for v in im.info.get('dpi',(0,0)));details.append({'pixels':im.size,'dpi':dpi})
        expected=[(math.ceil(float(page.mediabox.width)*300/72-1e-7),math.ceil(float(page.mediabox.height)*300/72-1e-7)) for page in pages]
        ok=len(files)==len(pages) and all(tuple(d['pixels'])==size and all(abs(v-300)<.1 for v in d['dpi']) for d,size in zip(details,expected))
        rows.append({'name':case['name']+' all pages at 300 DPI pixels and metadata','passed':ok,'details':details})
        continue
    if ext not in image_types:continue
    for raw in case.get('outputs',[]):
        output=Path(raw)
        if target in image_types-{'svg'}:
            try:
                size=pixels(output);colors=sample(output);reference=[(30,67,60)]*2
                preserved=all(max(abs(x-y) for x,y in zip(c,r))<24 for c,r in zip(colors,reference))
                rows.append({'name':case['name']+' exact pixel size and visible background','passed':size==(320,180) and preserved,'pixels':size,'samples':colors})
            except Exception as e:rows.append({'name':case['name'],'passed':False,'error':str(e)})
        elif target=='pdf':
            pages=PdfReader(output).pages;b=pages[0].mediabox;ratio=float(b.width)/float(b.height)
            rows.append({'name':case['name']+' PDF page count and proportions','passed':len(pages)==1 and abs(ratio-320/180)<.02,'page_points':[float(b.width),float(b.height)]})
report={'passed':sum(r['passed'] for r in rows),'failed':sum(not r['passed'] for r in rows),'cases':rows,'scope':'Image-matrix dimensions and color samples; PDF page count/proportions and every PDF raster page pixel dimensions plus 300 DPI metadata. HEIC read via system sips.'}
a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='cases'},ensure_ascii=False));print(json.dumps([r for r in rows if not r['passed']],ensure_ascii=False));raise SystemExit(bool(report['failed']))
