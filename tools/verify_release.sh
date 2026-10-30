#!/bin/bash
# Local engineering gate: actual files, independent readback and immutable app.
set -euo pipefail
cd "$(dirname "$0")/.."
LS_AUDIT="${1:-$PWD/work/release-audit/final-$(date -u +%Y%m%dT%H%M%SZ)}"
LS_PYTHON="${LOCALSHIFT_TEST_PYTHON:-python3}"
if [[ -e "$LS_AUDIT" ]]; then echo 'Choose a new audit directory; existing evidence is never reused.'; exit 2; fi
if [[ ! -f work/functional/matrix-jobs.json || ! -f work/functional/tool-jobs.json ]]; then echo 'Prepare the functional fixtures and jobs first.'; exit 2; fi
mkdir -p "$LS_AUDIT"
export PYTHONDONTWRITEBYTECODE=1
export LOCALSHIFT_RESOURCE_DIR="$PWD/LocalShift.app/Contents/Resources"
export LOCALSHIFT_RUNTIME_BIN="$LOCALSHIFT_RESOURCE_DIR/bin"
LS_SOURCES=(Sources/EngineTypes.swift Sources/OperationContext.swift Sources/CapabilityCatalog.swift Sources/SubtitleEngine.swift Sources/FileTransfer.swift Sources/EngineRouter.swift Sources/AdvancedNative.swift Sources/AdvancedMedia.swift Sources/OfficeEngine.swift)
LS_FLAGS=(-swift-version 5 -target arm64-apple-macos13.0 -module-cache-path /private/tmp/localshift-test-module-cache -framework Cocoa -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage -framework Vision -framework AVFoundation -framework WebKit -larchive)
LS_FAILURES=0
run_gate() {
 local label="$1" logfile="$2" result
 shift 2
 if "$@" > "$logfile" 2>&1; then result=0; else result=$?; LS_FAILURES=$((LS_FAILURES+1)); fi
 printf '%s\t%s\n' "$label" "$result" >> "$LS_AUDIT/phase-status.tsv"
 printf 'Phase %s: exit %s\n' "$label" "$result"
}
"$LS_PYTHON" - "$LS_AUDIT" <<'PYHASH'
from pathlib import Path
import json,hashlib,sys
paths=list(Path('Sources').glob('*.swift'))+list(Path('Resources').rglob('*'))+[Path('build.sh')]
source={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()}
(Path(sys.argv[1])/'source-before.json').write_text(json.dumps(source,indent=2))
PYHASH
bash build.sh > "$LS_AUDIT/build.log" 2>&1
"$LS_PYTHON" Tests/Acceptance/bundle_integrity.py before "$LS_AUDIT"
xcrun swiftc "${LS_FLAGS[@]}" "${LS_SOURCES[@]}" Tests/Functional/main.swift -o "$LS_AUDIT/functional-tests" > "$LS_AUDIT/functional-build.log" 2>&1
LS_FUNCTIONAL="$LS_AUDIT/functional-tests"
run_gate regression "$LS_AUDIT/regression.log" ./test.sh "$LS_AUDIT/regression"
run_gate matrix "$LS_AUDIT/matrix.log" "$LS_FUNCTIONAL" work/functional/matrix-jobs.json "$LS_AUDIT/matrix/results.json"
run_gate tools "$LS_AUDIT/tools.log" "$LS_FUNCTIONAL" work/functional/tool-jobs.json "$LS_AUDIT/tools/results.json"
run_gate tool_semantics "$LS_AUDIT/tool-semantics.log" "$LS_PYTHON" tools/inspect_final_outputs.py --matrix "$LS_AUDIT/matrix/results.json" --tools "$LS_AUDIT/tools/results.json" --report "$LS_AUDIT/tool-semantics.json"
run_gate edge "$LS_AUDIT/edge.log" "$LS_FUNCTIONAL" work/release-audit/edge-jobs.json "$LS_AUDIT/edge/results.json"
run_gate content "$LS_AUDIT/content.log" "$LS_PYTHON" Tests/Acceptance/check_content.py --area "$LS_AUDIT"
run_gate pdf_prepare "$LS_AUDIT/pdf-prepare.log" "$LS_PYTHON" Tests/Acceptance/prepare_pdf_route.py "$LS_AUDIT"
run_gate pdf_route_convert "$LS_AUDIT/pdf-route.log" "$LS_FUNCTIONAL" "$LS_AUDIT/pdf-route/jobs.json" "$LS_AUDIT/pdf-route/results.json"
run_gate pdf_route_content "$LS_AUDIT/pdf-route-content.log" "$LS_PYTHON" Tests/Acceptance/check_pdf_route.py "$LS_AUDIT"
run_gate images "$LS_AUDIT/image-semantics.log" "$LS_PYTHON" Tests/Acceptance/check_image_matrix.py --matrix "$LS_AUDIT/matrix/results.json" --report "$LS_AUDIT/image-semantics.json"
run_gate negative_compile "$LS_AUDIT/negative-build.log" xcrun swiftc "${LS_FLAGS[@]}" "${LS_SOURCES[@]}" Tests/Acceptance/main.swift -o "$LS_AUDIT/negative-tests"
run_gate negative "$LS_AUDIT/negative.log" "$LS_AUDIT/negative-tests" "$LS_AUDIT/negative" "$PWD/work/release-audit/negative-fixtures"
run_gate process_compile "$LS_AUDIT/process-tree-build.log" xcrun swiftc "${LS_FLAGS[@]}" Sources/EngineTypes.swift Sources/OperationContext.swift Tests/Acceptance/process-tree/main.swift -o "$LS_AUDIT/process-tree-tests"
run_gate process_tree "$LS_AUDIT/process-tree.log" "$LS_AUDIT/process-tree-tests" "$LS_AUDIT/process-tree"
run_gate native "$LS_AUDIT/native.log" "$PWD/LocalShift.app/Contents/MacOS/LocalShift" --verify-ui "$LS_AUDIT/native"
LS_UI_SOURCES=(); for source in Sources/*.swift; do if [[ "$source" != Sources/AppMain.swift ]]; then LS_UI_SOURCES+=("$source"); fi; done
run_gate native_drop_compile "$LS_AUDIT/native-drop-build.log" xcrun swiftc "${LS_FLAGS[@]}" "${LS_UI_SOURCES[@]}" Tests/Acceptance/native-drop/main.swift -o "$LS_AUDIT/native-drop-tests"
run_gate native_drop "$LS_AUDIT/native-drop.log" "$LS_AUDIT/native-drop-tests" "$LS_AUDIT/native-drop" "$PWD/work/release-audit/fixtures/rich.docx"
mkdir -p "$LS_AUDIT/offline"
# LibreOffice 26.2 用本机 unix socket 通信。拒绝 TCP，只放行这种 socket，否则 soffice 退出码 0 且不写文件。
run_gate offline "$LS_AUDIT/offline.log" /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local unix-socket))(allow network* (remote unix-socket))' "$LS_FUNCTIONAL" work/release-audit/edge-jobs.json "$LS_AUDIT/offline/edge/results.json"
run_gate offline_content "$LS_AUDIT/offline-content.log" "$LS_PYTHON" Tests/Acceptance/check_content.py --area "$LS_AUDIT/offline"
run_gate bundle_integrity "$LS_AUDIT/bundle-integrity.log" "$LS_PYTHON" Tests/Acceptance/bundle_integrity.py after "$LS_AUDIT"
run_gate codesign "$LS_AUDIT/codesign.log" /usr/bin/codesign --verify --deep --strict LocalShift.app
if [[ "$LS_FAILURES" != 0 ]]; then printf '%s phases failed; no completion certificate generated.\n' "$LS_FAILURES"; exit 1; fi
"$LS_PYTHON" - "$LS_AUDIT" <<'PY'
from pathlib import Path
import sys,json,hashlib,datetime
area=Path(sys.argv[1]);root=Path.cwd();reports={}
for name,relative in [('regression','regression/report.json'),('matrix','matrix/results.json'),('tools','tools/results.json'),('tool_semantics','tool-semantics.json'),('edge','edge/results.json'),('content','content-semantics.json'),('images','image-semantics.json'),('pdf_route','pdf-route/report.json'),('negative','negative/report.json'),('process_tree','process-tree/report.json'),('native','native/report.json'),('native_drop','native-drop/report.json'),('offline','offline/edge/results.json'),('offline_content','offline/content-semantics.json')]:
 p=area/relative;r=json.loads(p.read_text());reports[name]={'passed':r['passed'],'failed':r['failed'],'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
 if r['failed']:raise SystemExit('Failed report: '+name)
# 回归 58：删除界面不再提供的缩放和旋转后少了 2 项。原生 31：任务排队补了 2 项。原生拖放 19：松手不误触、Shift/Command 仍打开轮盘、Control 不再打开操作轮盘、缺参数工具开编辑器、Esc 关掉残留轮盘。
expected={'regression':58,'matrix':275,'tools':32,'tool_semantics':31,'edge':21,'content':30,'images':59,'pdf_route':3,'negative':14,'process_tree':4,'native':31,'native_drop':19,'offline':21,'offline_content':30}
for name,count in expected.items():
 if reports[name]['passed']!=count:raise SystemExit('Unexpected coverage: '+name)
paths=list(Path('Sources').glob('*.swift'))+list(Path('Resources').rglob('*'))+[Path('build.sh')]
sources={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()}
if sources!=json.loads((area/'source-before.json').read_text()):raise SystemExit('Sources changed during release acceptance')
for p in Path('Resources').rglob('*'):
 if p.is_file() and p.read_bytes()!=(root/'LocalShift.app/Contents/Resources'/p.relative_to('Resources')).read_bytes():raise SystemExit('Bundled resource differs from source: '+str(p))
report={'completed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'automated_local_checks_passed','reports':reports,'source_sha256':sources,'executable_sha256':hashlib.sha256((root/'LocalShift.app/Contents/MacOS/LocalShift').read_bytes()).hexdigest(),'signature_after_tests':True,'bundle_unchanged':True,'physical_finder_drag':'not_verified','cross_device_airdrop':'not_verified','original_native_equivalence':'not_established','requires_user_manual_acceptance':False}
(area/'complete.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({'status':report['status'],'counts':{k:v['passed'] for k,v in reports.items()}},ensure_ascii=False))
PY
