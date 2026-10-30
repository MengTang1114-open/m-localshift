from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json, hashlib
root=Path(__file__).resolve().parents[3]
out=root/'work/release-audit/multipage-image/fixtures';out.mkdir(parents=True,exist_ok=True)
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf',28)
def page(size,color,text):
    im=Image.new('RGB',size,color);d=ImageDraw.Draw(im)
    d.text((24,56),text,font=font,fill='white')
    return im
red=page((320,180),'#D82030','PAGE ONE RED')
blue=page((288,168),'#2040D8','PAGE TWO BLUE')
green=page((320,180),'#188A30','PAGE THREE GREEN')
red.save(out/'two-pages.tiff',save_all=True,append_images=[blue],compression='tiff_deflate')
(out/'uppercase.TIF').write_bytes((out/'two-pages.tiff').read_bytes())
red.save(out/'single-red.png');green.save(out/'single-green.png');red.save(out/'single.tiff')
(out/'baseline.json').write_text(json.dumps({'expected_pages':[{'color':'red','text':'PAGE ONE RED','size':list(red.size)},{'color':'blue','text':'PAGE TWO BLUE','size':list(blue.size)}],'files':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in out.iterdir() if f.suffix!='.json'}},indent=2)+'\n')
print(out)
