import Foundation

enum FileCategory: String, CaseIterable {
    case image, video, audio, pdf, document, presentation, spreadsheet, ebook, subtitle, archive, other
    var displayName: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        case .pdf: return "PDF"
        case .document: return "文档"
        case .presentation: return "幻灯片"
        case .ebook: return "电子书"
        case .spreadsheet: return "表格"
        case .subtitle: return "字幕"
        case .archive: return "归档"
        case .other: return "文件"
        }
    }
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .presentation: return "rectangle.on.rectangle"
        case .ebook: return "book"
        case .spreadsheet: return "tablecells"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }
}

enum WheelMode: String, CaseIterable { case conversion, tools, actions }

struct ConversionOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
}

struct ConversionSettings {
    var quality: Double = 0.82
    var width: Int = 1920
    var height: Int = 1080
    var startSeconds: Double = 0
    var endSeconds: Double = 10
    var speed: Double = 2
    var outputDirectory: URL? = nil
    var compressionMode = "quality" // quality, target, percent
    var targetBytes: Int64 = 0
    var reductionPercent: Double = 50
    var outputFormat = ""
    var cropRect: NormalizedRect? = nil
    var exactSize = false
    var exposure: Double = 0
    var brightness: Double = 0
    var saturation: Double = 1
    var contrast: Double = 1
    var sharpness: Double = 0
    var sepia: Double = 0
    var vignette: Double = 0
    var metadata: [String:String] = [:]
    var removeMetadata = true
    var annotations: [ImageAnnotation] = []
    var backgroundColorHex = "#151515"
    var gradientEndHex = ""
    var backgroundImage: URL? = nil
    var padding: Double = 40
    var cornerRadius: Double = 20
    var aspectRatio: Double = 0 // zero preserves natural canvas
    var collageLayout = "grid" // grid,row,column,featured
    var collageColumns = 2
    var pageOrder: [Int] = [] // zero based; duplicates allowed; omission deletes
    var pageRotations: [Int:Int] = [:] // output page index -> absolute rotation degrees
    var splitPoints: [Double] = []
    var snapshotTimes: [Double] = []
    var channels = 2
    var trimSilence = false
    var normalizeTarget: Double = -16
    var visualizerLayout = "landscape" // landscape,portrait,square
    var bleepRanges: [TimeRange] = []
    var redactions: [RedactionRegion] = []
    var detectFaces = false
    var detectText = false
    var redactionStyle = "blur" // blur,solid
    var redactionColorHex = "#000000"
    var bleepFrequency: Double = 1000
}

enum ConverterError: LocalizedError {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "已取消；原文件保持不变。"
        }
    }
}

// Normalized top-left coordinates, independent of source pixel dimensions.
struct NormalizedRect: Codable, Hashable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
}
struct TimeRange: Codable, Hashable {
    var start: Double; var end: Double
}
struct RedactionRegion: Codable, Hashable, Identifiable {
    var id = UUID()
    var rect: NormalizedRect
    var start: Double = 0
    var end: Double = .greatestFiniteMagnitude
    var style = "blur"
    var colorHex = "#000000"
}
struct ImageAnnotation: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind = "arrow" // arrow,rectangle,ellipse,text,number
    var rect = NormalizedRect(x: 0.1,y: 0.1,width: 0.5,height: 0.25)
    var text = ""
    var colorHex = "#ff8a32"
    var lineWidth: Double = 4
    var fontSize: Double = 28
}

/// Turns a raw engine failure (often the tail of an FFmpeg/LibreOffice/Python log)
/// into one sentence a user can act on. The full text stays available as diagnostics.
enum ErrorHint {
    private static let rules: [(patterns: [String], hint: String)] = [
        (["-1743", "Not authorized to send Apple events", "not allowed to send Apple events"],
         "需要允许 LocalShift 控制 Pages：打开「系统设置 → 隐私与安全性 → 自动化」，在 LocalShift 下勾选 Pages。"),
        (["No space left on device"], "磁盘空间不足，请清理后重试。"),
        (["Permission denied", "Operation not permitted"],
         "没有权限读取这个文件或写入输出文件夹。请换一个输出位置，或在「系统设置 → 隐私与安全性 → 文件和文件夹」里允许 LocalShift。"),
        (["FileNotDecryptedError", "has not been decrypted", "password"], "PDF 有密码保护，请先解除密码再处理。"),
        (["EOF marker not found", "PdfReadError", "Invalid PDF"], "PDF 文件已损坏，无法读取。"),
        (["does not contain any stream", "matches no streams", "Output file is empty"], "这个文件里没有可处理的音频或视频轨道。"),
        (["Unknown encoder", "Encoder not found", "Unknown decoder"], "缺少需要的编解码器，请重新安装 LocalShift。"),
        (["Invalid data found when processing input", "moov atom not found", "could not find codec parameters", "Error opening input",
          "BadZipFile", "File is not a zip file", "cannot identify image file"],
         "文件已损坏，或者实际格式和扩展名不一致。"),
    ]

    static func summary(for message: String) -> String {
        for rule in rules where rule.patterns.contains(where: { message.localizedCaseInsensitiveContains($0) }) {
            return rule.hint
        }
        if message.hasPrefix("处理失败：") {
            return "无法读取或转换这个文件。请确认文件可以正常打开，且输出位置可写。"
        }
        return message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
    }
}
