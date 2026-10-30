import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// System colours follow light/dark mode and the accent the user picked in System Settings.
enum LSPaint {
    static var accent: NSColor { .controlAccentColor }
    static var accentDeep: NSColor { NSColor.controlAccentColor.blended(withFraction: 0.3, of: .black) ?? .controlAccentColor }
    static let canvas = NSColor.windowBackgroundColor
    static let text = NSColor.labelColor
    static let muted = NSColor.secondaryLabelColor
    // Glass tones for the wheel inside the main window.
    static let tray = adaptive(light: NSColor(white: 0.45, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.05))
    static let petalTop = adaptive(light: NSColor(white: 1, alpha: 0.98), dark: NSColor(white: 1, alpha: 0.13))
    static let petalBottom = adaptive(light: NSColor(white: 1, alpha: 0.80), dark: NSColor(white: 1, alpha: 0.07))
    static let rim = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.10))
    static let hub = adaptive(light: .white, dark: NSColor(white: 0.24, alpha: 1))

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

enum LSIcon {
    static let trioBlue = NSColor(srgbRed: 35 / 255, green: 64 / 255, blue: 216 / 255, alpha: 1)
    static let trioYellow = NSColor(srgbRed: 1, green: 177 / 255, blue: 43 / 255, alpha: 1)
    static let trioWine = NSColor(srgbRed: 121 / 255, green: 8 / 255, blue: 18 / 255, alpha: 1)

    // Same tile, track and shapes as tools/make_icon.py, on the 1024-point icon grid.
    static func appMark(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 1024)
            transform.concat()
            let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
            NSGradient(starting: NSColor(srgbRed: 0.91, green: 0.92, blue: 0.95, alpha: 1), ending: .white)?.draw(in: tile, angle: 90)
            NSColor.black.withAlphaComponent(0.08).setStroke()
            tile.lineWidth = 8
            tile.stroke()
            let center = NSPoint(x: 512, y: 502)
            let track = NSBezierPath(ovalIn: NSRect(x: center.x - 150, y: center.y - 150, width: 300, height: 300))
            track.lineWidth = 14
            NSColor(srgbRed: 0.08, green: 0.12, blue: 0.24, alpha: 0.09).setStroke()
            track.stroke()
            for (path, color) in trioShapes(center: center) {
                NSGradient(starting: color, ending: color.blended(withFraction: 0.3, of: .white) ?? color)?.draw(in: path, angle: 90)
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func trioShapes(center: NSPoint) -> [(NSBezierPath, NSColor)] {
        func spot(_ degrees: CGFloat) -> NSPoint {
            let angle = degrees * .pi / 180
            return NSPoint(x: center.x + 150 * cos(angle), y: center.y + 150 * sin(angle))
        }
        func polygon(_ middle: NSPoint, radius: CGFloat, sides: Int, rotation: CGFloat, corner: CGFloat) -> NSBezierPath {
            let points = (0..<sides).map { index -> NSPoint in
                let angle = (rotation + 360 * CGFloat(index) / CGFloat(sides)) * .pi / 180
                return NSPoint(x: middle.x + radius * cos(angle), y: middle.y + radius * sin(angle))
            }
            let path = NSBezierPath()
            let last = points[sides - 1]
            path.move(to: NSPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
            for index in 0..<sides {
                path.appendArc(from: points[index], to: points[(index + 1) % sides], radius: corner)
            }
            path.close()
            return path
        }
        let top = spot(90)
        let triangle = polygon(NSPoint(x: top.x, y: top.y - 14), radius: 128, sides: 3, rotation: 90, corner: 30)
        let right = spot(-30)
        let circle = NSBezierPath(ovalIn: NSRect(x: right.x - 96, y: right.y - 96, width: 192, height: 192))
        let hexagon = polygon(spot(-150), radius: 104, sides: 6, rotation: 0, corner: 18)
        return [(hexagon, trioWine), (circle, trioYellow), (triangle, trioBlue)]
    }

    static func fileIcon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let type = UTTypeProbe.type(for: url) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

private enum UTTypeProbe {
    static func type(for url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension)
    }
}

enum PasteboardFiles {
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return uniqued(urls.map { $0.standardizedFileURL })
        }
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
            return uniqued(paths.map { URL(fileURLWithPath: $0).standardizedFileURL })
        }
        var found: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let raw = item.string(forType: .fileURL) ?? item.string(forType: NSPasteboard.PasteboardType("public.file-url")),
               let url = URL(string: raw) {
                found.append(url.standardizedFileURL)
            }
        }
        return uniqued(found)
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { $0.isFileURL && seen.insert($0.path).inserted }
    }

    static func looksLikeFileDrag(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(filenamesType) { return true }
        return types.contains(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
            || types.contains(NSPasteboard.PasteboardType("Apple URL pasteboard type"))
    }
}

// Native WindowServer blur; decoration never participates in the drag target chain.
final class LSGlassMaterialView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        alphaValue = 0.82
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RadialWheelView: NSView {
    weak var glassBackdrop: LSGlassMaterialView? { didSet { updateGlassMask(); needsDisplay = true } }
    var options: [ConversionOption] = [] { didSet { needsDisplay = true; updateGlassMask() } }
    var selectedID: String? { didSet { needsDisplay = true } }
    var centerTitle: String = "" { didSet { needsDisplay = true } }
    var centerSubtitle: String = "" { didSet { needsDisplay = true } }
    var centerImage: NSImage? { didSet { needsDisplay = true } }
    var dropEnabled = false
    var onSelect: ((ConversionOption) -> Void)?
    var onHover: ((ConversionOption?) -> Void)?
    var onCommit: ((ConversionOption, [URL]) -> Void)?
    private var accessibleOptions: [LSWheelAXElement] = []
    override func accessibilityChildren() -> [Any]? {
        if accessibleOptions.map(\.optionID) != options.map(\.id) { accessibleOptions = options.map { LSWheelAXElement(wheel: self, option: $0) } }
        return accessibleOptions
    }
    func accessibilityRect(for id: String) -> NSRect {
        guard let index = options.firstIndex(where: { $0.id == id }), !options.isEmpty else { return .zero }
        let outer = min(bounds.width,bounds.height)*0.46,inner = outer*0.34,r=inner+(outer-inner)*0.58
        let angle=(90.0-360.0*Double(index)/Double(options.count))*Double.pi/180
        let local=NSRect(x:bounds.midX+CGFloat(Darwin.cos(angle))*r-42,y:bounds.midY+CGFloat(Darwin.sin(angle))*r-23,width:84,height:46)
        return window?.convertToScreen(convert(local,to:nil)) ?? .zero
    }
    private(set) var hoverIndex: Int? {
        didSet {
            if oldValue != hoverIndex {
                needsDisplay = true
                if let hoverIndex = hoverIndex, options.indices.contains(hoverIndex) {
                    onHover?(options[hoverIndex])
                } else {
                    onHover?(nil)
                }
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("文件轮盘")
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL, PasteboardFiles.filenamesType])
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 360) }

    override func layout() {
        super.layout()
        updateGlassMask()
    }

    // Sectors have four quadratic fillets. The path clips the desktop blur.
    // Window clicks stay on the angular slice. A desktop release near a cell uses that cell.
    func petalPath(index: Int, count: Int) -> NSBezierPath {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) * 0.46
        let inner = outer * 0.34
        let slice = 360.0 / CGFloat(max(count, 1))
        let gap = min(3.2, slice * 0.08)
        let mid = 90.0 - slice * CGFloat(index)
        let start = mid + slice / 2 - gap, end = mid - slice / 2 + gap
        let path = NSBezierPath()
        let corner = min(12, inner * (slice - gap * 2) * .pi / 180 * 0.22)
        let outerTrim = corner / outer * 180 / .pi
        let innerTrim = corner / inner * 180 / .pi
        func point(_ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
            let angle = degrees * .pi / 180
            return NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        func round(to end: NSPoint, through control: NSPoint) {
            let begin = path.currentPoint
            path.curve(to: end,
                controlPoint1: NSPoint(x: begin.x + (control.x - begin.x) * 2 / 3, y: begin.y + (control.y - begin.y) * 2 / 3),
                controlPoint2: NSPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3))
        }
        path.move(to: point(outer - corner, start))
        round(to: point(outer, start - outerTrim), through: point(outer, start))
        path.appendArc(withCenter: center, radius: outer, startAngle: start - outerTrim, endAngle: end + outerTrim, clockwise: true)
        round(to: point(outer - corner, end), through: point(outer, end))
        path.line(to: point(inner + corner, end))
        round(to: point(inner, end + innerTrim), through: point(inner, end))
        path.appendArc(withCenter: center, radius: inner, startAngle: end + innerTrim, endAngle: start - innerTrim, clockwise: false)
        round(to: point(inner + corner, start), through: point(inner, start))
        path.close()
        return path
    }

    private func updateGlassMask() {
        guard let glass = glassBackdrop, bounds.width > 1, bounds.height > 1 else { return }
        let paths = (0..<options.count).map { petalPath(index: $0, count: options.count) }
        let radius = min(bounds.width, bounds.height) * 0.46 * 0.34
        let hub = NSBezierPath(ovalIn: NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2))
        let mask = NSImage(size: bounds.size, flipped: false) { _ in
            NSColor.white.setFill()
            paths.forEach { $0.fill() }; hub.fill()
            return true
        }
        glass.maskImage = mask
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) * 0.46
        let inner = outer * 0.34
        let count = max(options.count, 0)

        // In the window the petals sit on a frosted tray; on the desktop the native blur is the tray.
        if glassBackdrop == nil {
            let tray = NSBezierPath(ovalIn: NSRect(x: center.x - outer - 7, y: center.y - outer - 7, width: (outer + 7) * 2, height: (outer + 7) * 2))
            LSPaint.tray.setFill()
            tray.fill()
        }

        if count == 0 {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            (glassBackdrop == nil ? LSPaint.petalBottom : NSColor.white.withAlphaComponent(0.12)).setFill()
            ring.fill()
            drawHub(center: center, radius: inner)
            drawCenteredCaption("没有可用选项", at: NSPoint(x: center.x, y: center.y - inner - 22), color: LSPaint.muted, size: 11)
            return
        }

        for (index, option) in options.enumerated() {
            let path = petalPath(index: index, count: count)
            let hovered = hoverIndex == index
            let selected = option.id == selectedID
            if selected {
                // The one solid accent shape on screen: the choice that Return will run.
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = LSPaint.accent.withAlphaComponent(0.35)
                glow.shadowBlurRadius = 10
                glow.shadowOffset = NSSize(width: 0, height: -2)
                glow.set()
                LSPaint.accent.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.22))?.draw(in: path, angle: 90)
            } else if glassBackdrop != nil {
                let top = hovered ? LSPaint.accent.withAlphaComponent(0.30) : NSColor.white.withAlphaComponent(0.22)
                let bottom = hovered ? LSPaint.accent.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.06)
                NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
                NSColor.white.withAlphaComponent(hovered ? 0.8 : 0.55).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                NSGradient(starting: LSPaint.petalTop, ending: LSPaint.petalBottom)?.draw(in: path, angle: -90)
                if hovered {
                    LSPaint.accent.withAlphaComponent(0.14).setFill()
                    path.fill()
                }
                LSPaint.rim.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            let label: NSColor = selected ? .white : (hovered ? (glassBackdrop == nil ? LSPaint.accent : LSPaint.accentDeep) : LSPaint.text)
            drawLabel(option: option, index: index, count: count, center: center, inner: inner, outer: outer, color: label)
        }
        drawHub(center: center, radius: inner)
    }

    private func drawHub(center: NSPoint, radius: CGFloat) {
        let hole = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: hole)
        if glassBackdrop == nil {
            // A raised glass button holding the file.
            NSGraphicsContext.saveGraphicsState()
            let lift = NSShadow()
            lift.shadowColor = NSColor.black.withAlphaComponent(0.12)
            lift.shadowBlurRadius = 10
            lift.shadowOffset = NSSize(width: 0, height: -2)
            lift.set()
            LSPaint.hub.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            LSPaint.rim.setStroke()
            path.lineWidth = 0.5
        } else {
            NSColor.white.withAlphaComponent(0.18).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        let iconSide = min(36, radius * 0.72)
        if let icon = centerImage {
            let dest = NSRect(x: center.x - iconSide / 2, y: center.y + 4, width: iconSide, height: iconSide)
            icon.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let fruit = LSIcon.appMark(size: iconSide)
            fruit.draw(in: NSRect(x: center.x - iconSide / 2, y: center.y + 6, width: iconSide, height: iconSide))
        }
        let title = centerTitle as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingMiddle
        title.draw(in: NSRect(x: center.x - radius * 0.87, y: center.y - 23, width: radius * 1.74, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: LSPaint.text,
            .paragraphStyle: paragraph
        ])
        if !centerSubtitle.isEmpty {
            drawCenteredCaption(centerSubtitle, at: NSPoint(x: center.x, y: center.y - 32), color: LSPaint.muted, size: 9)
        }
    }

    private func drawLabel(option: ConversionOption, index: Int, count: Int, center: NSPoint, inner: CGFloat, outer: CGFloat, color: NSColor) {
        let slice = 360.0 / CGFloat(count)
        let mid = (90.0 - slice * CGFloat(index)) * .pi / 180.0
        let r = inner + (outer - inner) * 0.58
        let p = NSPoint(x: center.x + cos(mid) * r, y: center.y + sin(mid) * r)
        if count <= 10, let symbol = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil) {
            let configured = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? symbol
            let s = NSSize(width: 13, height: 13)
            configured.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 6, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: color == LSPaint.text ? 0.9 : 1)
        }
        let text = truncated(option.title, limit: count > 8 ? 8 : 12) as NSString
        let font = NSFont.systemFont(ofSize: count > 8 ? 10 : 11, weight: .semibold)
        let size = text.size(withAttributes: [.font: font])
        text.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2 - (count <= 10 ? 4 : 0)), withAttributes: [
            .font: font,
            .foregroundColor: color
        ])
    }

    private func drawCenteredCaption(_ text: String, at point: NSPoint, color: NSColor, size: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let ns = text as NSString
        let s = ns.size(withAttributes: [.font: font])
        ns.draw(at: NSPoint(x: point.x - s.width / 2, y: point.y - s.height / 2), withAttributes: [
            .font: font,
            .foregroundColor: color
        ])
    }

    private func truncated(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    func sector(at point: NSPoint) -> Int? {
        dropEnabled ? nearestSector(at: point) : exactSector(at: point)
    }

    /// Main window: a click in the gap does not change the selection.
    private func exactSector(at point: NSPoint) -> Int? {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = hypot(dx, dy)
        let outer = min(bounds.width, bounds.height) * 0.46
        let inner = outer * 0.34
        guard dist >= inner, dist <= outer, !options.isEmpty else { return nil }
        var clockwise = atan2(dx, dy)
        if clockwise < 0 { clockwise += .pi * 2 }
        let slice = (.pi * 2) / CGFloat(options.count)
        let position = (clockwise + slice / 2).truncatingRemainder(dividingBy: .pi * 2)
        let gap = min(CGFloat(3.2) * .pi / 180, slice * 0.08)
        let inside = position.truncatingRemainder(dividingBy: slice)
        guard inside >= gap, inside <= slice - gap else { return nil }
        let index = Int(position / slice) % options.count
        if glassBackdrop != nil, !petalPath(index: index, count: options.count).contains(point) { return nil }
        return index
    }

    /// Desktop release: the nearest cell wins across the gap and just outside the petal.
    /// The hub, and anything past the wheel view, does not run.
    private func nearestSector(at point: NSPoint) -> Int? {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = hypot(dx, dy)
        let outer = min(bounds.width, bounds.height) * 0.46
        let inner = outer * 0.34
        guard !options.isEmpty else { return nil }
        let nearInner = inner * 0.78
        let nearOuter = min(outer + 28, min(bounds.width, bounds.height) / 2 - 1)
        guard dist >= nearInner, dist <= nearOuter else { return nil }
        var clockwise = atan2(dx, dy)
        if clockwise < 0 { clockwise += .pi * 2 }
        let slice = (.pi * 2) / CGFloat(options.count)
        let position = (clockwise + slice / 2).truncatingRemainder(dividingBy: .pi * 2)
        return Int(position / slice) % options.count
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard !options.isEmpty else { return }
        if [123, 124, 125, 126].contains(Int(event.keyCode)) {
            let delta = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
            let previous = options.firstIndex(where: { $0.id == selectedID }) ?? 0
            let index = (previous + delta + options.count) % options.count
            selectedID = options[index].id
            onSelect?(options[index])
        } else { super.keyDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        hoverIndex = sector(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if !dropEnabled { hoverIndex = nil }
    }

    func highlight(windowPoint: NSPoint) {
        hoverIndex = sector(at: convert(windowPoint, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        hoverIndex = sector(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        hoverIndex = sector(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if dropEnabled { LSDragTrace.note("wheel mouseUp type=\(event.type.rawValue)") }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = sector(at: point), options.indices.contains(index) else { return }
        // The desktop wheel commits when the pointer is released near a cell.
        // The main window only changes the selection.
        if dropEnabled { onCommit?(options[index], []) }
        else { onSelect?(options[index]) }
    }

    // macOS turns a click with Control held into a secondary click; it must commit the same way.
    override func rightMouseDown(with event: NSEvent) {
        if dropEnabled { mouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if dropEnabled { mouseUp(with: event) } else { super.rightMouseUp(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if dropEnabled { mouseUp(with: event) } else { super.otherMouseUp(with: event) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DragWheelMonitor.shared.noteDragSessionBegan()
        updateDrag(sender)
        // The wheel opens already under the pointer, so the first hit is the center.
        // Refusing that hit makes AppKit drop the destination; later movement never arrives.
        return dropOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
        return dropOperation(sender)
    }

    /// Holding Control narrows a Finder drag to link only, and Command to generic.
    /// Answering .copy outside that mask makes AppKit refuse the drop.
    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDrag(sender.draggingPasteboard) else { return [] }
        let mask = sender.draggingSourceOperationMask
        LSDragTrace.note("drag mask=\(mask.rawValue) hover=\(hoverIndex.map(String.init) ?? "-")", dedupe: true)
        // Once 复制路径 has been chosen, Control is often released in the same instant
        // and the source mask grows to include copy. Advertising copy turns the cursor
        // into a file copy and Finder then puts the file on the general pasteboard.
        let order: [NSDragOperation] = DragWheelMonitor.shared.pathCopyInProgress ? [.generic, .link, .copy] : [.copy, .link, .generic]
        for operation in order where mask.contains(operation) { return operation }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hoverIndex = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropEnabled }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        DragWheelMonitor.shared.dragSessionEnded()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateDrag(sender)
        LSDragTrace.note("performDrag hover=\(hoverIndex.map(String.init) ?? "-")")
        guard dropEnabled, let hoverIndex = hoverIndex, options.indices.contains(hoverIndex) else { return false }
        let urls = PasteboardFiles.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onCommit?(options[hoverIndex], urls)
        return true
    }

    private func fileDrag(_ pasteboard: NSPasteboard) -> Bool {
        !PasteboardFiles.urls(from: pasteboard).isEmpty || PasteboardFiles.looksLikeFileDrag(pasteboard)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    private func updateDrag(_ sender: NSDraggingInfo) {
        let location = convert(sender.draggingLocation, from: nil)
        hoverIndex = sector(at: location)
        let urls = PasteboardFiles.urls(from: sender.draggingPasteboard)
        if !urls.isEmpty {
            DragWheelMonitor.shared.noteDragURLs(urls)
        }
    }
}

private final class LSWheelAXElement: NSAccessibilityElement {
    weak var wheel: RadialWheelView?
    let optionID: String
    init(wheel: RadialWheelView, option: ConversionOption) {
        self.wheel=wheel;self.optionID=option.id;super.init()
        setAccessibilityElement(true);setAccessibilityEnabled(true)
        setAccessibilityRole(.button);setAccessibilityLabel(option.title);setAccessibilityHelp(option.subtitle);setAccessibilityParent(wheel)
    }
    override func accessibilityFrame() -> NSRect { wheel?.accessibilityRect(for:optionID) ?? .zero }
    override func accessibilityPerformPress() -> Bool {
        guard let wheel=wheel,let option=wheel.options.first(where:{$0.id==optionID}) else{return false}
        wheel.selectedID=optionID;wheel.onSelect?(option);return true
    }
}

struct RadialWheelHost: NSViewRepresentable {
    var options: [ConversionOption]
    var selectedID: String?
    var centerTitle: String
    var centerSubtitle: String
    var centerImage: NSImage?
    var onSelect: (ConversionOption) -> Void
    var onHover: (ConversionOption?) -> Void

    func makeNSView(context: Context) -> RadialWheelView {
        let view = RadialWheelView(frame: NSRect(x: 0, y: 0, width: 380, height: 380))
        view.dropEnabled = false
        view.onSelect = onSelect
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: RadialWheelView, context: Context) {
        nsView.options = options
        nsView.selectedID = selectedID
        nsView.centerTitle = centerTitle
        nsView.centerSubtitle = centerSubtitle
        nsView.centerImage = centerImage
        nsView.onSelect = onSelect
        nsView.onHover = onHover
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Opt-in log of the release signals, for gestures only a real Mac shows.
/// Set LOCALSHIFT_DRAG_TRACE, or the LSDragTrace default, to a file path.
enum LSDragTrace {
    static let url: URL? = {
        let path = ProcessInfo.processInfo.environment["LOCALSHIFT_DRAG_TRACE"] ?? UserDefaults.standard.string(forKey: "LSDragTrace")
        guard let path = path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }()
    private static var last = ""

    static func note(_ line: String, dedupe: Bool = false) {
        guard let url = url else { return }
        if dedupe { if line == last { return }; last = line }
        let data = Data((String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

final class DragWheelMonitor: NSObject {
    static let shared = DragWheelMonitor()

    private var timer: Timer?
    // Poll slowly while nothing is happening; switch to a fast rate only while the
    // mouse button is down or the wheel is visible, so idle CPU use stays negligible.
    private static let idleInterval: TimeInterval = 0.25
    private static let activeInterval: TimeInterval = 0.04
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var escMonitor: Any?
    private var panel: OverlayPanel?
    private var wheel: RadialWheelView?
    private var caption: NSTextField?
    private var shown = false
    private var openedThisDrag = false
    private var hideWork: DispatchWorkItem?
    private var mode: WheelMode = .conversion
    private var dragURLs: [URL] = []
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var currentFileDrag = false
    private var mouseWasDown = false
    // Polls in a row with no button down. One empty poll is not a release: the button
    // state can blank for a moment when a modifier goes down mid-drag.
    private var upPolls = 2
    private static let releasePolls = 2
    // The physical button was seen down during this drag; only then is its release trusted.
    private var physicalSeen = false
    private var buttonsHeld = false
    private var mouseUpMonitors: [Any] = []
    private var didCommit = false
    // True from draggingEntered until draggingEnded. A path copy must not touch the
    // general pasteboard while this is set: Finder replaces that write with the file.
    private var dragLive = false
    var pathCopyInProgress = false
    private var armedPath: String?
    private var pathRewriteGeneration = 0
    var isEnabled = true {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isEnabled { self.start() } else { self.stop() }
            }
        }
    }

    func start() {
        preparePanel()
        schedule(interval: Self.idleInterval)
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53, self?.shown == true {
                    self?.hide()
                    return nil
                }
                return event
            }
        }
        if mouseUpMonitors.isEmpty {
            // Backup for the poll: a Control drag can end as a secondary-button release.
            let ups: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: ups, handler: { [weak self] event in self?.releaseFromEvent(event) }) {
                mouseUpMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: ups, handler: { [weak self] event in self?.releaseFromEvent(event); return event }) {
                mouseUpMonitors.append(local)
            }
        }
    }

    func stop() {
        hide()
        stopTimer()
        if let escMonitor = escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        mouseUpMonitors.forEach(NSEvent.removeMonitor)
        mouseUpMonitors = []
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(interval: TimeInterval) {
        if let timer = timer, timer.timeInterval == interval { return }
        stopTimer()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func noteDragURLs(_ urls: [URL]) {
        if !urls.isEmpty { dragURLs = urls }
        if shown { refreshOptions() }
    }

    func noteDragSessionBegan() {
        dragLive = true
    }

    /// The drag has finished. The path watcher is already running; it stays quiet
    /// until this clears the drag so it does not touch the pasteboard mid-drag.
    func dragSessionEnded() {
        dragLive = false
        pathCopyInProgress = false
    }

    /// Copies a filesystem path as plain text. Finder puts the dragged file on the
    /// general pasteboard when the drag image finishes, which can be a second after
    /// mouse-up. The recording pasted an image because the earlier rewrite had
    /// already stopped by then.
    func copyPathResolvingDrag(_ text: String) {
        armedPath = text
        pathRewriteGeneration += 1
        watchPath(text, generation: pathRewriteGeneration, attempt: 0, waits: 0)
    }

    private func watchPath(_ text: String, generation: Int, attempt: Int, waits: Int) {
        guard armedPath == text, generation == pathRewriteGeneration else { return }
        if dragLive || pathCopyInProgress {
            // A drag that never reaches draggingEnded must not block the path forever.
            if waits < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.watchPath(text, generation: generation, attempt: attempt, waits: waits + 1)
                }
                return
            }
            dragLive = false
            pathCopyInProgress = false
        }
        let board = NSPasteboard.general
        if !Self.pasteboardIsOnlyPath(text) {
            let current = board.string(forType: .string) ?? ""
            let hasFile = !PasteboardFiles.urls(from: board).isEmpty
            if attempt > 0, !hasFile, !current.isEmpty, current != text {
                armedPath = nil
                return
            }
            Self.writePlainPath(text)
        }
        // Keep the path in place for about two seconds. That covers Finder writing
        // the file back after the drag image has left the screen.
        if attempt >= 16 {
            armedPath = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.watchPath(text, generation: generation, attempt: attempt + 1, waits: waits)
        }
    }

    private static func writePlainPath(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private static func pasteboardIsOnlyPath(_ text: String) -> Bool {
        let board = NSPasteboard.general
        return board.string(forType: .string) == text && PasteboardFiles.urls(from: board).isEmpty
    }

    private func preparePanel() {
        if panel != nil { return }
        let panel = OverlayPanel(
            contentRect: NSRect(x: -4000, y: -4000, width: 440, height: 468),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 468))
        root.wantsLayer = true
        let caption = NSTextField(labelWithString: "")
        caption.frame = NSRect(x: 16, y: 442, width: 408, height: 18)
        caption.alignment = .center
        caption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        caption.textColor = LSPaint.muted
        caption.drawsBackground = false
        caption.backgroundColor = .clear
        caption.isBezeled = false
        let glass = LSGlassMaterialView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
        let captionGlass = LSGlassMaterialView(frame: NSRect(x: 26, y: 436, width: 388, height: 30))
        captionGlass.wantsLayer = true
        captionGlass.layer?.cornerRadius = 15
        captionGlass.layer?.masksToBounds = true
        captionGlass.layer?.borderWidth = 1
        captionGlass.layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        caption.frame = NSRect(x: 38, y: 442, width: 364, height: 18)
        let wheel = RadialWheelView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
        wheel.glassBackdrop = glass
        wheel.dropEnabled = true
        wheel.onCommit = { [weak self] option, urls in
            self?.commit(option: option, urls: urls)
        }
        root.addSubview(glass)
        root.addSubview(captionGlass)
        root.addSubview(wheel)
        root.addSubview(caption)
        panel.contentView = root
        self.panel = panel
        self.wheel = wheel
        self.caption = caption
    }

    // Exercises the real overlay with task fixtures, without synthesizing Finder input.
    func previewForSnapshot(urls: [URL], centeredAt center: NSPoint, mode: WheelMode = .conversion) -> NSPanel? {
        dragURLs = urls
        open(mode: mode)
        if let panel = panel {
            panel.setFrameOrigin(NSPoint(x: center.x - panel.frame.width / 2, y: center.y - panel.frame.height / 2))
        }
        return panel
    }

    /// Used by the acceptance harness. Window coordinates, same as `NSDraggingInfo.draggingLocation`.
    func commitRelease(atWindowPoint point: NSPoint) -> Bool {
        guard let wheel = wheel else { return false }
        wheel.highlight(windowPoint: point)
        guard let index = wheel.hoverIndex, wheel.options.indices.contains(index) else { return false }
        return commit(option: wheel.options[index], urls: [])
    }

    /// Any button counts. macOS reports a click with Control held as the secondary
    /// button, so watching only the left button misses the end of a Control drag.
    static func anyButtonDown(_ pressedMouseButtons: Int) -> Bool { pressedMouseButtons != 0 }

    /// Hardware button state, which a held Control key does not remap.
    static func physicalButtons() -> Int {
        (CGEventSource.buttonState(.hidSystemState, button: .left) ? 1 : 0)
            | (CGEventSource.buttonState(.hidSystemState, button: .right) ? 2 : 0)
    }

    @objc private func tick() {
        advance(buttons: NSEvent.pressedMouseButtons, physical: Self.physicalButtons(), pointer: NSEvent.mouseLocation, flags: NSEvent.modifierFlags)
    }

    /// One poll. Kept apart from `tick` so the acceptance harness can feed the button state and pointer.
    /// `buttons` is the session state AppKit reports; after a Control drag it can still show a button
    /// down until the next click. `physical` is the hardware state; once it was seen down in this drag,
    /// its release ends the drag even while the session state lags.
    func advance(buttons: Int, physical: Int = 0, pointer: NSPoint, flags: NSEvent.ModifierFlags, escape: Bool? = nil) {
        guard isEnabled else { return }
        let pressed = Self.anyButtonDown(buttons)
        if pressed && physical != 0 { physicalSeen = true }
        let physicalUp = physicalSeen && physical == 0
        upPolls = pressed && !physicalUp ? 0 : min(upPolls + 1, Self.releasePolls)
        let buttonsDown = upPolls < Self.releasePolls
        let released = mouseWasDown && !buttonsDown
        mouseWasDown = buttonsDown
        buttonsHeld = buttonsDown
        // Keep the hardware press in mind while AppKit's session bit is still stuck down.
        // Clearing it here made the next poll look like a brand-new drag and left the panel up.
        if !buttonsDown && !pressed { physicalSeen = false }
        LSDragTrace.note("poll session=\(buttons) physical=\(physical) flags=0x\(String(flags.rawValue & 0xFFFF0000, radix: 16)) held=\(buttonsDown) shown=\(shown) hover=\(wheel?.hoverIndex.map(String.init) ?? "-")", dedupe: true)
        if released { LSDragTrace.note("release shown=\(shown)") }
        schedule(interval: buttonsDown || shown ? Self.activeInterval : Self.idleInterval)
        if shown, let panel = panel, let wheel = wheel {
            wheel.highlight(windowPoint: panel.convertPoint(fromScreen: pointer))
        }
        if released && shown { commitRelease() }
        let pasteboard = dragPasteboard
        if !buttonsDown {
            dragBaseline = pasteboard.changeCount
            currentFileDrag = false
        } else if pasteboard.changeCount != dragBaseline {
            dragBaseline = pasteboard.changeCount
            let urls = PasteboardFiles.urls(from: pasteboard)
            currentFileDrag = !urls.isEmpty || PasteboardFiles.looksLikeFileDrag(pasteboard)
            dragURLs = urls
        }
        if escapePressed(escape), shown || panelIsOnScreen {
            hide(); currentFileDrag = false
            openedThisDrag = false
            return
        }
        // hide() can clear the sectors and still leave the panel on screen. Park it.
        if !shown && panelIsOnScreen { hide() }
        let hasDrag = buttonsDown && currentFileDrag
        if hasDrag {
            hideWork?.cancel()
            hideWork = nil
            if let next = modeFromFlags(flags) {
                if !openedThisDrag {
                    open(mode: next)
                } else if shown, next != mode {
                    mode = next
                    refreshOptions()
                    updateCaption()
                }
            }
        } else {
            if shown, !buttonsDown { scheduleHide() }
            if !buttonsDown {
                openedThisDrag = false
                if !shown { dragURLs = [] }
            }
        }
    }

    func modeFromFlags(_ flags: NSEvent.ModifierFlags) -> WheelMode? {
        LSModifierStore.mode(flags)
    }

    private func open(mode: WheelMode) {
        preparePanel()
        self.mode = mode
        didCommit = false
        openedThisDrag = true
        shown = true
        refreshOptions()
        updateCaption()
        positionNearMouse()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        // Register again once the panel is on screen so an in-progress Finder drag can enter it.
        wheel?.unregisterDraggedTypes()
        wheel?.registerForDraggedTypes([.fileURL, PasteboardFiles.filenamesType])
    }

    @discardableResult
    private func commit(option: ConversionOption, urls: [URL]) -> Bool {
        LSDragTrace.note("commit \(option.id) didCommit=\(didCommit)")
        let files = urls.isEmpty ? urlsForCommit() : urls
        guard !didCommit, !files.isEmpty else { return false }
        didCommit = true
        if option.id == "copyPath" { pathCopyInProgress = true }
        let wheelMode = mode
        hide()
        AppModel.shared.applyFromWheel(urls: files, option: option, mode: wheelMode)
        return true
    }

    private func commitRelease() {
        guard let wheel = wheel, let index = wheel.hoverIndex, wheel.options.indices.contains(index) else { return }
        commit(option: wheel.options[index], urls: [])
    }

    private func releaseFromEvent(_ event: NSEvent) {
        LSDragTrace.note("event type=\(event.type.rawValue) buttons=\(NSEvent.pressedMouseButtons) shown=\(shown)")
        guard shown, let panel = panel, let wheel = wheel else { return }
        wheel.highlight(windowPoint: panel.convertPoint(fromScreen: NSEvent.mouseLocation))
        commitRelease()
    }

    private func urlsForCommit() -> [URL] {
        // The drag pasteboard keeps the previous file after a drag ends. The wheel
        // already stored this drag's files; prefer those over the leftover pasteboard.
        if !dragURLs.isEmpty { return dragURLs }
        return PasteboardFiles.urls(from: dragPasteboard)
    }

    private func refreshOptions() {
        let urls = dragURLs
        let options = AppModel.commonOptions(for: urls, mode: mode)
        wheel?.options = options
        if urls.count == 1 {
            wheel?.centerTitle = urls[0].lastPathComponent
            wheel?.centerSubtitle = ConverterEngine.category(for: urls[0]).displayName
            wheel?.centerImage = LSIcon.fileIcon(for: urls[0])
        } else if urls.isEmpty {
            wheel?.centerTitle = "文件"
            wheel?.centerSubtitle = ""
            wheel?.centerImage = nil
        } else {
            wheel?.centerTitle = "\(urls.count) 个文件"
            wheel?.centerSubtitle = ""
            wheel?.centerImage = LSIcon.fileIcon(for: urls[0])
        }
        wheel?.selectedID = nil
    }

    private func updateCaption() {
        let verb = mode == .tools ? "工具" : (mode == .actions ? "操作" : "转换")
        caption?.stringValue = LSModifierStore.label(mode) + " \(verb) · 靠近格子后松开 · Esc 取消"
    }

    private func positionNearMouse() {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2 + 8)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func scheduleHide() {
        if hideWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            // Not the raw session state: after a Control drag it can stay down until the next click.
            if self?.buttonsHeld == false {
                self?.hide()
            }
            self?.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private var panelIsOnScreen: Bool {
        guard let panel = panel else { return false }
        return panel.isVisible && panel.frame.minX > -1000
    }

    private func escapePressed(_ override: Bool?) -> Bool {
        if let override = override { return override }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(53))
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        shown = false
        wheel?.options = []
        guard let panel = panel else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
        panel.setFrameOrigin(NSPoint(x: -4000, y: -4000))
    }
}
