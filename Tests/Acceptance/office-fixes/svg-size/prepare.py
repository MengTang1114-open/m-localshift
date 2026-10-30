from pathlib import Path
import sys,subprocess,shutil,json,zipfile,xml.etree.ElementTree as E
resources,tests,out=map(Path,sys.argv[1:]);inputs=out/'inputs';inputs.mkdir(parents=True)
for source in (tests/'spreadsheet/fixtures').iterdir():shutil.copy2(source,inputs/source.name)
for kind in ['ods','xls']:
 profile=out/('prepare-'+kind);profile.mkdir()
 cmd=[sys.executable,str(resources/'office-helper.py'),'office',str(resources/'OfficeRuntime/LibreOffice.app/Contents/MacOS/soffice'),'-env:UserInstallation='+profile.as_uri(),'--headless','--nologo','--nodefault','--norestore','--nolockcheck','--convert-to',kind,'--outdir',str(inputs),str(inputs/'sheets.xlsx')]
 result=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
 if result.returncode or not (inputs/('sheets.'+kind)).is_file():raise RuntimeError(result.stdout+result.stderr)
# Path-like sheet names must fail before an all-sheet CSV converter runs.
with zipfile.ZipFile(inputs/'sheets.xlsx') as z,zipfile.ZipFile(inputs/'unsafe.xlsx','w',zipfile.ZIP_DEFLATED) as dest:
 for name in z.namelist():
  data=z.read(name)
  if name=='xl/workbook.xml':
   root=E.fromstring(data);root.find('{http://schemas.openxmlformats.org/spreadsheetml/2006/main}sheets')[0].set('name','../../escape');data=E.tostring(root,encoding='utf-8')
  dest.writestr(name,data)
