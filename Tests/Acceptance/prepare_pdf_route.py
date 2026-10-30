from pathlib import Path
import sys,json
from pypdf import PdfReader,PdfWriter
area=Path(sys.argv[1]);root=Path(__file__).resolve().parents[2];base=area/'pdf-route';base.mkdir(exist_ok=True)
page=PdfReader(root/'work/functional/fixtures/sample.pdf').pages[0];page.rotate(90);writer=PdfWriter();writer.add_page(page)
rotated=base/'rotated.pdf'
with rotated.open('wb') as f:writer.write(f)
rich=json.loads((area/'edge/results.json').read_text())['cases'][0]['outputs'][0]
jobs=[{'name':'Actual routed rich PDF to TXT reading order','inputs':[rich],'option':'format_txt'}]+[{'name':'Actual rotated PDF to '+fmt,'inputs':[str(rotated.resolve())],'option':'format_'+fmt} for fmt in ['png','jpg']]
(base/'jobs.json').write_text(json.dumps(jobs,ensure_ascii=False,indent=2))
