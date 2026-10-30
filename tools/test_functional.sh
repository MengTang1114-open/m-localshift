#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "${TMPDIR:-/private/tmp}/localshift-test-module-cache" \
 -framework Cocoa -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage -framework Vision -framework AVFoundation -framework WebKit -larchive \
 Sources/EngineTypes.swift Sources/OperationContext.swift Sources/CapabilityCatalog.swift Sources/SubtitleEngine.swift Sources/FileTransfer.swift Sources/EngineRouter.swift Sources/AdvancedNative.swift Sources/AdvancedMedia.swift Sources/OfficeEngine.swift Tests/Functional/main.swift \
 -o work/functional-tests
LOCALSHIFT_RESOURCE_DIR="$PWD/LocalShift.app/Contents/Resources" LOCALSHIFT_RUNTIME_BIN="$PWD/LocalShift.app/Contents/Resources/bin" work/functional-tests "$@"
