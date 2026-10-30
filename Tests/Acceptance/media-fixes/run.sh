#!/bin/bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "$0")/../../.." && pwd)"
evidence_root="$project_root/work/release-audit/media-fixes"
phase="${1:-root-recheck-$(date -u +%Y%m%dT%H%M%SZ)}"
if [[ ! "$phase" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Use a phase name containing only letters, digits, underscores or hyphens." >&2
  exit 2
fi
phase_dir="$evidence_root/$phase"
if [[ -e "$phase_dir" ]]; then
  echo "Evidence phase already exists; choose a fresh name to preserve recorded evidence: $phase_dir" >&2
  exit 2
fi
python_command="${LOCALSHIFT_TEST_PYTHON:-python3}"
mkdir -p "$phase_dir"
cd "$project_root"
"$python_command" Tests/Acceptance/media-fixes/fixtures.py > "$phase_dir/fixtures.log" 2>&1
swiftc Sources/EngineTypes.swift Sources/OperationContext.swift Sources/AdvancedMedia.swift Tests/Acceptance/media-fixes/main.swift -o "$phase_dir/media-tests" > "$phase_dir/compile.log" 2>&1
LOCALSHIFT_RESOURCE_DIR="$project_root/LocalShift.app/Contents/Resources" "$phase_dir/media-tests" "$evidence_root/jobs.json" "$phase_dir/outputs" > "$phase_dir/run.log" 2>&1
"$python_command" Tests/Acceptance/media-fixes/validate.py "$phase_dir/outputs" > "$phase_dir/validation.log" 2>&1
cat "$phase_dir/validation.log"
"$python_command" - "$phase_dir/outputs/validation.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));sys.exit(0 if r['passed']==53 and r['failed']==0 else 1)
PY
printf 'Evidence: %s\n' "$phase_dir"
