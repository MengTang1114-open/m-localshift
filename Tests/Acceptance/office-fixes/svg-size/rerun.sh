#!/bin/bash
# Uses one explicit application resource directory for helper and engines.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
TESTS="$ROOT/Tests/Acceptance/office-fixes/svg-size"
RESOURCES="${1:-$ROOT/LocalShift.app/Contents/Resources}"
OUTPUT="${2:-$ROOT/work/release-audit/office-fixes/svg-size/rerun-$(date -u +%Y%m%dT%H%M%SZ)}"
PYTHON="${LOCALSHIFT_TEST_PYTHON:-$RESOURCES/bin/python3}"
if [[ -e "$OUTPUT" ]]; then printf 'Use a new evidence directory: %s\n' "$OUTPUT" >&2; exit 2; fi
mkdir -p "$OUTPUT/build"
export PYTHONDONTWRITEBYTECODE=1
"$PYTHON" "$TESTS/prepare.py" "$RESOURCES" "$TESTS" "$OUTPUT"
"$PYTHON" "$ROOT/Tests/Acceptance/office-fixes/helper_cases.py" --helper "$RESOURCES/office-helper.py" --output "$OUTPUT/helper" --soffice "$RESOURCES/OfficeRuntime/LibreOffice.app/Contents/MacOS/soffice" --expect-all
shasum -a 256 "$ROOT/Sources/OfficeEngine.swift" "$ROOT/Sources/AdvancedNative.swift" "$ROOT/Sources/OperationContext.swift" "$RESOURCES/office-helper.py" > "$OUTPUT/compiled-source-sha256.txt"
swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "${LOCALSHIFT_TEST_MODULE_CACHE:-$OUTPUT/build/module-cache}" "$ROOT/Sources/EngineTypes.swift" "$ROOT/Sources/OperationContext.swift" "$ROOT/Sources/AdvancedNative.swift" "$ROOT/Sources/OfficeEngine.swift" "$TESTS/main.swift" -o "$OUTPUT/build/engine-tests"
LOCALSHIFT_RESOURCE_DIR="$RESOURCES" "$OUTPUT/build/engine-tests" "$TESTS" "$OUTPUT/engine" "$OUTPUT/inputs"
"$PYTHON" "$ROOT/Tests/Acceptance/office-fixes/inspect_office.py" --output "$OUTPUT/engine/regression" --expect-all
"$PYTHON" "$TESTS/verify.py" "$OUTPUT" "$RESOURCES"
printf 'SVG dimensions, CJK order, all sheets, print layout and prior24 reports: %s\n' "$OUTPUT"
