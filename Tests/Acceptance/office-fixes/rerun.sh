#!/bin/bash
# Usage: rerun.sh [resource-directory] [new-evidence-directory]
# Defaults to the final app's actual resources; does not modify or launch the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RESOURCES="${1:-$ROOT/LocalShift.app/Contents/Resources}"
OUTPUT="${2:-$ROOT/work/release-audit/office-fixes/rerun-$(date -u +%Y%m%dT%H%M%SZ)}"
PYTHON="${LOCALSHIFT_TEST_PYTHON:-$ROOT/LocalShift.app/Contents/Resources/bin/python3}"
SOFFICE="${LOCALSHIFT_TEST_SOFFICE:-$ROOT/LocalShift.app/Contents/Resources/OfficeRuntime/LibreOffice.app/Contents/MacOS/soffice}"
if [[ -e "$OUTPUT" ]]; then
  printf 'Use a new evidence directory to prevent stale output: %s\n' "$OUTPUT" >&2
  exit 2
fi
if [[ ! -f "$RESOURCES/office-helper.py" || ! -x "$PYTHON" || ! -x "$SOFFICE" ]]; then
  printf 'Missing explicit helper/Python/LibreOffice runtime.\n' >&2
  exit 2
fi
mkdir -p "$OUTPUT/build"
export PYTHONDONTWRITEBYTECODE=1
"$PYTHON" "$ROOT/Tests/Acceptance/office-fixes/helper_cases.py" \
  --helper "$RESOURCES/office-helper.py" --output "$OUTPUT/helper" \
  --soffice "$SOFFICE" --expect-all
swiftc -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "$OUTPUT/build/module-cache" \
  "$ROOT/Sources/EngineTypes.swift" "$ROOT/Sources/OperationContext.swift" \
  "$ROOT/Sources/OfficeEngine.swift" "$ROOT/Tests/Acceptance/office-fixes/main.swift" \
  -o "$OUTPUT/build/engine-tests"
LOCALSHIFT_RESOURCE_DIR="$RESOURCES" "$OUTPUT/build/engine-tests" \
  "$ROOT/Tests/Acceptance/office-fixes/fixtures" "$OUTPUT/engine"
"$PYTHON" "$ROOT/Tests/Acceptance/office-fixes/inspect_office.py" \
  --output "$OUTPUT/engine" --expect-all
printf 'Helper15 + editable-Office9 reports: %s\n' "$OUTPUT"
