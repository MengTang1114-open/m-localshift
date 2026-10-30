from pathlib import Path
import hashlib,json,sys,os
root=Path(__file__).resolve().parents[2];bundle=root/'LocalShift.app';area=Path(sys.argv[2]);area.mkdir(parents=True,exist_ok=True)
files={}
for folder,dirs,names in os.walk(bundle,followlinks=False):
 for name in names+[n for n in dirs if (Path(folder)/n).is_symlink()]:
  p=Path(folder)/name
  if p.is_symlink():digest='symlink:'+os.readlink(p)
  else:
   h=hashlib.sha256()
   with p.open('rb') as f:
    for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
   digest=h.hexdigest()
  files[str(p.relative_to(bundle))]=digest
mode=sys.argv[1]
if mode=='before':(area/'bundle-before.json').write_text(json.dumps(files,indent=2));print(f'Bundle baseline: {len(files)} entries')
elif mode=='after':
 before=json.loads((area/'bundle-before.json').read_text());changed=[p for p in before.keys()|files.keys() if before.get(p)!=files.get(p)]
 report={'passed':not changed,'files_before':len(before),'files_after':len(files),'changed':changed}
 (area/'bundle-integrity.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));raise SystemExit(bool(changed))
else:raise SystemExit(2)
