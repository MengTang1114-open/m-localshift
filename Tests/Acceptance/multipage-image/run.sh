#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
MP_ROOT="$PWD/work/release-audit/multipage-image"
MP_PHASE="${1:-retest}"
if [[ ! "$MP_PHASE" =~ ^[A-Za-z0-9_-]+$ ]]; then exit 2; fi
mkdir -p "$MP_ROOT/$MP_PHASE-sources"
for source in EngineTypes OperationContext AdvancedNative; do cp "Sources/$source.swift" "$MP_ROOT/$MP_PHASE-sources/$source.swift"; done
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -Onone \
 -module-cache-path /private/tmp/localshift-multipage-modules \
 -framework Cocoa -framework ImageIO -framework PDFKit -framework CoreImage -framework Vision -framework UniformTypeIdentifiers \
 "$MP_ROOT/$MP_PHASE-sources/EngineTypes.swift" "$MP_ROOT/$MP_PHASE-sources/OperationContext.swift" "$MP_ROOT/$MP_PHASE-sources/AdvancedNative.swift" \
 Tests/Acceptance/multipage-image/Probe.swift -o "$MP_ROOT/probe-$MP_PHASE" > "$MP_ROOT/build-$MP_PHASE.log" 2>&1
LOCALSHIFT_RESOURCE_DIR="${LOCALSHIFT_RESOURCE_DIR:-$PWD/LocalShift.app/Contents/Resources}" \
 "$MP_ROOT/probe-$MP_PHASE" "$MP_ROOT" "$MP_PHASE" > "$MP_ROOT/run-$MP_PHASE.log" 2>&1
MP_PYTHON="${LOCALSHIFT_TEST_PYTHON:-python3}"
"$MP_PYTHON" Tests/Acceptance/multipage-image/verify.py "$MP_PHASE"
