"""Read ODF paragraph whitespace by the ODF1.2 whitespace contract, independently of the writer."""
from pathlib import Path
import json,re,sys,zipfile,xml.etree.ElementTree as E
F=Path(__file__).resolve().parent/'fixtures';BASE=Path(sys.argv[1]);expected=json.loads((F/'whitespace-expected.json').read_text());NS={'table':'urn:oasis:names:tc:opendocument:xmlns:table:1.0','text':'urn:oasis:names:tc:opendocument:xmlns:text:1.0'}
def paragraph_value(p):
 replacements={}
 def explicit(value):
  key='\ue000'+str(len(replacements))+'\ue001';replacements[key]=value;return key
 def read(e):
  pieces=[e.text or '']
  for child in e:
   tag=child.tag.split('}')[-1]
   if tag=='s':pieces.append(explicit(' '*int(child.attrib.get('{'+NS['text']+'}c','1'))))
   elif tag=='tab':pieces.append(explicit('\t'))
   elif tag=='line-break':pieces.append(explicit('\n'))
   else:pieces.append(read(child))
   pieces.append(child.tail or '')
  return ''.join(pieces)
 value=re.sub('[ \t\r\n]+',' ',read(p)).strip(' ')
 for marker,text in replacements.items():value=value.replace(marker,text)
 return value
reports=[]
for stage in ['before','after']:
 with zipfile.ZipFile(BASE/stage/'helper/whitespace.ods') as z:root=E.fromstring(z.read('content.xml'))
 actual=[['\n'.join(paragraph_value(p) for p in cell.findall('text:p',NS)) for cell in row.findall('table:table-cell',NS)] for row in root.findall('.//table:table-row',NS)]
 report={'stage':stage,'passed':actual==expected,'rows_by_odf_whitespace_semantics':actual,'expected_rows':expected,'boundary':'The current bundled LibreOffice already preserves the raw before whitespace on roundtrip;this independent ODF whitespace oracle documents portability semantics rather than claiming a reproduced LibreOffice failure.'}
 (BASE/stage/'helper/odf-format-semantic-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');reports.append(report)
print('Before conforming-whitespace oracle:',reports[0]['passed'],'After:',reports[1]['passed'])
assert not reports[0]['passed'] and reports[1]['passed']
