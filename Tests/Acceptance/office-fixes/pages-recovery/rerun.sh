#!/bin/bash
# Compile independent engines and use one explicit final application resource directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
RESOURCES="${1:-$ROOT/LocalShift.app/Contents/Resources}"
OUTPUT="${2:-$ROOT/work/release-audit/office-fixes/pages-recovery/rerun-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ -e "$OUTPUT" ]]; then printf 'Use a new evidence directory: %s\n' "$OUTPUT" >&2; exit 2; fi
mkdir -p "$OUTPUT/build"
export PYTHONDONTWRITEBYTECODE=1
PYTHON="${LOCALSHIFT_TEST_PYTHON:-$RESOURCES/bin/python3}"
shasum -a 256 "$ROOT/Sources/OfficeEngine.swift" "$ROOT/Sources/AdvancedNative.swift" "$ROOT/Sources/OperationContext.swift" "$RESOURCES/OfficePages.applescript" "$RESOURCES/office-helper.py" > "$OUTPUT/compiled-source-sha256.txt"
/usr/bin/osacompile -o "$OUTPUT/build/OfficePages.scpt" "$RESOURCES/OfficePages.applescript"
swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "${LOCALSHIFT_TEST_MODULE_CACHE:-$OUTPUT/build/module-cache}" "$ROOT/Sources/EngineTypes.swift" "$ROOT/Sources/OperationContext.swift" "$ROOT/Sources/AdvancedNative.swift" "$ROOT/Sources/OfficeEngine.swift" "$ROOT/Tests/Acceptance/office-fixes/pages-recovery/main.swift" -o "$OUTPUT/build/pages-tests"
"$PYTHON" "$ROOT/Tests/Acceptance/office-fixes/pages-recovery/run.py" "$ROOT" "$RESOURCES" "$OUTPUT/build/pages-tests" "$OUTPUT/run"
printf 'Pages32 result: %s/run/results.json\n' "$OUTPUT"
