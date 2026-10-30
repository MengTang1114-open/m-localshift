import Cocoa
import SwiftUI
import ImageIO

@main
enum LocalShiftMain {
    static func main() {
        let app = NSApplication.shared
        // tools/screenshots.sh only: render dark mode without touching the system setting.
        if ProcessInfo.processInfo.environment["LOCALSHIFT_APPEARANCE"] == "dark" {
            app.appearance = NSAppearance(named: .darkAqua)
        }
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var overlayToggleItem: NSMenuItem?
    private var snapshotPath: String?
    private var snapshotOverlay: NSPanel?
    private var snapshotSection: String?
    private var snapshotCompact = false
    private var demoMode = false
    private var verificationRoot: String?
    private var openURLs: [URL] = []
    private var initialTool: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments()
        buildMenu()
        AppModel.shared.refreshDependencies()
        if demoMode { AppModel.shared.loadDemo() }
        if !openURLs.isEmpty { AppModel.shared.addFiles(openURLs) }
        buildWindow()
        if snapshotPath != nil {
            if snapshotSection == "guide" { AppModel.shared.section = .guide }
            if snapshotSection == "recent" { AppModel.shared.section = .recent }
            if snapshotSection == "shelf" { LSFloatShelf.shared.show(openURLs) }
            if snapshotSection == "overlay", let window = window {
                // A synthetic backdrop makes the native blur visible without capturing other apps.
                let stage = NSView(frame: window.contentView!.bounds)
                stage.wantsLayer = true
                let gradient = CAGradientLayer(); gradient.frame = stage.bounds
                gradient.colors = [NSColor(srgbRed: 0.45, green: 0.70, blue: 0.94, alpha: 1).cgColor, NSColor(srgbRed: 0.88, green: 0.67, blue: 0.85, alpha: 1).cgColor, NSColor(srgbRed: 0.98, green: 0.83, blue: 0.64, alpha: 1).cgColor]
                gradient.startPoint = CGPoint(x: 0, y: 0); gradient.endPoint = CGPoint(x: 1, y: 1)
                stage.layer?.addSublayer(gradient)
                for index in 0..<12 {
                    let stripe = CALayer(); stripe.frame = CGRect(x: 25 + index * 90, y: 0, width: 20, height: Int(stage.bounds.height))
                    stripe.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
                    stage.layer?.addSublayer(stripe)
                }
                window.contentView = stage; window.orderFrontRegardless()
                snapshotOverlay = DragWheelMonitor.shared.previewForSnapshot(urls: openURLs, centeredAt: NSPoint(x: window.frame.midX, y: window.frame.midY))
            }
            if snapshotCompact { window?.setContentSize(NSSize(width: 900, height: 600)) }
        }
        if let tool = initialTool, let first = openURLs.first {
            let option = CapabilityCatalog.option(tool)
            if ConverterEngine.options(for: first, mode: .tools).contains(where: { $0.id == tool }) {
                AppModel.shared.wheelMode = .tools; AppModel.shared.selectedOptionID = tool
                DispatchQueue.main.async { AppModel.shared.openEditor(option: option, urls: self.openURLs) }
            }
        }
        if snapshotPath == nil && verificationRoot == nil { buildStatusItem() }
        if AppModel.shared.overlayEnabled && snapshotPath == nil && verificationRoot == nil {
            DragWheelMonitor.shared.start()
        }
        if snapshotPath == nil && verificationRoot == nil { NSApp.activate(ignoringOtherApps: true) }
        if let root = verificationRoot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.verifyNative(root: root) }
            return
        }
        if let snapshotPath = snapshotPath {
            // LOCALSHIFT_SNAPSHOT_HOLD keeps the window up for `screencapture`, which records the real blur.
            let hold = Double(ProcessInfo.processInfo.environment["LOCALSHIFT_SNAPSHOT_HOLD"] ?? "") ?? 0
            let snapshotDelay = (initialTool == nil ? 0.70 : 2.2) + hold
            DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDelay) { [weak self] in
                self?.writeSnapshot(to: snapshotPath)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + snapshotDelay + 0.4) {
                // A tool sheet can defer application termination. Dismiss it first so
                // screenshot automation exits without leaving a modal session alive.
                AppModel.shared.editingTool = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSApp.terminate(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.addFiles(urls); showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DragWheelMonitor.shared.stop(); ConverterEngine.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isConverting else { return .terminateNow }
        AppModel.shared.cancelRunning()
        let deadline = Date().addingTimeInterval(5)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if !AppModel.shared.isConverting || Date() > deadline {
                timer.invalidate(); NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc func showMainWindow() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        if snapshotPath == nil && verificationRoot == nil { NSApp.activate(ignoringOtherApps: true) }
    }

    @objc func openFiles(_ sender: Any?) {
        showMainWindow()
        AppModel.shared.section = .convert
        AppModel.shared.chooseFiles()
    }

    @objc func chooseOutput(_ sender: Any?) {
        showMainWindow()
        AppModel.shared.chooseOutputDirectory()
    }

    @objc func toggleOverlay(_ sender: Any?) {
        AppModel.shared.overlayEnabled.toggle()
        overlayToggleItem?.state = AppModel.shared.overlayEnabled ? .on : .off
    }

    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "LocalShift"
        alert.informativeText = "文件留在这台 Mac。\n本地转换与拖放轮盘。只展示当前引擎实际可用的能力。"
        alert.runModal()
    }

    @objc func clearList(_ sender: Any?) {
        AppModel.shared.clearList()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        overlayToggleItem?.state = AppModel.shared.overlayEnabled ? .on : .off
    }

    private func parseArguments() {
        let args = CommandLine.arguments
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--snapshot", index + 1 < args.count {
                snapshotPath = args[index + 1]
                index += 2
                continue
            }
            if arg == "--demo" { demoMode = true }
            if arg == "--snapshot-section", index + 1 < args.count { snapshotSection = args[index + 1]; index += 2; continue }
            if arg == "--snapshot-compact" { snapshotCompact = true }
            if arg == "--tool", index + 1 < args.count { initialTool = args[index + 1]; index += 2; continue }
            if arg == "--verify-ui", index + 1 < args.count {
                verificationRoot = args[index + 1]
                setenv("LOCALSHIFT_STATE_DIR", (args[index + 1] + "/state"), 1)
                index += 2; continue
            }
            if arg == "--open-file", index + 1 < args.count {
                openURLs.append(URL(fileURLWithPath: args[index + 1]))
                index += 2; continue
            }
            index += 1
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalShift"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        // The translucent sidebar runs under the traffic lights; the sidebar shows the name instead of the title bar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = LSPaint.canvas
        let root = RootView().environmentObject(AppModel.shared)
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1060, height: 720))
        self.window = window
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "LocalShift")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "LocalShift"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "打开 LocalShift", action: #selector(showMainWindow), keyEquivalent: "")
        let toggle = NSMenuItem(title: "启用拖放轮盘", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        toggle.state = AppModel.shared.overlayEnabled ? .on : .off
        overlayToggleItem = toggle
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func buildMenu() {
        let menubar = NSMenu()

        let appItem = NSMenuItem()
        menubar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 LocalShift", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 LocalShift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "退出 LocalShift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        menubar.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "打开…", action: #selector(openFiles(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "选择输出目录…", action: #selector(chooseOutput(_:)), keyEquivalent: "d")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "清空列表", action: #selector(clearList(_:)), keyEquivalent: "")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        menubar.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        menubar.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "1")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = menubar
    }

    private func writeSnapshot(to path: String) {
        guard let main = window else { return }
        let window = snapshotOverlay ?? (snapshotSection == "shelf" ? NSApp.windows.first(where: { $0.title == "LocalShift 暂存架" }) ?? main : main)
        guard let view = (window.attachedSheet ?? window).contentView else { return }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    private func verifyNative(root: String) {
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        let inputs = directory.appendingPathComponent("inputs", isDirectory: true)
        let outputs = directory.appendingPathComponent("outputs", isDirectory: true)
        var cases: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { cases.append(["name": name, "passed": passed]) }
        func finish() {
            let failed = cases.filter { $0["passed"] as? Bool != true }.count
            let report: [String: Any] = ["passed": cases.count - failed, "failed": failed, "cases": cases, "scope": "Actual AppModel, bundled WebP, history persistence, native drawing and hit testing; external Finder drag and AirDrop transfer not exercised"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("report.json"))
            }
            print("Native UI: \(cases.count - failed)/\(cases.count) passed. \(directory.path)/report.json")
            ConverterEngine.cancel(); DragWheelMonitor.shared.stop()
            exit(failed == 0 ? 0 : 1)
        }
        func awaitIdle(_ continuation: @escaping () -> Void) {
            let limit = Date().addingTimeInterval(30)
            Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { timer in
                if !AppModel.shared.isConverting { timer.invalidate(); continuation() }
                else if Date() > limit { timer.invalidate(); check("UI task deadline", false); finish() }
            }
        }
        do {
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
            let image = inputs.appendingPathComponent("本地样本.png")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            LSPaint.accent.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 200)).fill()
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: image)
            let wheel = RadialWheelView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
            for count in [3, 6, 7, 10] {
                wheel.options = (0..<count).map { ConversionOption(id: "\($0)", title: "\($0)", subtitle: "", symbol: "doc") }
                var matched = true
                for index in 0..<count {
                    for fraction in [-0.3, 0, 0.3] {
                        let angle = (Double(index) + fraction) * 2 * Double.pi / Double(count)
                        let point = NSPoint(x: 180 + sin(angle) * 112, y: 180 + cos(angle) * 112)
                        matched = matched && wheel.sector(at: point) == index
                    }
                }
                check("Wheel \(count) sectors match rendered centers and sides", matched)
            }
            let glass = LSGlassMaterialView(frame: wheel.bounds)
            wheel.glassBackdrop = glass
            for count in [3, 6, 7, 10] {
                wheel.options = (0..<count).map { ConversionOption(id: "\($0)", title: "\($0)", subtitle: "", symbol: "doc") }
                var matched = true
                for index in 0..<count {
                    let angle = Double(index) * 2 * Double.pi / Double(count)
                    let center = NSPoint(x: 180 + sin(angle) * 112, y: 180 + cos(angle) * 112)
                    matched = matched && wheel.sector(at: center) == index
                    // A fillet removes the sharp outer vertex from both drawing and dropping.
                    let slice = 360.0 / Double(count), gap = min(3.2, slice * 0.08)
                    let cornerAngle = (90 - Double(index) * slice + slice / 2 - gap) * Double.pi / 180
                    let cutout = NSPoint(x: 180 + cos(cornerAngle) * 165.5, y: 180 + sin(cornerAngle) * 165.5)
                    matched = matched && wheel.sector(at: cutout) == nil
                }
                check("Rounded glass \(count) sectors accept centers and exclude transparent corners", matched)
            }
            wheel.glassBackdrop = nil
            check("Wheel center and exterior are not drop targets", wheel.sector(at: NSPoint(x: 180, y: 180)) == nil && wheel.sector(at: NSPoint(x: 0, y: 0)) == nil)
            let clipboard = NSPasteboard.withUniqueName(); clipboard.writeObjects([image as NSURL])
            check("File URL drag decoding", PasteboardFiles.urls(from: clipboard) == [image]); clipboard.releaseGlobally()
            for item in LSUIVerification.canvasChecks() { check(item.0, item.1) }
            let model = AppModel.shared
            model.openEditor(option: CapabilityCatalog.option("cropImage"), urls: [image])
            check("Tool opens draft editor without starting conversion", model.editingTool != nil && !model.isConverting)
            model.editingTool = nil
            let shelf = LSFloatShelf.shared; let previous = shelf.urls
            shelf.append([image,image]); check("Float shelf deduplicates file references", shelf.urls.filter { $0 == image }.count == 1)
            shelf.urls.removeAll { $0 == image }; check("Removing shelf reference preserves source", FileManager.default.fileExists(atPath:image.path)); shelf.urls=previous
            check("Configured wheel modifiers are unique", Set(LSModifierStore.wheelModes.map { LSModifierStore.value($0) }).count == 2)
            for mode in LSModifierStore.wheelModes { check("Configured modifier opens \(mode.rawValue)", DragWheelMonitor.shared.modeFromFlags(LSModifierStore.flag(LSModifierStore.value(mode))) == mode) }
            check("Control alone does not open a wheel", DragWheelMonitor.shared.modeFromFlags(.control) == nil)
            check("Combined modifiers do not open wheel", DragWheelMonitor.shared.modeFromFlags([.command,.shift]) == nil)
            model.addFiles([image]); model.settings.outputDirectory = outputs; model.selectedOptionID = "format_webp"
            check("Selection exposes real WebP capability", model.selectedOption?.id == "format_webp")
            writeSnapshot(to: directory.appendingPathComponent("conversion.png").path)
            model.runCurrent()
            if let jpg = model.currentOptions.first(where: { $0.id == "format_jpg" }) {
                model.run(option: jpg, urls: [image], mode: .conversion)
            }
            check("Second job queues behind the running one", model.isConverting && model.queuedCount == 1)
            awaitIdle {
                let record = model.history.first { $0.optionID == "format_webp" }
                let path = record?.outputs.first ?? ""
                check("AppModel conversion reaches success history", model.errorMessage == nil && FileManager.default.fileExists(atPath: path))
                check("Queued job runs after the first", model.history.first?.optionID == "format_jpg" && model.queuedCount == 0)
                let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                check("Bundled WebP result decodes", source != nil)
                check("History persists across reload", HistoryStore.load() == model.history)
                self.writeSnapshot(to: directory.appendingPathComponent("history.png").path)
                model.clearList()
                check("Clear list preserves converted files", model.files.isEmpty && FileManager.default.fileExists(atPath: path))
                let corrupt = inputs.appendingPathComponent("损坏.png")
                try? "not an image".write(to: corrupt, atomically: true, encoding: .utf8)
                let before = model.history.count
                model.section = .convert; model.addFiles([corrupt]); model.selectedOptionID = "format_jpg"
                model.runCurrent()
                awaitIdle {
                    let summary = model.errorSummary ?? ""
                    check("Failed file exposes concise readable error and retains diagnostics without false history", model.errorMessage != nil && summary.contains("文件") && summary.count < 120 && !summary.contains("[png @") && (model.errorMessage?.count ?? 0) > summary.count && model.history.count == before && !model.isConverting)
                    self.writeSnapshot(to: directory.appendingPathComponent("error.png").path)
                    finish()
                }
            }
        } catch {
            check("Verification setup: \(error.localizedDescription)", false); finish()
        }
    }
}
