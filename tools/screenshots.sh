#!/bin/bash
# Render the main screens in light and dark mode for appearance review.
# *-window.png comes from the app's own --snapshot; *-screen.png comes from screencapture
# and is the one that shows real translucency (it needs screen recording permission).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: tools/screenshots.sh <output-dir>}"
APP="$PWD/LocalShift.app/Contents/MacOS/LocalShift"
mkdir -p "$OUT/fixtures"
export LOCALSHIFT_STATE_DIR="$OUT/state"
sips -s format jpeg Assets/AppIcon.icns --out "$OUT/fixtures/photo.jpg" > /dev/null

shoot() {
  local name="$1" look="$2"
  shift 2
  LOCALSHIFT_APPEARANCE="$look" LOCALSHIFT_SNAPSHOT_HOLD=3 "$APP" --snapshot "$OUT/$name-$look-window.png" "$@" &
  local pid=$!
  sleep 3
  screencapture -x "$OUT/$name-$look-screen.png" || true
  wait "$pid" || true
}

for look in light dark; do
  shoot empty "$look"
  shoot demo "$look" --demo
  shoot photo "$look" --open-file "$OUT/fixtures/photo.jpg"
  shoot guide "$look" --snapshot-section guide
  shoot overlay "$look" --snapshot-section overlay --open-file "$OUT/fixtures/photo.jpg"
done
mkdir -p "$OUT/icon"
python3 tools/make_icon.py --preview > /dev/null 2>&1 && cp work/icon/AppIcon-*.png "$OUT/icon/" || true
ls -1 "$OUT"
