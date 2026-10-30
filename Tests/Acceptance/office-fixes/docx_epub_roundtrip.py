from pathlib import Path
import json,os,subprocess,sys
F=Path(__file__).resolve().parent/'fixtures';root=Path(sys.argv[1]);helper=root/'Resources/office-helper.py';out=root/'work/release-audit/office-fixes/after/helper';env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
order=['DOC-START','OUTER-START','INNER-SDT','CELL-BEFORE','CELL-SDT','NESTED-TABLE-CELL','CELL-AFTER','SECOND-CELL','OUTER-END','DOC-END']
subprocess.run([sys.executable,str(helper),'convert',str(F/'nested-sdt.docx'),str(out/'sdt.epub'),'epub'],check=True,env=env)
subprocess.run([sys.executable,str(helper),'convert',str(out/'sdt.epub'),str(out/'sdt-back.txt'),'txt'],check=True,env=env)
text=(out/'sdt-back.txt').read_text();positions=[text.find(x) for x in order];passed=all(x>=0 for x in positions) and positions==sorted(positions) and all(text.count(x)==1 for x in order)
(out/'sdt-epub-roundtrip-results.json').write_text(json.dumps({'passed':passed,'actual':text,'expected_order':order,'counts':{x:text.count(x) for x in order}},indent=2)+'\n');assert passed
print('Nested SDT/table actual DOCX-to-EPUB-to-TXT order and counts passed')
