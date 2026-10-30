import Combine
import Cocoa
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Semantic colours only, so light and dark mode and the user's accent colour just work.
// Accent is reserved for the one thing to press next; everything else stays neutral.
enum Theme {
    static let accent = Color.accentColor
    static let canvas = Color(nsColor: LSPaint.canvas)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let text = Color(nsColor: LSPaint.text)
    static let muted = Color(nsColor: LSPaint.muted)
    static let line = Color(nsColor: .separatorColor)
    static let border = line
    static let fill = Color.primary.opacity(0.06)
    static let danger = Color(nsColor: .systemRed)
}

struct LSMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// Frosted panel: system material, a light top edge instead of a grey outline, and a soft lift.
struct GlassCard: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.18 : 0.75), .white.opacity(scheme == .dark ? 0.04 : 0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.07), radius: 16, y: 6)
    }
}

extension View {
    func glassCard(radius: CGFloat = 14) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

// A faint wash of the accent and the brand yellow, so the glass has something to refract.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [Theme.accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear], center: UnitPoint(x: 0.75, y: 0.28), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color(nsColor: LSIcon.trioYellow).opacity(scheme == .dark ? 0.06 : 0.09), .clear], center: UnitPoint(x: 0.2, y: 1.0), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

struct FileItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var isDemo: Bool
    var name: String { url.lastPathComponent }
    var category: FileCategory { ConverterEngine.category(for: url) }
    init(id: UUID = UUID(), url: URL, isDemo: Bool = false) {
        self.id = id
        self.url = url.standardizedFileURL
        self.isDemo = isDemo
    }
}

struct HistoryRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var optionID: String
    var optionTitle: String
    var sources: [String]
    var outputs: [String]
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case convert, recent, guide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .convert: return "转换文件"
        case .recent: return "最近完成"
        case .guide: return "使用说明"
        }
    }
    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .recent: return "clock"
        case .guide: return "info.circle"
        }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var section: SidebarSection = .convert
    @Published var files: [FileItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var wheelMode: WheelMode = .conversion
    @Published var selectedOptionID: String?
    @Published var hoveredOption: ConversionOption?
    @Published var settings = ConversionSettings()
    @Published var isConverting = false
    @Published var progress: Double = 0
    @Published var progressMessage = ""
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var history: [HistoryRecord] = []
    @Published var overlayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(overlayEnabled, forKey: Self.overlayKey)
            DragWheelMonitor.shared.isEnabled = overlayEnabled
        }
    }
    @Published var isDemo = false
    @Published var dropTargeted = false
    @Published var editingTool: LSToolSession?
    @Published var terminalApplication = UserDefaults.standard.string(forKey: "LocalShiftTerminal") ?? "Terminal" { didSet { UserDefaults.standard.set(terminalApplication, forKey: "LocalShiftTerminal") } }
    @Published var dependencies: [String: Bool] = [:]
    /// Jobs waiting for the running one; each must call `finishJob()` on the main queue when it ends.
    @Published private var pendingJobs: [() -> Void] = []
    var queuedCount: Int { pendingJobs.count }

    private let convertQueue = DispatchQueue(label: "localshift.convert", qos: .userInitiated)
    private static let overlayKey = "LocalShiftOverlayEnabled"
    private static let historyCap = 80

    var selectedFiles: [FileItem] {
        let chosen = files.filter { selectedIDs.contains($0.id) }
        return chosen.isEmpty ? files : chosen
    }

    var selectedURLs: [URL] { selectedFiles.map(\.url) }

    var currentOptions: [ConversionOption] {
        Self.commonOptions(for: selectedURLs, mode: wheelMode)
    }

    var selectedOption: ConversionOption? {
        currentOptions.first(where: { $0.id == selectedOptionID }) ?? currentOptions.first
    }

    var ffmpegAvailable: Bool { dependencies["FFmpeg"] ?? false }

    var errorSummary: String? {
        guard let error = errorMessage, !error.isEmpty else { return nil }
        return ErrorHint.summary(for: error)
    }

    init() {
        let defaults = UserDefaults.standard
        overlayEnabled = defaults.object(forKey: Self.overlayKey) == nil ? true : defaults.bool(forKey: Self.overlayKey)
        history = HistoryStore.load()
        refreshDependencies()
    }

    func refreshDependencies() {
        dependencies = ConverterEngine.dependencies()
    }

    static func commonOptions(for urls: [URL], mode: WheelMode) -> [ConversionOption] {
        guard let first = urls.first else { return [] }
        var options = ConverterEngine.options(for: first, mode: mode)
        for url in urls.dropFirst() {
            let ids = Set(ConverterEngine.options(for: url, mode: mode).map(\.id))
            options = options.filter { ids.contains($0.id) }
        }
        return options
    }

    func addFiles(_ urls: [URL]) {
        var existing = Set(files.map { $0.url.path })
        var added: [FileItem] = []
        for url in urls {
            guard url.isFileURL else { continue }
            let standardized = url.standardizedFileURL
            guard existing.insert(standardized.path).inserted else { continue }
            added.append(FileItem(url: standardized))
        }
        guard !added.isEmpty else { return }
        files.append(contentsOf: added)
        selectedIDs.formUnion(added.map(\.id))
        reconcileOption()
        errorMessage = nil
        noticeMessage = nil
    }

    func removeSelected() {
        files.removeAll { selectedIDs.contains($0.id) }
        selectedIDs.removeAll()
        if let first = files.first { selectedIDs = [first.id] }
        reconcileOption()
    }

    func clearList() {
        files.removeAll()
        selectedIDs.removeAll()
        selectedOptionID = nil
        errorMessage = nil
        noticeMessage = "列表已清空；磁盘上的文件没有改动。"
    }

    func loadDemo() {
        isDemo = true
        files = [
            FileItem(url: URL(fileURLWithPath: "/tmp/LocalShiftDemo/landscape.jpg"), isDemo: true),
            FileItem(url: URL(fileURLWithPath: "/tmp/LocalShiftDemo/notes.pdf"), isDemo: true),
            FileItem(url: URL(fileURLWithPath: "/tmp/LocalShiftDemo/clip.mov"), isDemo: true)
        ]
        selectedIDs = Set(files.prefix(1).map(\.id))
        noticeMessage = "示例，尚未转换"
        reconcileOption()
    }

    func reconcileOption() {
        let ids = Set(currentOptions.map(\.id))
        if let selectedOptionID = selectedOptionID, ids.contains(selectedOptionID) { return }
        selectedOptionID = currentOptions.first?.id
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要转换或处理的文件。原文件会留在原地。"
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此文件夹"
        panel.message = "转换结果将保存到这里。已有同名文件不会被覆盖。"
        if panel.runModal() == .OK { settings.outputDirectory = panel.url }
    }

    func applyFromWheel(urls: [URL], option: ConversionOption, mode: WheelMode) {
        DispatchQueue.main.async {
            self.section = .convert
            self.addFiles(urls)
            let addedPaths = Set(urls.map { $0.standardizedFileURL.path })
            self.selectedIDs = Set(self.files.filter { addedPaths.contains($0.url.path) }.map(\.id))
            self.wheelMode = mode
            self.selectedOptionID = option.id
            if mode == .tools, Self.wheelNeedsEditor(option.id, settings: self.settings) {
                // A release cannot supply a crop box, marks or cut points: open the editor on top of the main window.
                AppDelegate.shared?.showMainWindow()
                self.openEditor(option: option, urls: urls)
            } else {
                self.run(option: option, urls: urls, mode: mode)
            }
        }
    }

    /// Tools that need a person's input before they can run. Running them from a wheel
    /// release would silently write a default result, such as a centered 16:9 crop.
    static func wheelNeedsEditor(_ id: String, settings: ConversionSettings) -> Bool {
        switch id {
        case "annotateImage": return settings.annotations.isEmpty
        case "redactImage", "redactVideo": return settings.redactions.isEmpty && !settings.detectFaces && !settings.detectText
        case "redactAudio": return settings.bleepRanges.isEmpty
        case "cropImage", "cropVideo": return settings.cropRect == nil
        case "splitVideo": return settings.splitPoints.isEmpty
        case "editImage":
            let plain = ConversionSettings()
            return settings.exposure == plain.exposure && settings.brightness == plain.brightness
                && settings.saturation == plain.saturation && settings.contrast == plain.contrast
                && settings.sharpness == plain.sharpness && settings.sepia == plain.sepia && settings.vignette == plain.vignette
        default: return false
        }
    }

    func runCurrent() {
        guard let option = selectedOption else {
            errorMessage = "请先选择一个输出格式或工具。"
            return
        }
        if wheelMode == .tools { openEditor(option: option, urls: selectedURLs) }
        else { run(option: option, urls: selectedURLs, mode: wheelMode) }
    }

    func openEditor(option: ConversionOption, urls: [URL]) {
        guard !urls.isEmpty else { return }
        if option.id == "readQRCode" { run(option: option, urls: urls, mode: .tools); return }
        editingTool = LSToolSession(option: option, urls: urls, settings: settings)
    }

    func run(option: ConversionOption, urls: [URL], mode: WheelMode) {
        let targets = urls.isEmpty ? selectedURLs : urls
        guard !targets.isEmpty else {
            presentFailure("请先添加文件。")
            return
        }
        let targetPaths = Set(targets.map(\.path))
        if files.contains(where: { $0.isDemo && targetPaths.contains($0.url.path) }) {
            noticeMessage = "示例，尚未转换。请添加这台 Mac 上的真实文件。"
            errorMessage = nil
            AppDelegate.shared?.showMainWindow()
            return
        }
        errorMessage = nil
        noticeMessage = nil
        if ["mergePDF", "joinVideos", "createCollage"].contains(option.id), targets.count < 2 {
            presentFailure("此工具需要至少两个文件；可在编辑器中添加并排序。")
            return
        }
        if mode == .actions {
            performAction(option.id, urls: targets)
            return
        }
        let snapshot = settings
        enqueue { self.convert(targets, option: option, settings: snapshot) }
    }

    private func convert(_ targets: [URL], option: ConversionOption, settings snapshot: ConversionSettings) {
        progress = 0
        progressMessage = "开始处理…"
        convertQueue.async {
            do {
                let outputs = try ConverterEngine.convert(targets, option: option.id, settings: snapshot) { value, message in
                    DispatchQueue.main.async {
                        self.progress = value
                        self.progressMessage = message
                    }
                }
                DispatchQueue.main.async {
                    self.progress = 1
                    self.progressMessage = "已完成 \(outputs.count) 个结果"
                    self.recordHistory(option: option, sources: targets, outputs: outputs)
                    self.section = .recent
                    self.finishJob()
                }
            } catch {
                DispatchQueue.main.async {
                    if let converter = error as? ConverterError, case .cancelled = converter {
                        let text = converter.errorDescription ?? "已取消；原文件保持不变。"
                        self.progressMessage = text
                        self.noticeMessage = text
                        self.errorMessage = nil
                    } else {
                        self.errorMessage = error.localizedDescription
                        self.progressMessage = ""
                        AppDelegate.shared?.showMainWindow()
                    }
                    self.finishJob()
                }
            }
        }
    }

    /// Starts `job` now, or queues it behind the running one.
    private func enqueue(_ job: @escaping () -> Void) {
        if isConverting {
            pendingJobs.append(job)
            noticeMessage = "已加入队列，前面还有 \(pendingJobs.count) 个任务。"
            return
        }
        isConverting = true
        job()
    }

    private func finishJob() {
        guard !pendingJobs.isEmpty else {
            isConverting = false
            return
        }
        pendingJobs.removeFirst()()
    }

    /// Cancels the running job and drops everything queued behind it.
    func cancelRunning() {
        let dropped = pendingJobs.count
        pendingJobs.removeAll()
        progressMessage = "正在取消…文件复制将在当前文件完成后停止。" + (dropped > 0 ? "排队的 \(dropped) 个任务已移除。" : "")
        ConverterEngine.cancel()
    }

    private func recordHistory(option: ConversionOption, sources: [URL], outputs: [URL]) {
        let record = HistoryRecord(
            id: UUID(),
            date: Date(),
            optionID: option.id,
            optionTitle: option.title,
            sources: sources.map(\.path),
            outputs: outputs.map(\.path)
        )
        history.insert(record, at: 0)
        if history.count > Self.historyCap {
            history = Array(history.prefix(Self.historyCap))
        }
        HistoryStore.save(history)
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            errorMessage = "找不到文件：\(url.lastPathComponent)"
        }
    }

    func revealOutputs(_ record: HistoryRecord) {
        let existing = record.outputs.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            errorMessage = "这些结果已不在原来的位置。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    var showsQuality: Bool {
        guard let id = selectedOption?.id else { return false }
        return id == "compress" || id == "format_jpg" || id == "format_webp" || id == "format_heic" || id == "format_gif"
    }

    var showsSize: Bool {
        ["resize", "crop"].contains(selectedOption?.id ?? "")
    }

    var showsTrim: Bool { selectedOption?.id == "trim" }
    var showsSpeed: Bool { selectedOption?.id == "speed" }

    func performAction(_ id: String, urls: [URL]) {
        do {
            switch id {
            case "airdrop": try airDrop(urls)
            case "float": float(urls)
            case "copy": try copyFiles(urls)
            case "move": try moveFiles(urls)
            case "copyPath": copyPaths(urls)
            case "terminal": try openTerminal(urls)
            default: throw ConverterError.message("未知操作。")
            }
        } catch {
            presentFailure(error.localizedDescription)
        }
    }

    private func presentFailure(_ message: String) {
        errorMessage = message
        noticeMessage = nil
        AppDelegate.shared?.showMainWindow()
    }

    private func airDrop(_ urls: [URL]) throws {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            throw ConverterError.message("当前系统没有提供 AirDrop 服务。")
        }
        guard service.canPerform(withItems: urls) else {
            throw ConverterError.message("当前无法使用 AirDrop。请确认无线局域网或蓝牙已打开。")
        }
        service.perform(withItems: urls)
        noticeMessage = "已打开 AirDrop。"
    }

    private func float(_ urls: [URL]) {
        LSFloatShelf.shared.show(urls)
        noticeMessage = "已加入暂存架；可以拖出文件或固定在屏幕边缘。"
    }

    private func copyFiles(_ urls: [URL]) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects(urls.map { $0 as NSURL }) else {
            throw ConverterError.message("无法将文件写入剪贴板。")
        }
        noticeMessage = "已复制 \(urls.count) 个文件，可在 Finder 中粘贴。"
    }

    private func moveFiles(_ urls: [URL]) throws {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目标"
        panel.message = "移动原文件。目标位置若已有同名文件，将停止且不覆盖。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let names = urls.map(\.lastPathComponent).joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "移动这些文件？"
        alert.informativeText = "将 \(names) 移动到 \(folder.path)。此操作会改动原位置。"
        alert.addButton(withTitle: "移动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        transfer(urls, to: folder, move: true)
    }

    private func transfer(_ urls: [URL], to folder: URL, move: Bool) {
        enqueue { self.performTransfer(urls, to: folder, move: move) }
    }

    private func performTransfer(_ urls: [URL], to folder: URL, move: Bool) {
        progress = 0
        progressMessage = move ? "正在移动…" : "正在复制…"
        convertQueue.async {
            do {
                let outputs = try FileTransfer.perform(urls, to: folder, move: move) { value, message in
                    DispatchQueue.main.async { self.progress = value; self.progressMessage = message }
                }
                DispatchQueue.main.async {
                    self.progress = 1
                    self.progressMessage = "已完成 \(outputs.count) 个项目"
                    if move {
                        let paths = Set(urls.map(\.path))
                        self.files.removeAll { paths.contains($0.url.path) }
                        self.selectedIDs = self.selectedIDs.intersection(Set(self.files.map(\.id)))
                    }
                    let option = ConversionOption(id: move ? "move" : "copy", title: move ? "移动" : "复制", subtitle: "", symbol: "folder")
                    self.recordHistory(option: option, sources: urls, outputs: outputs)
                    self.section = .recent
                    self.finishJob()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.progressMessage = ""
                    AppDelegate.shared?.showMainWindow()
                    self.finishJob()
                }
            }
        }
    }

    private func copyPaths(_ urls: [URL]) {
        DragWheelMonitor.shared.copyPathResolvingDrag(urls.map(\.path).joined(separator: "\n"))
        noticeMessage = "已复制路径。"
    }

    private func openTerminal(_ urls: [URL]) throws {
        var directories = Set<URL>()
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.insert(url)
            } else {
                directories.insert(url.deletingLastPathComponent())
            }
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalApplication == "iTerm2" ? "com.googlecode.iterm2" : "com.apple.Terminal") else {
            throw ConverterError.message("未安装 \(terminalApplication)。请在使用说明中更换终端。")
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(Array(directories), withApplicationAt: app, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error = error { self.errorMessage = "无法启动终端：" + error.localizedDescription }
                else { self.noticeMessage = "已在 \(self.terminalApplication) 中打开所选目录。" }
            }
        }
    }
}

enum HistoryStore {
    static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["LOCALSHIFT_STATE_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalShift", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static var file: URL { folder.appendingPathComponent("history.json") }

    static func load() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
    }

    static func save(_ items: [HistoryRecord]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

enum FloatPreview {
    static func makeView(for url: URL) -> NSView {
        let category = ConverterEngine.category(for: url)
        if category == .image, let image = NSImage(contentsOf: url) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.animates = true
            return view
        }
        if category == .pdf {
            let view = PDFView()
            view.autoScales = true
            view.document = PDFDocument(url: url)
            return view
        }
        let ext = url.pathExtension.lowercased()
        if ["txt", "md", "csv", "tsv", "srt", "vtt", "html"].contains(ext) {
            return textView(string: (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取这个文件。")
        }
        if ext == "rtf", let data = try? Data(contentsOf: url), let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
            return textView(attributed: rich)
        }
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        let icon = NSImageView(image: LSIcon.fileIcon(for: url))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: 170, y: 250, width: 100, height: 100)
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.frame = NSRect(x: 20, y: 200, width: 400, height: 24)
        label.alignment = .center
        label.textColor = LSPaint.text
        wrap.addSubview(icon)
        wrap.addSubview(label)
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = LSPaint.canvas.cgColor
        return wrap
    }

    private static func textView(string: String) -> NSView {
        textView(attributed: NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: LSPaint.text
        ]))
    }

    private static func textView(attributed: NSAttributedString) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let text = NSTextView()
        text.isEditable = false
        text.isRichText = true
        text.drawsBackground = true
        text.backgroundColor = LSPaint.canvas
        text.textStorage?.setAttributedString(attributed)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 216)
            Group {
                switch model.section {
                case .convert: ConvertView()
                case .recent: RecentView()
                case .guide: GuideView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AmbientBackground())
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(item: $model.editingTool) { session in
            LSToolEditor(session: session) { settings, urls in
                model.settings = settings
                model.editingTool = nil
                model.run(option: session.option, urls: urls, mode: .tools)
            }
        }
        .onChange(of: model.files) { _ in model.reconcileOption() }
        .onChange(of: model.wheelMode) { _ in model.reconcileOption() }
        .onChange(of: model.selectedIDs) { _ in model.reconcileOption() }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: LSIcon.appMark(size: 34))
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LocalShift").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    Text("文件留在这台 Mac").font(.system(size: 11)).foregroundColor(Theme.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 22)

            ForEach(SidebarSection.allCases) { section in
                Button(action: { model.section = section }) {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .foregroundColor(Theme.accent)
                            .frame(width: 18)
                        Text(section.title)
                            .foregroundColor(Theme.text)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.section == section ? Color.primary.opacity(0.09) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 7) {
                statusRow("FFmpeg", model.ffmpegAvailable ? "本机可用" : "未安装", on: model.ffmpegAvailable)
                statusRow("拖放轮盘", model.overlayEnabled ? "已启用" : "已关闭", on: model.overlayEnabled)
                Label("转换在本地完成，不会上传。", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(LSMaterial(material: .sidebar).ignoresSafeArea())
    }

    private func statusRow(_ title: String, _ value: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color(nsColor: .systemGreen) : Theme.muted.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(title).foregroundColor(Theme.muted)
            Spacer()
            Text(value).foregroundColor(Theme.text)
        }
        .font(.system(size: 11))
    }
}

struct ConvertView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.files.isEmpty {
                EmptyDropView()
            } else {
                HStack(alignment: .top, spacing: 0) {
                    FileListPane()
                        .glassCard(radius: 16)
                        .frame(width: 268)
                        .padding(.leading, 14)
                        .padding(.vertical, 14)
                    WheelPane()
                }
            }
            TaskBar()
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = {
                    if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                        return URL(string: text)
                    }
                    if let url = item as? URL { return url }
                    if let text = item as? String { return URL(string: text) }
                    return nil
                }()
                guard let url = url else { return }
                DispatchQueue.main.async { model.addFiles([url]) }
            }
        }
    }
}

struct EmptyDropView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 18) {
                Image(nsImage: LSIcon.appMark(size: 104))
                    .resizable()
                    .frame(width: 104, height: 104)
                VStack(spacing: 8) {
                    Text("把文件放在这里")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("拖入文件，选择格式，轻松完成转换。")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                }
                Button("选择文件…") { model.chooseFiles() }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 6)
            }
            .frame(maxWidth: 460, minHeight: 330)
            .glassCard(radius: 28)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(model.dropTargeted ? 0.55 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            )
            .scaleEffect(model.dropTargeted ? 1.015 : 1)
            .animation(.easeOut(duration: 0.18), value: model.dropTargeted)
            .padding(40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileListPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("\(model.files.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.muted)
                Spacer()
                Button("添加") { model.chooseFiles() }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if model.isDemo {
                Text("示例，尚未转换")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.muted)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            List(selection: $model.selectedIDs) {
                ForEach(model.files) { item in
                    FileRow(item: item)
                        .tag(item.id)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                Button("删除选中") { model.removeSelected() }
                    .disabled(model.selectedIDs.isEmpty)
                Button("清空列表") { model.clearList() }
                    .disabled(model.files.isEmpty)
            }
            .buttonStyle(QuietButtonStyle())
            .padding(12)
        }
    }
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: LSIcon.fileIcon(for: item.url))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(item.isDemo ? "示例 · \(item.category.displayName)" : item.category.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
            Spacer()
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

struct WheelPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
        VStack(spacing: 10) {
            ModeTabs()
                .padding(.top, 14)
            RadialWheelHost(
                options: model.currentOptions,
                selectedID: model.selectedOption?.id,
                centerTitle: centerTitle,
                centerSubtitle: centerSubtitle,
                centerImage: centerImage,
                onSelect: { option in
                    model.selectedOptionID = option.id
                },
                onHover: { option in
                    model.hoveredOption = option
                }
            )
            .frame(width: 360, height: 360)

            if model.currentOptions.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Text(statusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.text)
            }

            SettingsStrip()
            Button(actionLabel) { model.runCurrent() }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedOption == nil)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var centerTitle: String {
        if model.selectedFiles.count == 1 { return model.selectedFiles[0].name }
        if model.selectedFiles.isEmpty { return "文件" }
        return "\(model.selectedFiles.count) 个文件"
    }

    private var centerSubtitle: String {
        if model.selectedFiles.count == 1 { return model.selectedFiles[0].category.displayName }
        return ""
    }

    private var centerImage: NSImage? {
        model.selectedFiles.first.map { LSIcon.fileIcon(for: $0.url) }
    }

    private var statusLine: String {
        guard let option = model.hoveredOption ?? model.selectedOption else { return "" }
        switch model.wheelMode {
        case .conversion: return "输出 \(option.title)  ·  \(option.subtitle)"
        case .tools: return "\(option.title)  ·  \(option.subtitle)"
        case .actions: return "\(option.title)  ·  \(option.subtitle)"
        }
    }

    private var actionLabel: String {
        guard let option = model.selectedOption else { return "选择一个选项" }
        switch model.wheelMode {
        case .conversion: return "转换为 \(option.title)"
        case .tools: return option.title
        case .actions: return "执行 \(option.title)"
        }
    }

    private var emptyHint: String {
        switch model.wheelMode {
        case .conversion: return "所选文件没有共同的转换格式。请按类型分别处理。"
        case .tools: return "所选文件没有共同的工具。音视频工具需要本机 FFmpeg。"
        case .actions: return "没有可用操作。"
        }
    }
}

struct ModeTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("工作模式", selection: $model.wheelMode) {
            Text(LSModifierStore.label(.conversion) + "  转换").tag(WheelMode.conversion)
            Text(LSModifierStore.label(.tools) + "  工具").tag(WheelMode.tools)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .controlSize(.large)
    }
}

struct SettingsStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(outputLabel)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
                Spacer()
                Button("选择输出目录") { model.chooseOutputDirectory() }
                    .buttonStyle(QuietButtonStyle())
                if model.settings.outputDirectory != nil {
                    Button("改回原位置") { model.settings.outputDirectory = nil }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            if model.showsQuality {
                HStack {
                    Text("质量 \(Int(model.settings.quality * 100))%")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                        .frame(width: 78, alignment: .leading)
                    Slider(value: $model.settings.quality, in: 0.1...1)
                        .tint(Theme.accent)
                }
            }
            if model.showsSize {
                HStack {
                    labeledInt("宽", $model.settings.width)
                    labeledInt("高", $model.settings.height)
                }
            }
            if model.showsTrim {
                HStack {
                    labeledDouble("起始秒", $model.settings.startSeconds)
                    labeledDouble("结束秒", $model.settings.endSeconds)
                }
            }
            if model.showsSpeed {
                HStack {
                    Text("速度")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                    Slider(value: $model.settings.speed, in: 0.5...2)
                        .tint(Theme.accent)
                    Text(String(format: "%.2f×", model.settings.speed))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.text)
                }
            }
        }
        .padding(12)
        .glassCard(radius: 14)
        .padding(.horizontal, 24)
    }

    private var outputLabel: String {
        if let directory = model.settings.outputDirectory {
            return "输出到 \(directory.path)"
        }
        return "输出到每个源文件所在文件夹（不覆盖）"
    }

    private func labeledInt(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundColor(Theme.muted)
            TextField(title, value: value, formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }

    private func labeledDouble(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundColor(Theme.muted)
            TextField(title, value: value, formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }
}

struct TaskBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showsErrorDetails = false

    private var hasContent: Bool {
        model.isConverting || !model.progressMessage.isEmpty || model.errorMessage != nil || !(model.noticeMessage ?? "").isEmpty
    }

    var body: some View {
        if hasContent {
            bar
                .glassCard(radius: 14)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isConverting {
                HStack(spacing: 10) {
                    ProgressView(value: min(max(model.progress, 0), 1))
                        .tint(Theme.accent)
                    Text(model.progressMessage + (model.queuedCount > 0 ? "（另有 \(model.queuedCount) 个排队）" : ""))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Button("取消") { model.cancelRunning() }
                        .buttonStyle(QuietButtonStyle())
                }
            } else if !model.progressMessage.isEmpty {
                Text(model.progressMessage)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
            if let error = model.errorMessage, let summary = model.errorSummary {
                Label(summary, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if error != summary {
                    DisclosureGroup("详细信息", isExpanded: $showsErrorDetails) {
                        ScrollView {
                            Text(error)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                }
            } else if let notice = model.noticeMessage, !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .onChange(of: model.errorMessage) { _ in showsErrorDetails = false }
    }
}

struct RecentView: View {
    @EnvironmentObject var model: AppModel
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近完成")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            Text("只记录文件路径，不会把内容复制进应用目录。")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            if model.history.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("还没有完成的转换。")
                        .foregroundColor(Theme.muted)
                    Spacer()
                }
                Spacer()
            } else {
                List(model.history) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.optionTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.text)
                            Spacer()
                            Text(stamp.string(from: record.date))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.muted)
                        }
                        Text(record.outputs.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text)
                            .lineLimit(2)
                        HStack {
                            Button("在 Finder 中显示") { model.revealOutputs(record) }
                                .buttonStyle(QuietButtonStyle())
                            if let first = record.outputs.first {
                                Text(first)
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .glassCard(radius: 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

struct GuideView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("使用说明")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("添加文件后，选择轮盘上的格式，再按回车转换。结果会另存为新文件；同名文件自动编号。可用格式会随这台 Mac 的处理能力调整。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)

                card("键盘与拖放") {
                    LSShortcutPreferences()
                    labeled("松开鼠标", "指针靠近格子后松开即执行，转换和工具都一样。成功不打开主窗口，出错才打开")
                    labeled("Esc", "取消当前轮盘；某些来源可能无法传递按键状态")
                }

                Toggle("启用拖放轮盘", isOn: $model.overlayEnabled)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .foregroundColor(Theme.text)

                card("本机依赖") {
                    ForEach(model.dependencies.keys.sorted(), id: \.self) { key in
                        labeled(key, model.dependencies[key] == true ? "可用" : "不可用")
                    }
                }

                card("当前可转换的格式") {
                    capability("图片", "jpg", .conversion)
                    capability("视频", "mp4", .conversion)
                    capability("音频", "mp3", .conversion)
                    capability("PDF", "pdf", .conversion)
                    capability("文档", "txt", .conversion)
                    capability("表格", "csv", .conversion)
                    capability("字幕", "srt", .conversion)
                    capability("归档", "zip", .conversion)
                }

                card("当前工具") {
                    capability("图片", "png", .tools)
                    capability("视频", "mov", .tools)
                    capability("音频", "wav", .tools)
                    capability("PDF", "pdf", .tools)
                    capability("归档", "zip", .tools)
                }

                card("格式说明") {
                    Text("可用格式随本机依赖调整。JPEG 无透明通道。文档转 PDF 可能重新排版；请检查导出的内容和版式。工具编辑器中点击应用后才创建结果。")
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                }
            }
            .padding(24)
        }
        .onAppear { model.refreshDependencies() }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 16)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundColor(Theme.text).frame(width: 160, alignment: .leading)
            Text(value).foregroundColor(Theme.muted)
            Spacer()
        }
        .font(.system(size: 12))
    }

    private func capability(_ title: String, _ sampleExt: String, _ mode: WheelMode) -> some View {
        let names = ConverterEngine.options(for: URL(fileURLWithPath: "/tmp/sample." + sampleExt), mode: mode).map(\.title)
        return labeled(title, names.isEmpty ? "（当前环境没有可用项）" : names.joined(separator: " · "))
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(isEnabled ? 1 : 0.75))
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
            .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)).allowsHitTesting(false))
            .shadow(color: Theme.accent.opacity(isEnabled ? 0.28 : 0), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.text.opacity(isEnabled ? 1 : 0.35))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)))
    }
}
