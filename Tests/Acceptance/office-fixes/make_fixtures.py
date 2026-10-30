from pathlib import Path
import csv,io,json,zipfile
from PIL import Image,ImageDraw,ImageFont
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
ROOT=Path(__file__).resolve().parent;F=ROOT/'fixtures';F.mkdir(exist_ok=True)
W='http://schemas.openxmlformats.org/wordprocessingml/2006/main';R='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
def p(s):return '<w:p><w:r><w:t>'+s+'</w:t></w:r></w:p>'
def sdt(s):return '<w:sdt><w:sdtContent>'+s+'</w:sdtContent></w:sdt>'
def table(cells):return '<w:tbl><w:tr>'+''.join('<w:tc>'+s+'</w:tc>' for s in cells)+'</w:tr></w:tbl>'
def docx(name,body):
 with zipfile.ZipFile(F/name,'w',zipfile.ZIP_DEFLATED) as z:
  z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
  z.writestr('_rels/.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="'+R+'/officeDocument" Target="word/document.xml"/></Relationships>')
  z.writestr('word/document.xml','<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="'+W+'"><w:body>'+body+'<w:sectPr/></w:body></w:document>')
nested=table([p('CELL-BEFORE')+sdt(p('CELL-SDT'))+table([p('NESTED-TABLE-CELL')])+p('CELL-AFTER'),p('SECOND-CELL')])
docx('nested-sdt.docx',p('DOC-START')+sdt(p('OUTER-START')+sdt(p('INNER-SDT'))+nested+p('OUTER-END'))+p('DOC-END'))
docx('cell-separators.docx',table(['<w:p><w:r><w:t>A</w:t><w:tab/><w:t>B</w:t><w:br/><w:t>C</w:t><w:cr/><w:t>D</w:t></w:r></w:p>']))
for encoding in ['utf-16-le','utf-16-be']:
 for declared in [False,True]:
  name='chapter-'+encoding+('-declared' if declared else '-bom')+'.epub';decl='<?xml version="1.0" encoding="UTF-16"?>' if declared else ''
  text=decl+'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Encoding test</title></head><body><p>UNICODE BODY 本地文字 Ω</p></body></html>'
  chapter=(b'\xff\xfe' if encoding.endswith('le') else b'\xfe\xff')+text.encode(encoding)
  with zipfile.ZipFile(F/name,'w',zipfile.ZIP_DEFLATED) as z:
   z.writestr('mimetype','application/epub+zip',compress_type=zipfile.ZIP_STORED)
   z.writestr('META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
   z.writestr('content.opf','<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:test</dc:identifier><dc:title>Encoding test</dc:title><dc:language>en</dc:language></metadata><manifest><item id="c" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>')
   z.writestr('chapter.xhtml',chapter)
rows=[['Case','Exact value'],['spaces','  alpha  beta   '],['tab','alpha\tbeta'],['newline','alpha\nbeta'],['combined','  alpha  beta\tgamma\nsecond  '],['unicode','本地  文字\tΩ\n尾行']]
with (F/'whitespace.csv').open('w',encoding='utf8',newline='') as f:csv.writer(f).writerows(rows)
(F/'whitespace-expected.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',64)
im=Image.new('RGB',(1800,1500),'white');draw=ImageDraw.Draw(im)
for y,t in [(180,'INVOICE NUMBER 24680'),(430,'TOTAL AMOUNT 12345'),(680,'SCANNED BODY MUST SURVIVE')]:draw.text((100,y),t,font=font,fill='black')
im.save(F/'scan-body.png')
for name,mixed in [('mixed-scan.pdf',True),('pure-scan.pdf',False)]:
 c=canvas.Canvas(str(F/name),pagesize=(612,792));c.drawImage(ImageReader(im),30,150,width=552,height=460)
 if mixed:c.setFont('Helvetica',12);c.drawString(40,40,'Scanned by LocalShift')
 c.save()
c=canvas.Canvas(str(F/'pure-native.pdf'),pagesize=(612,792));c.setFont('Helvetica',20)
for y,t in [(650,'INVOICE NUMBER 24680'),(500,'TOTAL AMOUNT 12345'),(350,'SCANNED BODY MUST SURVIVE')]:c.drawString(40,y,t)
c.setFont('Helvetica',12);c.drawString(40,40,'Scanned by LocalShift');c.save()
print('Fixtures created',len(list(F.iterdir())))
