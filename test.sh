#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR="${1:-${TMPDIR:-/private/tmp}/LocalShiftLegacyTests-$(date +%s)}"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "${TMPDIR:-/private/tmp}/localshift-test-module-cache" \
 -framework Cocoa -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage -framework Vision -framework AVFoundation -framework WebKit -larchive \
 Sources/EngineTypes.swift Sources/OperationContext.swift Sources/CapabilityCatalog.swift Sources/SubtitleEngine.swift Sources/FileTransfer.swift Sources/EngineRouter.swift Sources/AdvancedNative.swift Sources/AdvancedMedia.swift Sources/OfficeEngine.swift Tests/main.swift \
 -o work/legacy-regression-tests
LOCALSHIFT_RESOURCE_DIR="$PWD/LocalShift.app/Contents/Resources" LOCALSHIFT_RUNTIME_BIN="$PWD/LocalShift.app/Contents/Resources/bin" work/legacy-regression-tests "$TEST_DIR"
