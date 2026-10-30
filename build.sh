#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="LocalShift.app"
VERSION="0.3.0"   # user-visible version; bump together with CHANGELOG.md
BUILD_NUMBER="4"  # increase for every distributed build
# Assemble from scratch so files from an older build never linger in the bundle.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${LOCALSHIFT_SKIP_RUNTIME:-0}" != "1" ]]; then python3 tools/bundle_runtime.py; fi
if [[ "${LOCALSHIFT_SKIP_RUNTIME:-0}" != "1" ]]; then
  WEBP_RUNTIME_DIR="work/vendor/webp13"
  for lib in libwebp.7.dylib libsharpyuv.0.dylib; do
    if [[ ! -f "$WEBP_RUNTIME_DIR/lib/$lib" ]]; then
      printf 'Missing macOS 13 compatible WebP runtime: %s\nRun: python3 tools/bootstrap_runtime.py\n' "$lib" >&2
      exit 1
    fi
  done
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses/WebP"
  for lib in libwebp.7.dylib libsharpyuv.0.dylib; do
    if [[ -f "$APP/Contents/Frameworks/$lib" ]]; then chmod u+w "$APP/Contents/Frameworks/$lib"; fi
    cp "$WEBP_RUNTIME_DIR/lib/$lib" "$APP/Contents/Frameworks/$lib"
  done
  cp "$WEBP_RUNTIME_DIR/licenses/COPYING" "$WEBP_RUNTIME_DIR/licenses/Pillow-LICENSE" "$WEBP_RUNTIME_DIR/licenses/NOTICE.md" "$APP/Contents/Resources/Licenses/WebP/"
  for lib in libsharpyuv.0.dylib libwebp.7.dylib; do codesign --force --sign - "$APP/Contents/Frameworks/$lib"; done
fi
if [[ -f Assets/AppIcon.icns ]]; then cp Assets/AppIcon.icns "$APP/Contents/Resources/"; fi
if [[ -d Resources ]]; then cp -R Resources/. "$APP/Contents/Resources/"; fi
# Package.swift is the single compile definition; this script only assembles the bundle.
swift build -c release --arch arm64 --product LocalShift
cp "$(swift build -c release --arch arm64 --show-bin-path)/LocalShift" "$APP/Contents/MacOS/LocalShift"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalShift</string>
<key>CFBundleIdentifier</key><string>io.github.mengtang1114.localshift</string>
<key>CFBundleName</key><string>LocalShift</string>
<key>CFBundleDisplayName</key><string>LocalShift</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>LocalShift 仅通过已安装的 Pages、Numbers 和 Keynote 转换你选择的本地文件。</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Local files</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>public.item</string></array></dict></array>
</dict></plist>
PLIST
# Runtime imports must never add unsealed bytecode to the signed application.
if [[ -d "$APP/Contents/Resources/Python" ]]; then python3 - "$APP/Contents/Resources/Python" <<'PYCODE'
from pathlib import Path
import sys,shutil
for p in Path(sys.argv[1]).rglob('__pycache__'):
    if p.is_dir():shutil.rmtree(p)
PYCODE
fi
codesign --force --deep --sign - "$APP"
printf 'Built: %s/%s\n' "$PWD" "$APP"
