#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PILLOW_SITE="${1:?usage: prepare.sh <site-packages directory containing Pillow>}"
mkdir -p "$ROOT/lib" "$ROOT/licenses" "$ROOT/evidence"
for lib in libwebp.7.dylib libsharpyuv.0.dylib; do
  source="$PILLOW_SITE/PIL/.dylibs/$lib"
  test -f "$source"
  xcrun vtool -show-build "$source" > "$ROOT/evidence/$lib.original-build.txt"
  /usr/bin/file "$source" > "$ROOT/evidence/$lib.original-file.txt"
  /usr/bin/otool -L "$source" > "$ROOT/evidence/$lib.original-dependencies.txt"
  # Reject a future wheel with a deployment target above the application's contract.
  /usr/bin/awk '/minos/ { split($2,v,"."); if (v[1] > 13 || (v[1] == 13 && v[2] > 0)) exit 1; found=1 } END { if (!found) exit 1 }' "$ROOT/evidence/$lib.original-build.txt"
  if [[ -f "$ROOT/lib/$lib" ]]; then chmod u+w "$ROOT/lib/$lib"; fi
  cp "$source" "$ROOT/lib/$lib"
  chmod u+w "$ROOT/lib/$lib"
  /usr/bin/install_name_tool -id "@loader_path/$lib" "$ROOT/lib/$lib"
done
# Pillow already uses the sibling-relative sharpyuv load path; it is verified below.
/usr/bin/otool -L "$ROOT/lib/libwebp.7.dylib" | /usr/bin/awk '/libsharpyuv/ && $1 != "@loader_path/libsharpyuv.0.dylib" {exit 1}'
for lib in libsharpyuv.0.dylib libwebp.7.dylib; do
  /usr/bin/codesign --force --sign - "$ROOT/lib/$lib"
  xcrun vtool -show-build "$ROOT/lib/$lib" > "$ROOT/evidence/$lib.prepared-build.txt"
  /usr/bin/otool -L "$ROOT/lib/$lib" > "$ROOT/evidence/$lib.prepared-dependencies.txt"
done
python3 - "$PILLOW_SITE" "$ROOT" <<'PY'
from pathlib import Path
import sys,json,hashlib
site,root=map(Path,sys.argv[1:])
license_file=next(site.glob('pillow-*.dist-info/licenses/LICENSE'))
license_text=license_file.read_text()
(root/'licenses/Pillow-LICENSE').write_text(license_text)
section=license_text.split('\nLIBWEBP\n',1)[1].split('\n\n----\n',1)[0].strip()+'\n'
assert 'Copyright (c) 2010, Google Inc.' in section and 'Redistribution and use in source and binary forms' in section
(root/'licenses/COPYING').write_text(section)
(root/'licenses/NOTICE.md').write_text('LocalShift WebP runtime\n\nlibwebp.7.dylib and its libsharpyuv.0.dylib dependency are reused from the official Pillow wheel. The original binaries declare macOS 11.0; no minimum-version load command was patched. Only dylib install IDs were made loader-relative and ad hoc signatures refreshed. COPYING reproduces the LIBWEBP BSD notice included in the wheel; Pillow-LICENSE preserves the complete wheel notices. No nonexistent PATENTS file is assumed.\n')
files=['libwebp.7.dylib','libsharpyuv.0.dylib']
manifest={'source':'official Pillow wheel','pillow_dist_info':license_file.parent.parent.name,'changes':['install_name_tool -id @loader_path/<library>','ad hoc codesign'],'minos_changed':False,'libraries':{name:{'source_path':str(site/'PIL/.dylibs'/name),'source_sha256':hashlib.sha256((site/'PIL/.dylibs'/name).read_bytes()).hexdigest(),'prepared_sha256':hashlib.sha256((root/'lib'/name).read_bytes()).hexdigest()} for name in files}}
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
