from pathlib import Path
import sys,json,hashlib,re
from PIL import Image
root=Path(__file__).resolve().parents[3]
base=root/'work/release-audit/multipage-image'
phase=sys.argv[1] if len(sys.argv)>1 else 'after'
report=json.loads((base/phase/'report.json').read_text())
cases={c['name']:c for c in report['cases']}
checks=[]
def check(name,ok,detail=None):
    item={'name':name,'passed':bool(ok)}
    if detail is not None:item['detail']=detail
    checks.append(item)
def color(rgba):
    r,g,b=rgba[:3]
    if r>160 and g<100 and b<120:return 'red'
    if b>160 and r<100 and g<130:return 'blue'
    if g>100 and r<100 and b<100:return 'green'
    return 'other'
def flat(case):return [im for output in case.get('outputs',[]) for im in output.get('images',[])]
def sentinel(text):return re.sub(r'[^A-Z]','',text.upper())
def pages(name,expected_colors,expected_texts):
    case=cases[name];images=flat(case)
    check(name+' succeeds',case['status']=='success',case.get('error'))
    check(name+' page count',len(images)==len(expected_colors),len(images))
    check(name+' page colors/order',[color(im['corner_rgba']) for im in images]==expected_colors)
    check(name+' page text/order',[sentinel(im.get('text','')) for im in images]==expected_texts)
    return case,images
baseline=json.loads((base/'fixtures/baseline.json').read_text())
for name,digest in baseline['files'].items():
    check('source unchanged '+name,hashlib.sha256((base/'fixtures'/name).read_bytes()).hexdigest()==digest)
check('source contains two pages',report['source']['pages']==2)
check('source has different red/blue pages',[color(im['corner_rgba']) for im in report['source']['images']]==['red','blue'])
before=json.loads((base/'before/report.json').read_text())
old={c['name']:c for c in before['cases']}
check('actual before TIFF to PDF lost page',sum(o.get('pages',0) for o in old['tiff_to_pdf']['outputs'])==1)
check('actual before createPDF lost TIFF second page',sum(o.get('pages',0) for o in old['create_pdf_mixed']['outputs'])==2)
for fmt in ['pdf','png','jpg','tiff','webp','heic','avif','bmp']:
    name='tiff_to_'+fmt
    c,images=pages(name,['red','blue'],['PAGEONERED','PAGETWOBLUE'])
    check(name+' pixel sizes preserved',[im['pixels'] for im in images]==[[320,180],[288,168]])
    if fmt in ['pdf','tiff']:
        check(name+' one multi-page container',len(c['outputs'])==1 and c['outputs'][0]['pages']==2)
    else:
        check(name+' unique sequential page filenames',[Path(o['file']).name for o in c['outputs']]==[f'two-pages-page-{i:04d}.{fmt}' for i in [1,2]])
pages('create_pdf_mixed',['red','blue','green'],['PAGEONERED','PAGETWOBLUE','PAGETHREEGREEN'])
for name in ['collage_multipage','multipage_background']+['tool_'+x for x in ['editImage','cropImage','annotateImage','frameImage','redactImage','removeMetadata','compress','readQRCode']]:
    c=cases[name]
    check(name+' explicit refusal',c['status']=='error' and '2 页 TIFF' in c.get('error','') and 'PNG/JPEG' in c.get('error',''))
    check(name+' no returned partial output',not c.get('outputs'))
for name in ['single_png_pdf','single_tiff_png','single_edit_png']:
    c,images=pages(name,['red'],['PAGEONERED'])
    check(name+' original dimensions',images[0]['pixels']==[320,180])
check('single TIFF original output naming',Path(cases['single_tiff_png']['outputs'][0]['file']).name=='single.png')
c=cases['single_collage'];check('single-frame collage remains supported',c['status']=='success' and len(c.get('outputs',[]))==1)
if c['status']=='success':
    im=Image.open(c['outputs'][0]['file']).convert('RGB')
    counts={'red':0,'green':0}
    for pixel in im.getdata():
        k=color(pixel)
        if k in counts:counts[k]+=1
    check('single-frame collage preserves both inputs',im.size==(320,180) and counts['red']>1000 and counts['green']>1000,counts)
pages('uppercase_tif_png',['red','blue'],['PAGEONERED','PAGETWOBLUE'])
summary={'phase':phase,'passed':sum(c['passed'] for c in checks),'failed':sum(not c['passed'] for c in checks),'checks':checks}
(base/phase/'verification.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:summary[k] for k in ['phase','passed','failed']},ensure_ascii=False))
if summary['failed']:
    for c in checks:
        if not c['passed']:print(json.dumps(c,ensure_ascii=False))
    sys.exit(1)
