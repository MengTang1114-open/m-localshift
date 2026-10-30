import Cocoa
import SwiftUI
import AVKit
import QuickLookUI
import UniformTypeIdentifiers

final class LSFloatShelf: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = LSFloatShelf()
    @Published var urls: [URL] = []
    @Published var edge = "free"
    private var panel: NSPanel?
    private var previews: [NSPanel] = []
    func show(_ items: [URL]) {
        append(items)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 120, y: 180, width: 340, height: 450), styleMask: [.titled,.closable,.resizable,.utilityWindow], backing: .buffered, defer: false)
            p.title = "LocalShift 暂存架"; p.level = .floating; p.isReleasedWhenClosed = false
            p.backgroundColor = LSPaint.canvas
            p.titlebarAppearsTransparent = true
            p.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: LSFloatShelfView(shelf: self))
            p.minSize = NSSize(width: 280, height: 260); p.delegate = self
            p.center(); panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }
    func append(_ items: [URL]) {
        for url in items where url.isFileURL && !urls.contains(url.standardizedFileURL) { urls.append(url.standardizedFileURL) }
    }
    func pin(_ value: String) {
        edge = value
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        var rect = p.frame; let visible = screen.visibleFrame
        if value == "left" { rect.origin.x = visible.minX }
        if value == "right" { rect.origin.x = visible.maxX - rect.width }
        rect.origin.y = min(max(rect.origin.y, visible.minY), visible.maxY - rect.height)
        p.setFrame(rect, display: true, animate: false)
    }
    func windowDidMove(_ notification: Notification) {
        guard edge != "free", let p = panel, let screen = p.screen else { return }
        let expected = edge == "left" ? screen.visibleFrame.minX : screen.visibleFrame.maxX - p.frame.width
        if abs(p.frame.minX - expected) > 24 { edge = "free" }
    }
    func preview(_ url: URL) {
        let p = NSPanel(contentRect: NSRect(x: 100,y: 100,width: 640,height: 520), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        p.title = url.lastPathComponent; p.isReleasedWhenClosed = false; p.level = .floating
        if [.audio,.video].contains(ConverterEngine.category(for: url)) {
            let view = AVPlayerView(); view.player = AVPlayer(url: url); view.controlsStyle = .floating
            p.contentView = view
        } else if let quick = QLPreviewView(frame: p.contentView!.bounds, style: .normal) {
            quick.previewItem = url as NSURL; quick.autoresizingMask = [.width,.height]; p.contentView = quick
        } else { p.contentView = FloatPreview.makeView(for: url) }
        p.center(); p.makeKeyAndOrderFront(nil); previews.append(p)
    }
}

struct LSFloatShelfView: View {
    @ObservedObject var shelf: LSFloatShelf
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full").font(.system(size: 17)).foregroundColor(Theme.accent)
                    Text("暂存架").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                    Spacer()
                    Menu("固定边缘") {
                        Button("左侧") { shelf.pin("left") }
                        Button("右侧") { shelf.pin("right") }
                        Button("自由浮动") { shelf.pin("free") }
                    }.menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                }
                Text("拖入保存引用，拖出交给其他应用。移除只清理列表。")
                    .font(.system(size: 11)).foregroundColor(Theme.muted).lineSpacing(3)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card)
            Divider()
            ZStack {
                List {
                    ForEach(shelf.urls, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(nsImage: LSIcon.fileIcon(for: url)).resizable().frame(width: 30,height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.text).lineLimit(1)
                                Text(url.deletingLastPathComponent().lastPathComponent).font(.system(size: 10)).foregroundColor(Theme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button { shelf.preview(url) } label: { Image(systemName: "eye") }.help("预览")
                                .buttonStyle(.borderless).foregroundColor(Theme.muted)
                            Button { shelf.urls.removeAll { $0 == url } } label: { Image(systemName: "xmark") }.help("从暂存架移除")
                                .buttonStyle(.borderless).foregroundColor(Theme.muted)
                        }
                        .padding(.vertical, 7).listRowBackground(Theme.card)
                        .onDrag { LSUIEventLog.emit("shelf.drag.begin",detail:url.lastPathComponent);return NSItemProvider(object: url as NSURL) }
                        .contextMenu {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("复制文件") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.card)
                if shelf.urls.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 34, weight: .light)).foregroundColor(Theme.muted.opacity(0.55))
                        Text("将文件拖到这里").font(.system(size: 12)).foregroundColor(Theme.muted)
                    }.allowsHitTesting(false)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if shelf.edge != "free" { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundColor(Theme.accent) }
                Text("\(shelf.urls.count) 个文件 · \(shelf.edge == "free" ? "自由浮动" : "固定边缘")").font(.system(size: 10)).foregroundColor(Theme.muted)
                Spacer()
                Button("清空") { shelf.urls.removeAll() }.disabled(shelf.urls.isEmpty).controlSize(.small)
            }.padding(.horizontal, 14).padding(.vertical, 10).background(Theme.canvas)
        }
        .background(Theme.canvas).tint(Theme.accent).buttonStyle(.bordered)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Theme.accent : .clear, lineWidth: 2).padding(1).allowsHitTesting(false))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            LSUIEventLog.emit("shelf.drop.received",detail:String(providers.count))
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value,_ in
                    let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0,relativeTo: nil) }
                    if let url = url { DispatchQueue.main.async { shelf.append([url]) } }
                }
            }
            return !providers.isEmpty
        }
    }
}

enum LSModifierStore {
    static let values = ["shift","command","control","option"]
    /// Conversion and tools are the only wheels. The Control action wheel was removed.
    static let wheelModes: [WheelMode] = [.conversion, .tools]
    static let defaults: [WheelMode:String] = [.conversion:"shift",.tools:"command",.actions:"control"]
    static func value(_ mode: WheelMode) -> String { UserDefaults.standard.string(forKey: "LocalShiftModifier." + mode.rawValue) ?? defaults[mode]! }
    static func flag(_ value: String) -> NSEvent.ModifierFlags { switch value { case "command": return .command; case "control": return .control; case "option": return .option; default: return .shift } }
    static func label(_ mode: WheelMode) -> String { symbol(value(mode)) }
    static func symbol(_ value: String) -> String { ["shift":"⇧ Shift","command":"⌘ Command","control":"⌃ Control","option":"⌥ Option"][value] ?? value }
    static func set(_ value: String, for mode: WheelMode) {
        let previous = self.value(mode)
        for other in WheelMode.allCases where other != mode && self.value(other) == value { UserDefaults.standard.set(previous, forKey: "LocalShiftModifier." + other.rawValue) }
        UserDefaults.standard.set(value, forKey: "LocalShiftModifier." + mode.rawValue)
        NotificationCenter.default.post(name: NSNotification.Name("LocalShiftShortcutsChanged"), object: nil)
    }
    static func mode(_ flags: NSEvent.ModifierFlags) -> WheelMode? {
        let held = flags.intersection([.shift,.command,.control,.option])
        return wheelModes.first { held == flag(value($0)) }
    }
}
struct LSShortcutPreferences: View {
    @State private var revision = 0
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(LSModifierStore.wheelModes, id: \.rawValue) { mode in
                Picker(mode == .conversion ? "转换" : "工具", selection: Binding(get: { LSModifierStore.value(mode) }, set: { LSModifierStore.set($0, for: mode); revision += 1 })) {
                    ForEach(LSModifierStore.values,id: \.self) { Text(LSModifierStore.symbol($0)).tag($0) }
                }
            }
            Text("选择已占用的键会交换两项设置，确保转换和工具不冲突。").font(.caption).foregroundColor(.secondary)
        }.id(revision)
    }
}
