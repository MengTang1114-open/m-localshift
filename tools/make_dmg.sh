#!/bin/bash
# Package the built LocalShift.app as dist/LocalShift-<version>.dmg plus its sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="LocalShift.app"
[[ -d "$APP" ]] || { echo "Build first: ./build.sh" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/LocalShift-$VERSION.dmg"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p dist
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/安装说明.md"
rm -f "$DMG"
hdiutil create -volname "LocalShift $VERSION" -srcfolder "$STAGE" -format UDZO -fs APFS "$DMG" >/dev/null
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
