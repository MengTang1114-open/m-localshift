#!/usr/bin/env python3
"""Read actual Mach-O headers; declared deployment targets are not device testing."""
from pathlib import Path
import json,subprocess,re,sys
root=Path(__file__).resolve().parent.parent
bundle=root/'LocalShift.app'
magic={bytes.fromhex(x) for x in ('cffaedfe','cefaedfe','feedfacf','feedface','cafebabe','bebafeca','cafebabf','bfbafeca')}
rows=[];too_new=[];unknown=[]
for path in bundle.rglob('*'):
 if not path.is_file() or path.is_symlink():continue
 try:
  with path.open('rb') as f:kind=f.read(4)
 except OSError:continue
 if kind not in magic:continue
 raw=subprocess.run(['/usr/bin/vtool','-show-build',str(path)],capture_output=True,text=True).stdout
 values=re.findall(r'\bminos\s+(\d+(?:\.\d+)*)',raw)
 if not values:values=re.findall(r'\bversion\s+(\d+(?:\.\d+)*)',raw)
 if not values:unknown.append(str(path.relative_to(root)))
 row={'path':str(path.relative_to(root)),'minimum_system_versions':values};rows.append(row)
 if any(tuple(map(int,(v+'.0.0').split('.')[:3]))>(13,0,0) for v in values):too_new.append(row)
report={'scanned_mach_o':len(rows),'too_new':too_new,'unknown':unknown,'files':rows,'scope':'Actual load-command deployment targets; physical macOS13 device testing pending'}
(root/'Evidence/runtime-compatibility.json').write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='files'}))
sys.exit(1 if too_new or unknown else 0)
