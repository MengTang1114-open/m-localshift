#!/bin/bash
# Compile-only check for the acceptance harnesses. They build their own source
# subsets with swiftc, so a refactor can break them without breaking `swift build`.
# Running them still needs the full runtime on a Mac: see Tests/Acceptance/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
FLAGS=(-swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$OUT/module-cache" -framework Cocoa -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage -framework Vision -framework AVFoundation -framework WebKit -larchive)
ENGINE=(Sources/EngineTypes.swift Sources/OperationContext.swift Sources/CapabilityCatalog.swift Sources/SubtitleEngine.swift Sources/FileTransfer.swift Sources/EngineRouter.swift Sources/AdvancedNative.swift Sources/AdvancedMedia.swift Sources/OfficeEngine.swift)
UI=(); for source in Sources/*.swift; do [[ "$source" != Sources/AppMain.swift ]] && UI+=("$source"); done
compile() { local name="$1"; shift; printf 'compile %s\n' "$name"; xcrun swiftc "${FLAGS[@]}" "$@" -o "$OUT/$name"; }
compile regression "${ENGINE[@]}" Tests/main.swift
compile functional "${ENGINE[@]}" Tests/Functional/main.swift
compile negative "${ENGINE[@]}" Tests/Acceptance/main.swift
compile process-tree Sources/EngineTypes.swift Sources/OperationContext.swift Tests/Acceptance/process-tree/main.swift
compile native-drop "${UI[@]}" Tests/Acceptance/native-drop/main.swift
compile media Sources/EngineTypes.swift Sources/OperationContext.swift Sources/AdvancedMedia.swift Tests/Acceptance/media-fixes/main.swift
compile office Sources/EngineTypes.swift Sources/OperationContext.swift Sources/OfficeEngine.swift Tests/Acceptance/office-fixes/main.swift
compile multipage Sources/EngineTypes.swift Sources/OperationContext.swift Sources/AdvancedNative.swift Tests/Acceptance/multipage-image/Probe.swift
echo 'All acceptance harnesses compile.'
