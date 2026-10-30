import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import CoreImage
import Vision
import AVFoundation
import AVKit
import ImageIO

struct LSToolSession: Identifiable {
    let id = UUID()
    let option: ConversionOption
    let urls: [URL]
    let settings: ConversionSettings
}

private struct LSPage: Identifiable {
    let id = UUID()
    var index: Int
    var rotation: Int
}

struct LSToolEditor: View {
    let session: LSToolSession
    let apply: (ConversionSettings,[URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ConversionSettings
    @State private var urls: [URL]
    @State private var image: NSImage?
    @State private var metadataRows: [LSMetadataRow] = []
    @State private var metadataOriginal: [String:String] = [:]
    @State private var pages: [LSPage] = []
    @State private var pdf: PDFDocument?
    @State private var pageSelection = 0
    @State private var annotationKind = "arrow"
    @State private var annotationText = "文字"
    @State private var annotationHex = "#ff8a32"
    @State private var annotationWidth = 4.0
    @State private var annotationFont = 28.0
    @State private var selectedShape: UUID?
    @State private var error: String?
    @State private var busy = false
    @State private var previewImage: NSImage?
    @State private var previewSource: URL?
    @State private var visionStatus = ""
    @StateObject private var media = LSMediaPreview()
    private var tool: String { session.option.id }
    private var category: FileCategory { urls.first.map(ConverterEngine.category) ?? .other }
    private var mediaTool: Bool { [.audio,.video].contains(category) }
    private var canvasTool: Bool { ["cropImage","annotateImage","redactImage","cropVideo","redactVideo","editImage","frameImage"].contains(tool) }
    private var drawMode: String { if tool == "cropImage" || tool == "cropVideo" { return "crop" }; if tool == "annotateImage" { return annotationKind }; if tool == "redactImage" || tool == "redactVideo" { return "redact" }; return "none" }

    init(session: LSToolSession, apply: @escaping (ConversionSettings,[URL]) -> Void) {
        self.session = session; self.apply = apply
        _settings = State(initialValue: session.settings)
        _urls = State(initialValue: session.urls)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: session.option.symbol)
                    .font(.system(size: 18, weight: .medium)).foregroundColor(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Text(session.option.title).font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                Text("LocalShift · 本地处理").font(.system(size: 11)).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 24).padding(.vertical, 18).background(Theme.card)
            Divider()
            HStack(spacing: 0) {
                preview.frame(maxWidth: .infinity,maxHeight: .infinity).background(Theme.canvas)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text).lineLimit(2)
                        Divider()
                        controls
                        outputControls
                        if let error = error {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.caption).foregroundColor(Theme.danger)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 350).background(Theme.card)
            }
            Divider()
            HStack(spacing: 12) {
                Label("结果另存为新文件，源文件保留。", systemImage: "doc.badge.plus")
                    .font(.system(size: 11)).foregroundColor(Theme.muted)
                Spacer()
                Button("取消") { media.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用并生成") { commit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || urls.isEmpty)
            }
            .controlSize(.large).padding(.horizontal, 24).padding(.vertical, 14).background(Theme.card)
        }
        .frame(minWidth: 1000, idealWidth: 1100, minHeight: 680, idealHeight: 760)
        .background(Theme.canvas).tint(Theme.accent).buttonStyle(.bordered).controlSize(.regular)
        .onAppear { load() }
        .onDisappear { media.stop() }
        .onChange(of: urls) { _ in
            guard let first=urls.first,first != previewSource else{return}
            previewSource=first;image=NSImage(contentsOf:first);refreshImage()
            if category == .pdf {pdf=PDFDocument(url:first)}
            if mediaTool {media.load(first) { duration in settings.startSeconds=0;settings.endSeconds=duration }}
        }
        .onChange(of: settings.exactSize) { _ in refreshImage() }
        .onChange(of: settings.width) { _ in refreshImage() }
        .onChange(of: settings.height) { _ in refreshImage() }
        .onChange(of: settings.exposure) { _ in refreshImage() }
        .onChange(of: settings.brightness) { _ in refreshImage() }
        .onChange(of: settings.saturation) { _ in refreshImage() }
        .onChange(of: settings.contrast) { _ in refreshImage() }
        .onChange(of: settings.sharpness) { _ in refreshImage() }
        .onChange(of: settings.sepia) { _ in refreshImage() }
        .onChange(of: settings.vignette) { _ in refreshImage() }
    }
    @ViewBuilder private var preview: some View {
        VStack(spacing: 12) {
            if tool == "organizePDF" || tool == "splitPDF" {
                pdfPreview
            } else if tool == "createCollage" {
                collagePreview
            } else if canvasTool {
                if let shown = mediaTool ? media.frame : previewImage ?? image {
                    LSCanvas(image: shown, crop: $settings.cropRect, annotations: $settings.annotations, redactions: $settings.redactions, selection: $selectedShape, mode: drawMode, annotation: ImageAnnotation(kind: annotationKind, text: annotationText, colorHex: annotationHex, lineWidth: annotationWidth, fontSize: annotationFont), redaction: RedactionRegion(rect: NormalizedRect(x: 0,y: 0,width: 0.1,height: 0.1), start: mediaTool ? settings.startSeconds : 0, end: mediaTool ? settings.endSeconds : .greatestFiniteMagnitude, style: settings.redactionStyle,colorHex: settings.redactionColorHex), frameBackground: tool == "frameImage" ? settings : nil)
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1).allowsHitTesting(false))
                    Text(drawMode == "none" ? "预览" : "在画面拖拽绘制；拖动框内部移动，右下角调整大小。点击形状选中。").font(.caption).foregroundColor(.secondary)
                } else { unavailablePreview }
            } else if mediaTool {
                if category == .video {
                    ZStack {
                        VideoPlayer(player: media.player)
                        if !media.playing, let frame = media.frame { Image(nsImage: frame).resizable().scaledToFit().allowsHitTesting(false) }
                    }.frame(minHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1).allowsHitTesting(false))
                }
                else {
                    Image(systemName: "waveform").font(.system(size: 70)).foregroundColor(Theme.accent)
                    Text(urls.first?.lastPathComponent ?? "").font(.headline)
                    LSVisualizerPreview(samples: media.waveform, settings: settings).frame(maxWidth: .infinity,maxHeight: .infinity)
                }
            } else if category == .pdf, let doc = pdf {
                LSPDFView(document: doc).frame(maxWidth: .infinity,maxHeight: .infinity)
            } else if let image = image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity,maxHeight: .infinity)
            } else { unavailablePreview }
            if mediaTool {
                if let message=media.error {Text(message).font(.caption).foregroundColor(.secondary)}
                transport.padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1).allowsHitTesting(false))
            }
        }.padding(22)
    }
    private var unavailablePreview: some View {
        VStack(spacing: 14) {
            Image(systemName: category.symbol).font(.system(size: 60)).foregroundColor(Theme.accent)
            Text(urls.first?.lastPathComponent ?? "文件").font(.headline)
            if let message = media.error { Text(message).font(.caption).foregroundColor(Theme.danger) }
            else { Text(category == .archive ? "解压后会生成独立目录" : "选择参数后应用生成结果").font(.caption).foregroundColor(.secondary) }
        }.frame(maxWidth: .infinity,maxHeight: .infinity)
    }
    @ViewBuilder private var controls: some View {
        switch tool {
        case "compress": compressionControls
        case "removeMetadata": metadataControls
        case "editImage": imageControls
        case "annotateImage": annotationControls
        case "cropImage","cropVideo": cropControls
        case "frameImage": frameControls
        case "createCollage": collageControls
        case "redactImage","redactVideo": redactionControls
        case "organizePDF","splitPDF": pdfControls
        case "mergePDF","createPDF": orderControls
        case "joinVideos":
            orderControls
            Toggle("统一到指定画面尺寸",isOn:$settings.exactSize)
            if settings.exactSize {integer("输出宽",$settings.width);integer("输出高",$settings.height)}
        case "trimVideo","trimAudio": trimControls
        case "changeVideoSpeed": speedControls
        case "videoSnapshots": snapshotControls
        case "splitVideo": splitControls
        case "normalizeAudio":
            number("目标响度 LUFS", $settings.normalizeTarget)
            Text("峰值限制与响度校正在本地处理。").font(.caption).foregroundColor(.secondary)
        case "audioChannels":
            Picker("输出声道", selection: $settings.channels) { Text("单声道").tag(1); Text("立体声").tag(2) }
        case "redactAudio": bleepControls
        case "audioToVideo": visualizerControls
        case "muteVideo":
            Label("导出的视频移除所有音轨", systemImage: "speaker.slash").font(.callout)
            Text("可先播放确认源片段。应用后写入新视频。").font(.caption).foregroundColor(.secondary)
        case "extractArchive":
            Label("将归档展开至新目录",systemImage: "archivebox").font(.callout)
            Text("保留归档文件。解压目录使用独立名称；路径检查由引擎执行。").font(.caption).foregroundColor(.secondary)
        default: EmptyView()
        }
    }
    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("输出位置").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.muted)
            Text(settings.outputDirectory?.path ?? "各源文件所在目录").font(.caption).foregroundColor(.secondary).lineLimit(3)
            HStack {
                Button("选择目录") {
                    let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
                    if p.runModal() == .OK { settings.outputDirectory = p.url }
                }
                if settings.outputDirectory != nil { Button("原目录") { settings.outputDirectory = nil } }
            }
        }
    }
    private var compressionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("压缩方式",selection: $settings.compressionMode) {
                Text("质量").tag("quality"); Text("目标文件大小").tag("target"); Text("减少百分比").tag("percent")
            }
            if settings.compressionMode == "quality" { slider("质量", $settings.quality, 0.05...1) }
            if settings.compressionMode == "target" {
                HStack { Text("目标 MB"); TextField("MB", value: Binding(get: { Double(settings.targetBytes)/1_000_000 }, set: { settings.targetBytes = Int64(max(0,$0)*1_000_000) }), format: .number).textFieldStyle(.roundedBorder) }
            }
            if settings.compressionMode == "percent" { slider("减少 %",$settings.reductionPercent,1...95) }
            Text("目标大小可能受格式、时长和最低码率限制；以实际结果为准。").font(.caption).foregroundColor(.secondary)
        }
    }
    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("精确输出尺寸",isOn: $settings.exactSize)
            integer("宽（像素）",$settings.width); integer("高（像素）",$settings.height)
            slider("曝光 EV",$settings.exposure,-3...3)
            slider("亮度",$settings.brightness,-1...1)
            slider("饱和度",$settings.saturation,0...2)
            slider("对比度",$settings.contrast,0.25...2)
            slider("锐化",$settings.sharpness,0...2)
            slider("棕褐色",$settings.sepia,0...1)
            slider("暗角",$settings.vignette,0...2)
            Button("恢复调色") { settings.exposure = 0; settings.brightness = 0; settings.saturation = 1; settings.contrast = 1; settings.sharpness = 0; settings.sepia = 0; settings.vignette = 0; refreshImage() }
        }
    }
    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("拖拽画面选择保留区域。坐标使用 0–1 归一化值。").font(.caption).foregroundColor(.secondary)
            rectFields(Binding(get: { settings.cropRect ?? NormalizedRect(x:0,y:0,width:1,height:1) },set: { settings.cropRect = $0 }))
            HStack { Button("全图") { settings.cropRect = NormalizedRect(x:0,y:0,width:1,height:1) }; Button("正方形") { setCrop(aspect: 1) }; Button("16:9") { setCrop(aspect: 16/9) }; Button("9:16") { setCrop(aspect: 9/16) } }
            Toggle("精确输出尺寸",isOn: $settings.exactSize)
            if settings.exactSize { integer("输出宽",$settings.width); integer("输出高",$settings.height) }
        }
    }
    private var annotationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("标注",selection: $annotationKind) {
                Text("箭头").tag("arrow"); Text("矩形").tag("rectangle"); Text("椭圆").tag("ellipse"); Text("文字").tag("text"); Text("编号").tag("number")
            }
            TextField("内容",text: $annotationText).textFieldStyle(.roundedBorder)
            color("颜色",$annotationHex)
            slider("线宽",$annotationWidth,1...20); slider("字号",$annotationFont,10...120)
            Button("更新选中标注") {
                if let index = settings.annotations.firstIndex(where: { $0.id == selectedShape }) {
                    settings.annotations[index].text = annotationText; settings.annotations[index].colorHex = annotationHex
                    settings.annotations[index].lineWidth = annotationWidth; settings.annotations[index].fontSize = annotationFont
                }
            }.disabled(!settings.annotations.contains { $0.id == selectedShape })
            ForEach(Array(settings.annotations.enumerated()),id: \.element.id) { index,item in
                HStack {
                    Button("\(index+1). \(item.kind) \(item.text)") { selectedShape = item.id; annotationKind = item.kind; annotationText = item.text; annotationHex = item.colorHex; annotationWidth = item.lineWidth; annotationFont = item.fontSize }.buttonStyle(.plain)
                    Spacer(); Button { settings.annotations.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                }.font(.caption).foregroundColor(selectedShape == item.id ? Theme.accent : Theme.text)
            }
            Button("清除全部标注") { settings.annotations.removeAll() }.disabled(settings.annotations.isEmpty)
        }
    }
    private var frameControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            color("背景颜色",$settings.backgroundColorHex); color("渐变终点",$settings.gradientEndHex)
            HStack { Button("选择背景图片") { let p = NSOpenPanel(); p.allowedContentTypes = [.image]; if p.runModal() == .OK { settings.backgroundImage = p.url } }; if settings.backgroundImage != nil { Button("移除背景图") { settings.backgroundImage = nil } } }
            slider("边距（像素）",$settings.padding,0...400); slider("图片圆角（像素）",$settings.cornerRadius,0...200)
            aspectPicker
        }
    }
    private var aspectPicker: some View {
        Picker("画幅比例", selection: $settings.aspectRatio) { Text("跟随图片").tag(0.0); Text("1:1").tag(1.0); Text("16:9").tag(16.0/9); Text("9:16").tag(9.0/16); Text("4:3").tag(4.0/3) }
    }
    private var collageControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            orderControls
            Picker("布局",selection: $settings.collageLayout) { Text("网格").tag("grid"); Text("横排").tag("row"); Text("竖排").tag("column"); Text("主图").tag("featured") }
            Stepper("列数 \(settings.collageColumns)", value: $settings.collageColumns, in: 1...8)
            color("背景",$settings.backgroundColorHex); slider("间距（像素）",$settings.padding,0...160); slider("圆角",$settings.cornerRadius,0...100)
            integer("输出宽",$settings.width); integer("输出高",$settings.height)
        }
    }
    private var orderControls: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text("输入顺序").font(.headline)
            ForEach(Array(urls.enumerated()),id: \.offset) { index,url in
                HStack(spacing: 5) {
                    Text("\(index+1). \(url.lastPathComponent)").lineLimit(1)
                    Spacer()
                    Button { urls.swapAt(index,index-1) } label: { Image(systemName:"arrow.up") }.disabled(index == 0)
                    Button { urls.swapAt(index,index+1) } label: { Image(systemName:"arrow.down") }.disabled(index == urls.count-1)
                    Button { urls.remove(at:index) } label: { Image(systemName:"minus.circle") }.disabled(urls.count == 1)
                }.font(.caption)
            }
            Button("添加同类文件") {
                let p=NSOpenPanel();p.allowsMultipleSelection=true
                if p.runModal() == .OK {
                    let required = category
                    for u in p.urls where ConverterEngine.category(for:u) == required && !urls.contains(u) { urls.append(u) }
                }
            }
        }
    }
    private var redactionControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            Picker("遮挡样式",selection: $settings.redactionStyle) { Text("模糊").tag("blur"); Text("纯色").tag("solid") }
            color("遮挡颜色",$settings.redactionColorHex)
            if tool == "redactVideo" { rangeFields }
            Toggle("本地识别人脸",isOn: $settings.detectFaces)
            Toggle("本地识别文字",isOn: $settings.detectText)
            Button(busy ? "识别中…" : "识别当前画面并加入遮挡") { detect() }.disabled(busy || (!settings.detectFaces && !settings.detectText))
            if !visionStatus.isEmpty { Text(visionStatus).font(.caption).foregroundColor(.secondary) }
            Text(tool == "redactVideo" ? "自动识别基于当前帧。已标注区域按指定时间范围固定遮挡；对象移动时请增加分段区域。" : "也可直接在图上拖拽添加遮挡区域。").font(.caption).foregroundColor(.secondary)
            ForEach(Array(settings.redactions.enumerated()),id: \.element.id) { index,region in
                VStack(alignment: .leading,spacing: 5) {
                    HStack { Button("区域 \(index+1)") { selectedShape = region.id }; Spacer(); Button { settings.redactions.removeAll { $0.id == region.id } } label: { Image(systemName:"trash") } }
                    if let i=settings.redactions.firstIndex(where: { $0.id == region.id }) {
                        rectFields($settings.redactions[i].rect)
                        if tool == "redactVideo" { number("开始秒",$settings.redactions[i].start); number("结束秒",$settings.redactions[i].end) }
                        Picker("样式",selection: $settings.redactions[i].style) { Text("模糊").tag("blur");Text("纯色").tag("solid") }
                        color("颜色",$settings.redactions[i].colorHex)
                    }
                }.padding(12).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1).allowsHitTesting(false))
            }
            Button("清除全部区域") { settings.redactions.removeAll() }.disabled(settings.redactions.isEmpty)
        }
    }
    private var trimControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            rangeFields
            if tool == "trimAudio" { Toggle("去除首尾静音",isOn: $settings.trimSilence) }
            Button("试听选区") { media.playRange(start:settings.startSeconds,end:settings.endSeconds,rate:Float(settings.speed == 2 ? 1 : settings.speed)) }
        }
    }
    private var rangeFields: some View {
        VStack(spacing: 8) {
            number("开始秒",$settings.startSeconds); number("结束秒",$settings.endSeconds)
            HStack { Button("当前设为开始") { settings.startSeconds = media.position }; Button("当前设为结束") { settings.endSeconds = media.position } }
        }
    }
    private var speedControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            slider("播放速度",$settings.speed,0.25...4)
            Button("按此速度试听") { media.player?.rate = Float(settings.speed); media.playing = true }
        }
    }
    private var splitControls: some View {
        VStack(alignment: .leading,spacing: 10) {
            Button("添加当前位置为切割点") { if media.position > 0 && media.position < media.duration { settings.splitPoints.append(media.position); settings.splitPoints = Array(Set(settings.splitPoints)).sorted() } }
            ForEach(Array(settings.splitPoints.enumerated()),id: \.offset) { index,_ in
                HStack { TextField("秒", value: $settings.splitPoints[index],format: .number).textFieldStyle(.roundedBorder); Button("定位") { media.seek(settings.splitPoints[index]) }; Button { settings.splitPoints.remove(at:index) } label: { Image(systemName:"trash") } }
            }
            Text("应用后按切割点导出多个独立片段。").font(.caption).foregroundColor(.secondary)
        }
    }
    private var snapshotControls: some View {
        VStack(alignment: .leading,spacing: 10) {
            Button("添加当前帧截图点") { settings.snapshotTimes.append(media.position); settings.snapshotTimes = Array(Set(settings.snapshotTimes)).sorted() }
            ForEach(Array(settings.snapshotTimes.enumerated()),id: \.offset) { index,_ in
                HStack { TextField("秒",value: $settings.snapshotTimes[index],format: .number).textFieldStyle(.roundedBorder); Button("定位") { media.seek(settings.snapshotTimes[index]) }; Button { settings.snapshotTimes.remove(at:index) } label: { Image(systemName:"trash") } }
            }
            Picker("截图格式",selection: $settings.outputFormat) { Text("PNG").tag("png"); Text("JPEG").tag("jpg") }
            Text("时间精度受源文件帧率约束。").font(.caption).foregroundColor(.secondary)
        }
    }
    private var bleepControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            rangeFields
            number("提示音频率 Hz（0 为静音）",$settings.bleepFrequency)
            Button("添加消音/提示音区间") { if settings.endSeconds > settings.startSeconds { settings.bleepRanges.append(TimeRange(start:settings.startSeconds,end:settings.endSeconds)) } }
            ForEach(Array(settings.bleepRanges.enumerated()),id: \.offset) { index,_ in
                VStack {
                    number("开始秒",$settings.bleepRanges[index].start); number("结束秒",$settings.bleepRanges[index].end)
                    HStack { Button("试听原区间") { media.playRange(start:settings.bleepRanges[index].start,end:settings.bleepRanges[index].end,rate:1) }; Button("移除") { settings.bleepRanges.remove(at:index) } }
                }.padding(12).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1).allowsHitTesting(false))
            }
        }
    }
    private var visualizerControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            Picker("画幅",selection: $settings.visualizerLayout) { Text("横向").tag("landscape");Text("竖向").tag("portrait");Text("方形").tag("square") }
            Text(settings.visualizerLayout == "portrait" ? "1080 × 1920" : settings.visualizerLayout == "square" ? "1080 × 1080" : "1920 × 1080").font(.caption).foregroundColor(.secondary)
            color("背景颜色",$settings.backgroundColorHex)
            Button("背景图片") { let p=NSOpenPanel();p.allowedContentTypes=[.image];if p.runModal() == .OK { settings.backgroundImage = p.url } }
            if let u=settings.backgroundImage { Text(u.lastPathComponent).font(.caption);Button("移除背景") { settings.backgroundImage=nil } }
        }
    }
    private var metadataControls: some View {
        VStack(alignment: .leading,spacing: 10) {
            Toggle("清除原有元数据",isOn:$settings.removeMetadata)
            Text("原始标签 \(metadataOriginal.count) 项").font(.headline)
            ForEach(metadataOriginal.keys.sorted(),id: \.self) { key in HStack(alignment:.top) { Text(key).fontWeight(.medium);Spacer();Text(metadataOriginal[key] ?? "").textSelection(.enabled) }.font(.caption) }
            Divider(); Text("写入或更新标签").font(.headline)
            Text("填写 Title、Author、Description、Copyright、Artist、Software 等标准标签；留空行不写入。").font(.caption).foregroundColor(.secondary)
            ForEach($metadataRows) { $row in
                HStack { TextField("标签",text:$row.key).textFieldStyle(.roundedBorder);TextField("值",text:$row.value).textFieldStyle(.roundedBorder);Button { metadataRows.removeAll { $0.id == row.id } } label: { Image(systemName:"minus.circle") } }
            }
            Button("添加标签") { metadataRows.append(LSMetadataRow()) }
        }
    }
    private var pdfPreview: some View {
        VStack(spacing: 10) {
            if let pdf = pdf, pages.indices.contains(pageSelection), let page = pdf.page(at:pages[pageSelection].index) {
                Image(nsImage: rotatedThumbnail(page, rotation: pages[pageSelection].rotation, size: NSSize(width: 700,height: 430))).resizable().scaledToFit().frame(maxHeight:.infinity)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(pages.enumerated()),id: \.element.id) { index,item in
                        VStack(spacing: 5) {
                            if let page=pdf?.page(at:item.index) { Image(nsImage:rotatedThumbnail(page,rotation:item.rotation,size:NSSize(width:90,height:110))).resizable().scaledToFit().frame(width:72,height:90) }
                            Text("\(index+1) · 源 \(item.index+1)").font(.caption2)
                        }.padding(6).background(pageSelection == index ? Theme.accent.opacity(0.10) : Theme.card).cornerRadius(7)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(pageSelection == index ? Theme.accent.opacity(0.65) : Theme.border, lineWidth: 1).allowsHitTesting(false))

                    }
                }
                .overlay(LSPDFReorderCapture(count: pages.count, select: { pageSelection=$0 }, reorder: { from,to in
                    let item=pages.remove(at:from);pages.insert(item,at:to);pageSelection=to
                }))
            }.frame(height:130)
            Text("拖动缩略图调整顺序；点击选择页面。").font(.caption).foregroundColor(.secondary)
        }
    }
    private func rotatedThumbnail(_ page: PDFPage, rotation: Int, size: NSSize) -> NSImage {
        let copy = (page.copy() as? PDFPage) ?? page
        copy.rotation = rotation
        return copy.thumbnail(of: size, for: .mediaBox)
    }
    private var pdfControls: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("\(pages.count) 个输出页面").font(.headline)
            if !pages.isEmpty {
                Stepper("选中第 \(pageSelection+1) 页",value:$pageSelection,in:0...max(0,pages.count-1))
                HStack {
                    Button("向前") { pages.swapAt(pageSelection,pageSelection-1);pageSelection-=1 }.disabled(pageSelection == 0)
                    Button("向后") { pages.swapAt(pageSelection,pageSelection+1);pageSelection+=1 }.disabled(pageSelection >= pages.count-1)
                }
                HStack {
                    Button("旋转 90°") { pages[pageSelection].rotation = (pages[pageSelection].rotation+90)%360 }
                    Button("复制") { let p=pages[pageSelection];pages.insert(LSPage(index:p.index,rotation:p.rotation),at:pageSelection+1) }
                    Button("删除") { pages.remove(at:pageSelection);pageSelection=max(0,min(pageSelection,pages.count-1)) }.disabled(pages.count <= 1)
                }
            }
            Button("恢复全部页面") { resetPages() }
            Text(tool == "splitPDF" ? "按当前列表逐页导出独立 PDF；移除页面可只拆分所需页面。" : "列表顺序、页面旋转和重复页将写入新 PDF。").font(.caption).foregroundColor(.secondary)
        }
    }
    private var collagePreview: some View {
        LSCollagePreview(urls: urls, settings: settings)
    }
    private var transport: some View {
        VStack(spacing: 8) {
            LSTimeline(position:$media.position,start:$settings.startSeconds,end:$settings.endSeconds,duration:media.duration,samples:media.waveform,points:settings.splitPoints+settings.snapshotTimes,ranges:settings.bleepRanges,onSeek:media.seek).frame(height:78)
            HStack {
                Button { media.step(-1) } label: { Image(systemName:"backward.frame") }.help("上一帧")
                Button { media.toggle() } label: { Image(systemName:media.playing ? "pause.fill" : "play.fill") }.help("播放/暂停")
                Button { media.step(1) } label: { Image(systemName:"forward.frame") }.help("下一帧")
                Text(String(format:"%.3f / %.3f 秒",media.position,media.duration)).font(.system(.caption,design:.monospaced))
                Spacer()
                if !media.waveform.isEmpty { Text("本地波形").font(.caption2).foregroundColor(.secondary) }
            }
        }
    }
    private func load() {
        if let first=urls.first {
            previewSource=first
            image=NSImage(contentsOf:first)
            if category == .pdf { pdf=PDFDocument(url:first);resetPages() }
            if mediaTool { media.load(first) { duration in settings.startSeconds=0;settings.endSeconds=duration;if tool == "changeVideoSpeed" { media.player?.rate=0 }; if tool == "audioToVideo" { settings.width=1920;settings.height=1080 } } }
            if tool == "removeMetadata" { metadataOriginal=LSMetadata.read(first);metadataRows=settings.metadata.sorted{$0.key<$1.key}.map { LSMetadataRow(key:$0.key,value:$0.value) } }
        }
        settings.outputFormat = tool == "videoSnapshots" ? "png" : ""
        if tool == "compress" && settings.targetBytes == 0 { settings.targetBytes=1_000_000 }
        refreshImage()
    }
    private func resetPages() {
        guard let pdf=pdf else { return };pages=(0..<pdf.pageCount).map { LSPage(index:$0,rotation:pdf.page(at:$0)?.rotation ?? 0) };pageSelection=0
    }
    private func commit() {
        error=nil
        if ["mergePDF","joinVideos","createCollage"].contains(tool) && urls.count<2 { error="此操作至少需要两个文件。";return }
        if ["trimVideo","trimAudio"].contains(tool), !(settings.endSeconds>settings.startSeconds && settings.startSeconds>=0 && settings.endSeconds<=media.duration+0.1) { error="请设置有效的开始和结束时间。";return }
        if ["cropImage","cropVideo"].contains(tool), settings.cropRect == nil { error="请先在预览中拖出裁剪框，或选择全图。";return }
        if tool == "annotateImage", settings.annotations.isEmpty { error="请先在画面上添加标注。";return }
        if tool == "redactVideo", settings.redactions.isEmpty {error="请先识别当前画面或绘制遮挡区域。";return}
        if tool == "redactImage", settings.redactions.isEmpty && !settings.detectFaces && !settings.detectText { error="请绘制遮挡区域或启用本地自动识别。";return }
        if tool == "redactAudio", settings.bleepRanges.isEmpty { error="请添加至少一个消音区间。";return }
        if tool == "splitVideo", settings.splitPoints.isEmpty { error="请添加至少一个切割点。";return }
        if tool == "videoSnapshots", settings.snapshotTimes.isEmpty { settings.snapshotTimes=[media.position] }
        if tool == "removeMetadata" { settings.metadata=Dictionary(metadataRows.filter{!$0.key.isEmpty}.map{($0.key,$0.value)},uniquingKeysWith: { _,new in new }) }
        if ["organizePDF","splitPDF"].contains(tool) {
            settings.pageOrder=pages.map(\.index)
            settings.pageRotations=[:]
            for (i,p) in pages.enumerated() { settings.pageRotations[i]=p.rotation }
        }
        if ["redactImage","redactVideo"].contains(tool) {
            // Detections were converted into editable regions. Avoid an additional automatic pass on export.
            if !settings.redactions.isEmpty { settings.detectFaces=false;settings.detectText=false }
        }
        media.stop();apply(settings,urls)
    }
    private func setCrop(aspect: Double) {
        let size = (mediaTool ? media.frame : image)?.size ?? NSSize(width:1,height:1)
        let natural=Double(size.width/max(size.height,1));let w=min(1,aspect/natural);let h=min(1,natural/aspect)
        settings.cropRect=NormalizedRect(x:(1-w)/2,y:(1-h)/2,width:w,height:h)
    }
    private func refreshImage() {
        guard tool == "editImage",let image=image,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let cg=bitmap.cgImage else { previewImage=image;return }
        var ci=CIImage(cgImage:cg)
        ci=ci.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:settings.exposure])
        ci=ci.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:settings.brightness,kCIInputSaturationKey:settings.saturation,kCIInputContrastKey:settings.contrast])
        ci=ci.applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:settings.sharpness])
        ci=ci.applyingFilter("CISepiaTone",parameters:[kCIInputIntensityKey:settings.sepia])
        ci=ci.applyingFilter("CIVignette",parameters:[kCIInputIntensityKey:settings.vignette,kCIInputRadiusKey:Double(min(cg.width,cg.height))/2])
        if settings.exactSize,settings.width>0,settings.height>0,settings.width<=16384,settings.height<=16384 {
            let previewScale=min(1,1600.0/Double(max(settings.width,settings.height)))
            ci=ci.transformed(by:CGAffineTransform(scaleX:Double(settings.width)*previewScale/ci.extent.width,y:Double(settings.height)*previewScale/ci.extent.height))
        }
        if let rendered=CIContext().createCGImage(ci,from:ci.extent) { previewImage=NSImage(cgImage:rendered,size:settings.exactSize ? NSSize(width:rendered.width,height:rendered.height) : image.size) }
    }
    private func detect() {
        guard let image=mediaTool ? media.frame : image,let data=image.tiffRepresentation,let rep=NSBitmapImageRep(data:data),let cg=rep.cgImage else { error="无法读取当前画面。";return }
        busy=true;visionStatus=""
        let faces=settings.detectFaces,text=settings.detectText, style=settings.redactionStyle,hex=settings.redactionColorHex
        let start=mediaTool ? settings.startSeconds : 0,end=mediaTool ? settings.endSeconds : Double.greatestFiniteMagnitude
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                var rects:[CGRect]=[]
                let handler=VNImageRequestHandler(cgImage:cg)
                if faces { let request=VNDetectFaceRectanglesRequest();try handler.perform([request]);rects += (request.results ?? []).map(\.boundingBox) }
                if text { let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;try handler.perform([request]);rects += (request.results ?? []).map(\.boundingBox) }
                let regions=rects.map { RedactionRegion(rect:NormalizedRect(x:Double($0.minX),y:Double(1-$0.maxY),width:Double($0.width),height:Double($0.height)),start:start,end:end,style:style,colorHex:hex) }
                DispatchQueue.main.async { settings.redactions.append(contentsOf:regions);busy=false;visionStatus="已识别 \(regions.count) 个区域，可拖动和删除。" }
            } catch { DispatchQueue.main.async { busy=false;self.error=error.localizedDescription } }
        }
    }
    private func slider(_ label: String,_ value: Binding<Double>,_ range: ClosedRange<Double>) -> some View {
        VStack(alignment:.leading,spacing:4) { HStack { Text(label);Spacer();Text(String(format:"%.2f",value.wrappedValue)).monospacedDigit().foregroundColor(.secondary) };Slider(value:value,in:range).tint(Theme.accent) }.font(.caption)
    }
    private func number(_ label: String,_ value: Binding<Double>) -> some View { HStack { Text(label);Spacer();TextField(label,value:value,format:.number.precision(.fractionLength(0...3))).frame(width:90).textFieldStyle(.roundedBorder) }.font(.caption) }
    private func integer(_ label:String,_ value:Binding<Int>) -> some View { HStack { Text(label);Spacer();TextField(label,value:value,format:.number).frame(width:90).textFieldStyle(.roundedBorder) }.font(.caption) }
    private func color(_ label:String,_ value:Binding<String>) -> some View { HStack { ColorPicker(label,selection:Binding(get:{ Color(nsColor:LSColor.hex(value.wrappedValue)) },set:{ value.wrappedValue=LSColor.string(NSColor($0)) }),supportsOpacity:false);TextField("#RRGGBB",text:value).frame(width:85).textFieldStyle(.roundedBorder) }.font(.caption) }
    private func rectFields(_ rect:Binding<NormalizedRect>) -> some View {
        VStack(spacing:5) {
            number("左侧 x",Binding(get:{rect.wrappedValue.x},set:{rect.wrappedValue.x=min(max(0,$0),1-rect.wrappedValue.width)}))
            number("顶部 y",Binding(get:{rect.wrappedValue.y},set:{rect.wrappedValue.y=min(max(0,$0),1-rect.wrappedValue.height)}))
            number("宽度",Binding(get:{rect.wrappedValue.width},set:{rect.wrappedValue.width=min(max(0.001,$0),1-rect.wrappedValue.x)}))
            number("高度",Binding(get:{rect.wrappedValue.height},set:{rect.wrappedValue.height=min(max(0.001,$0),1-rect.wrappedValue.y)}))
        }
    }
}

private struct LSMetadataRow: Identifiable { let id=UUID();var key="";var value="" }
private struct LSPDFView:NSViewRepresentable {
    let document:PDFDocument
    func makeNSView(context:Context)->PDFView { let v=PDFView();v.autoScales=true;v.document=document;return v }
    func updateNSView(_ v:PDFView,context:Context) { v.document=document }
}
// Local PDF page reordering uses native pointer events, so the entire thumbnail
// strip remains responsive without an external system drag session.
private struct LSPDFReorderCapture:NSViewRepresentable {
    let count:Int
    let select:(Int)->Void
    let reorder:(Int,Int)->Void
    func makeNSView(context:Context)->LSPDFReorderView { LSPDFReorderView() }
    func updateNSView(_ view:LSPDFReorderView,context:Context) {
        view.itemCount=count;view.select=select;view.reorder=reorder
    }
}
private final class LSPDFReorderView:NSView {
    var itemCount=0
    var select:((Int)->Void)?
    var reorder:((Int,Int)->Void)?
    private var source:Int?
    private var destination:Int?
    override var isFlipped:Bool {true}
    private func index(at point:NSPoint)->Int? {
        guard itemCount>0 else{return nil}
        return min(itemCount-1,max(0,Int(point.x/94)))
    }
    override func mouseDown(with event:NSEvent) {
        source=index(at:convert(event.locationInWindow,from:nil));destination=source
        if let source=source {select?(source);LSUIEventLog.emit("pdf.local.begin",detail:String(source))}
    }
    override func mouseDragged(with event:NSEvent) {
        destination=index(at:convert(event.locationInWindow,from:nil));needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        let target=index(at:convert(event.locationInWindow,from:nil))
        if let source=source,let target=target,source != target {
            reorder?(source,target);LSUIEventLog.emit("pdf.local.reorder",detail:"\(source)->\(target)")
        }
        source=nil;destination=nil;needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        guard source != nil,let destination=destination else{return}
        NSColor(Theme.accent).setStroke()
        let box=NSRect(x:CGFloat(destination)*94+1,y:1,width:82,height:bounds.height-2)
        let path=NSBezierPath(roundedRect:box,xRadius:7,yRadius:7);path.lineWidth=2;path.stroke()
    }
}
private enum LSColor {
    static func hex(_ value:String)->NSColor {
        let raw=value.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"#",with:"")
        guard let n=UInt64(raw,radix:16),raw.count==6 else{return NSColor.darkGray}
        return NSColor(srgbRed:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:1)
    }
    static func string(_ color:NSColor)->String { let c=color.usingColorSpace(.sRGB) ?? .orange;return String(format:"#%02x%02x%02x",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255)) }
}
private enum LSMetadata {
    static func read(_ url:URL)->[String:String] {
        var result:[String:String]=[:]
        if let src=CGImageSourceCreateWithURL(url as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any] {
            func flatten(_ dict:[String:Any],prefix:String="") { for (key,value) in dict { if let child=value as? [String:Any] { flatten(child,prefix:prefix+key+".") } else { result[prefix+key]=String(describing:value) } } }
            flatten(properties)
        } else if let doc=PDFDocument(url:url) { for (k,v) in doc.documentAttributes ?? [:] { result[String(describing:k)]=String(describing:v) } }
        else { let asset=AVURLAsset(url:url);for item in asset.commonMetadata { if let key=item.commonKey?.rawValue,let value=item.stringValue { result[key]=value } } }
        return result
    }
}

private struct LSCanvas:NSViewRepresentable {
    let image:NSImage
    @Binding var crop:NormalizedRect?
    @Binding var annotations:[ImageAnnotation]
    @Binding var redactions:[RedactionRegion]
    @Binding var selection:UUID?
    let mode:String
    let annotation:ImageAnnotation
    let redaction:RedactionRegion
    let frameBackground:ConversionSettings?
    func makeNSView(context:Context)->LSCanvasView { LSCanvasView() }
    func updateNSView(_ v:LSCanvasView,context:Context) {
        v.image=image;v.crop=crop;v.annotations=annotations;v.redactions=redactions;v.selected=selection;v.mode=mode
        v.annotationTemplate=annotation;v.redactionTemplate=redaction;v.frameSettings=frameBackground
        v.onCrop={ crop=$0 };v.onAnnotations={annotations=$0};v.onRedactions={redactions=$0};v.onSelect={selection=$0}
        v.needsDisplay=true
    }
}
private final class LSCanvasView:NSView {
    var image:NSImage=NSImage()
    var crop:NormalizedRect?
    var annotations:[ImageAnnotation]=[]
    var redactions:[RedactionRegion]=[]
    var selected:UUID?
    var mode="none"
    var annotationTemplate=ImageAnnotation()
    var redactionTemplate=RedactionRegion(rect:NormalizedRect(x:0,y:0,width:0.1,height:0.1))
    var frameSettings:ConversionSettings?
    var onCrop:((NormalizedRect?)->Void)?
    var onAnnotations:(([ImageAnnotation])->Void)?
    var onRedactions:(([RedactionRegion])->Void)?
    var onSelect:((UUID?)->Void)?
    private var start=CGPoint.zero
    private var original:NormalizedRect?
    private var activeID:UUID?
    private var dragKind="new"
    private var draft:NormalizedRect?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    private var sourceSize:NSSize {
        if let rep=image.representations.first,rep.pixelsWide>0 { return NSSize(width:rep.pixelsWide,height:rep.pixelsHigh) };return image.size
    }
    private var canvasRect:NSRect {
        var size=sourceSize
        if let s=frameSettings { size.width += s.padding*2;size.height += s.padding*2;if s.aspectRatio>0 { if size.width/size.height<s.aspectRatio { size.width=size.height*s.aspectRatio } else { size.height=size.width/s.aspectRatio } } }
        let scale=min((bounds.width-24)/max(1,size.width),(bounds.height-24)/max(1,size.height))
        return NSRect(x:(bounds.width-size.width*scale)/2,y:(bounds.height-size.height*scale)/2,width:size.width*scale,height:size.height*scale)
    }
    private var imageRect:NSRect {
        guard let s=frameSettings else{return canvasRect}
        let natural=sourceSize
        var size=NSSize(width:natural.width+s.padding*2,height:natural.height+s.padding*2)
        if s.aspectRatio>0 { if size.width/size.height<s.aspectRatio { size.width=size.height*s.aspectRatio } else { size.height=size.width/s.aspectRatio } }
        let scale=canvasRect.width/size.width
        return NSRect(x:canvasRect.midX-natural.width*scale/2,y:canvasRect.midY-natural.height*scale/2,width:natural.width*scale,height:natural.height*scale)
    }
    override func draw(_ dirtyRect:NSRect) {
        ThemeBackground();let target=imageRect
        if let s=frameSettings {
            let rect=canvasRect
            LSColor.hex(s.backgroundColorHex).setFill();rect.fill()
            if !s.gradientEndHex.isEmpty { NSGradient(starting:LSColor.hex(s.backgroundColorHex),ending:LSColor.hex(s.gradientEndHex))?.draw(in:rect,angle:45) }
            if let u=s.backgroundImage,let bg=NSImage(contentsOf:u) { bg.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil) }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect:target,xRadius:s.cornerRadius*target.width/max(1,sourceSize.width),yRadius:s.cornerRadius*target.width/max(1,sourceSize.width)).addClip()
            image.draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else { image.draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high]) }
        for r in redactions { drawRedaction(r,in:target) }
        for (i,a) in annotations.enumerated() { drawAnnotation(a,index:i+1,in:target) }
        if let crop=crop {
            let r=screen(crop);let shade=NSBezierPath(rect:target);shade.append(NSBezierPath(rect:r));shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill();shade.fill();outline(r,color:LSPaint.accent)
        }
        if let draft=draft { outline(screen(draft),color:NSColor(Theme.accent)) }
        if let active=selected {
            if let a=annotations.first(where:{$0.id==active}) { outline(screen(a.rect),color:LSPaint.accent) }
            if let r=redactions.first(where:{$0.id==active}) { outline(screen(r.rect),color:LSPaint.accent) }
        }
    }
    private func ThemeBackground() { NSColor(Theme.canvas).setFill();bounds.fill() }
    private func screen(_ n:NormalizedRect)->NSRect { let r=imageRect;return NSRect(x:r.minX+n.x*r.width,y:r.minY+n.y*r.height,width:n.width*r.width,height:n.height*r.height) }
    private func outline(_ r:NSRect,color:NSColor) { color.setStroke();let p=NSBezierPath(rect:r);p.lineWidth=1.5;p.stroke();color.setFill();NSBezierPath(roundedRect:NSRect(x:r.maxX-4,y:r.maxY-4,width:8,height:8),xRadius:2,yRadius:2).fill() }
    private func drawRedaction(_ region:RedactionRegion,in target:NSRect) {
        let rect=screen(region.rect)
        if region.style == "solid" { LSColor.hex(region.colorHex).setFill();rect.fill() }
        else if let data=image.tiffRepresentation,let rep=NSBitmapImageRep(data:data),let cg=rep.cgImage {
            let ci=CIImage(cgImage:cg);let blurred=ci.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:24]).cropped(to:ci.extent)
            if let out=CIContext().createCGImage(blurred,from:ci.extent) {
                NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:rect).addClip()
                NSImage(cgImage:out,size:image.size).draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSColor.white.withAlphaComponent(0.4).setStroke();NSBezierPath(rect:rect).stroke()
    }
    private func drawAnnotation(_ a:ImageAnnotation,index:Int,in target:NSRect) {
        let r=screen(a.rect),scale=target.width/max(1,sourceSize.width),color=LSColor.hex(a.colorHex)
        color.setStroke();color.setFill()
        let p=NSBezierPath();p.lineWidth=max(1,a.lineWidth*scale)
        switch a.kind {
        case "arrow":
            p.move(to:r.origin);p.line(to:NSPoint(x:r.maxX,y:r.maxY));p.stroke()
            let angle=atan2(r.height,r.width),length=max(9,a.lineWidth*scale*4)
            let tip=NSPoint(x:r.maxX,y:r.maxY)
            p.removeAllPoints();p.move(to:tip);p.line(to:NSPoint(x:tip.x-length*cos(angle-0.45),y:tip.y-length*sin(angle-0.45)));p.line(to:NSPoint(x:tip.x-length*cos(angle+0.45),y:tip.y-length*sin(angle+0.45)));p.close();p.fill()
        case "rectangle":p.appendRect(r);p.stroke()
        case "ellipse":p.appendOval(in:r);p.stroke()
        case "number":
            NSBezierPath(ovalIn:r).fill();let text=a.text.isEmpty ? String(index) : a.text
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.boldSystemFont(ofSize:max(11,a.fontSize*scale)),.foregroundColor:NSColor.white]
            let size=(text as NSString).size(withAttributes:attrs);(text as NSString).draw(at:NSPoint(x:r.midX-size.width/2,y:r.midY-size.height/2),withAttributes:attrs)
        default:
            (a.text as NSString).draw(in:r,withAttributes:[.font:NSFont.systemFont(ofSize:max(8,a.fontSize*scale),weight:.semibold),.foregroundColor:color])
        }
    }
    private func point(_ event:NSEvent)->CGPoint {
        let p=convert(event.locationInWindow,from:nil),r=imageRect
        return CGPoint(x:min(1,max(0,(p.x-r.minX)/max(1,r.width))),y:min(1,max(0,(p.y-r.minY)/max(1,r.height))))
    }
    override func mouseDown(with event:NSEvent) {
        guard mode != "none" else{return};window?.makeFirstResponder(self);start=point(event);activeID=nil;original=nil;dragKind="new";draft=nil
        let p=convert(event.locationInWindow,from:nil)
        var existing:NormalizedRect?
        if mode == "crop",let c=crop,screen(c).insetBy(dx:-6,dy:-6).contains(p) { existing=c }
        else if mode == "redact",let r=redactions.reversed().first(where:{screen($0.rect).insetBy(dx:-5,dy:-5).contains(p)}) { existing=r.rect;activeID=r.id }
        else if mode != "redact",mode != "crop",let a=annotations.reversed().first(where:{screen($0.rect).insetBy(dx:-5,dy:-5).contains(p)}) { existing=a.rect;activeID=a.id }
        if let r=existing { original=r;let corner=screen(r);dragKind=hypot(p.x-corner.maxX,p.y-corner.maxY)<15 ? "resize" : "move" }
        selected=activeID;onSelect?(activeID);needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent) {
        guard mode != "none" else{return};let p=point(event);var next:NormalizedRect
        if let old=original {
            if dragKind == "resize" { next=NormalizedRect(x:old.x,y:old.y,width:min(1-old.x,max(0.005,old.width+p.x-start.x)),height:min(1-old.y,max(0.005,old.height+p.y-start.y))) }
            else { next=NormalizedRect(x:min(max(0,old.x+p.x-start.x),1-old.width),y:min(max(0,old.y+p.y-start.y),1-old.height),width:old.width,height:old.height) }
        } else { next=NormalizedRect(x:min(start.x,p.x),y:min(start.y,p.y),width:max(0.001,abs(p.x-start.x)),height:max(0.001,abs(p.y-start.y))) }
        if mode == "crop" { crop=next;onCrop?(next) }
        else if let id=activeID {
            if let index=annotations.firstIndex(where:{$0.id==id}) { annotations[index].rect=next;onAnnotations?(annotations) }
            if let index=redactions.firstIndex(where:{$0.id==id}) { redactions[index].rect=next;onRedactions?(redactions) }
        } else { draft=next }
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        defer{draft=nil;needsDisplay=true}
        guard let rect=draft,rect.width>0.004,rect.height>0.004,activeID==nil else{return}
        if mode == "redact" { var region=redactionTemplate;region.id=UUID();region.rect=rect;redactions.append(region);selected=region.id;onSelect?(selected);onRedactions?(redactions) }
        else if mode != "crop" && mode != "none" { var a=annotationTemplate;a.id=UUID();a.rect=rect;a.kind=mode;if a.kind == "number",a.text=="文字" {a.text=String(annotations.count+1)};annotations.append(a);selected=a.id;onSelect?(selected);onAnnotations?(annotations) }
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode==51 || event.keyCode==117 { if let id=selected {annotations.removeAll{$0.id==id};redactions.removeAll{$0.id==id};onAnnotations?(annotations);onRedactions?(redactions);selected=nil;onSelect?(nil);needsDisplay=true} }
        else {super.keyDown(with:event)}
    }
}

private final class LSMediaPreview:ObservableObject {
    @Published var player:AVPlayer?
    @Published var duration:Double=0
    @Published var position:Double=0
    @Published var playing=false
    @Published var waveform:[Float]=[]
    @Published var frame:NSImage?
    @Published var error:String?
    private var observer:Any?
    private var generator:AVAssetImageGenerator?
    private var framePending=false
    private var lastFrameTime:Double = -1
    private var rangeEnd:Double?
    private var fps:Double=30
    private var generation=UUID()
    private var previewContext:OperationContext?
    private var proxyFolder:URL?
    private var waveformReader:AVAssetReader?
    private let readerLock=NSLock()
    func load(_ url:URL,ready:@escaping(Double)->Void) { load(url,allowProxy:true,ready:ready) }
    private func load(_ url:URL,allowProxy:Bool,ready:@escaping(Double)->Void) {
        stop();let token=UUID();readerLock.lock();generation=token;readerLock.unlock()
        duration=0;position=0;frame=nil;waveform=[];error=nil;framePending=false;lastFrameTime = -1
        let asset=AVURLAsset(url:url);let player=AVPlayer(playerItem:AVPlayerItem(asset:asset));self.player=player
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true;generator.maximumSize=NSSize(width:1400,height:1000);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero;self.generator=generator
        asset.loadValuesAsynchronously(forKeys:["duration","tracks","playable"]) { [weak self] in
            DispatchQueue.main.async {
                guard let self=self,self.generation==token else{return}
                let seconds=asset.duration.seconds
                if !asset.isPlayable || !seconds.isFinite || seconds<=0 {
                    if allowProxy {self.createProxy(url,ready:ready,token:token)}
                    else {self.error="无法解码预览；仍可编辑参数并交由本地引擎处理。"}
                    return
                }
                self.duration=seconds;self.fps=Double(asset.tracks(withMediaType:.video).first?.nominalFrameRate ?? 30);if self.fps<=0{self.fps=30}
                ready(seconds);self.capture(0)
            }
        }
        observer=player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.08,preferredTimescale:600),queue:.main) { [weak self] time in
            guard let self=self else{return};let value=time.seconds
            if value.isFinite { self.position=value;self.capture(value) }
            self.playing=player.rate != 0
            if let end=self.rangeEnd,value>=end {player.pause();self.playing=false;self.rangeEnd=nil}
        }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let values=Self.readWaveform(asset) { reader in
                guard let self=self else{return false};self.readerLock.lock();defer{self.readerLock.unlock()}
                guard self.generation==token else{return false};self.waveformReader=reader;return true
            }
            DispatchQueue.main.async { guard self?.generation==token else{return};self?.waveform=values }
        }
    }
    func seek(_ value:Double) {
        let v=min(max(0,value),max(duration,0));position=v
        player?.seek(to:CMTime(seconds:v,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
        capture(v)
    }
    func step(_ offset:Int) {player?.pause();playing=false;seek(position+Double(offset)/fps)}
    func toggle() {if player?.rate != 0 {player?.pause();playing=false} else {rangeEnd=nil;player?.play();playing=true}}
    func playRange(start:Double,end:Double,rate:Float) {seek(start);rangeEnd=end;player?.rate=rate;playing=true}
    func stop() {
        readerLock.lock();generation=UUID();let reader=waveformReader;waveformReader=nil;readerLock.unlock();reader?.cancelReading()
        player?.pause();if let observer=observer {player?.removeTimeObserver(observer)};observer=nil;generator?.cancelAllCGImageGeneration();playing=false
        previewContext?.cancel();previewContext=nil
        if let folder=proxyFolder {try? FileManager.default.removeItem(at:folder)};proxyFolder=nil
    }
    private func createProxy(_ source:URL,ready:@escaping(Double)->Void,token:UUID) {
        guard previewContext==nil,let ff=OperationContext.executable("ffmpeg") else {error="此格式需要 FFmpeg 才能建立本地预览。";return}
        let context=OperationContext();previewContext=context
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("LocalShift-preview-"+UUID().uuidString,isDirectory:true)
        let video=ConverterEngine.category(for:source) == .video
        let out=folder.appendingPathComponent(video ? "preview.mp4" : "preview.m4a")
        error="正在本地建立兼容预览…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                var args=["-nostdin","-v","error","-y","-protocol_whitelist","file,pipe","-i",source.path]
                args += video ? ["-map","0:v:0","-map","0:a:0?","-vf","scale=1280:720:force_original_aspect_ratio=decrease,pad=ceil(iw/2)*2:ceil(ih/2)*2","-c:v","libx264","-preset","ultrafast","-crf","25","-pix_fmt","yuv420p","-c:a","aac"] : ["-vn","-c:a","aac","-b:a","160k"]
                try context.run(ff,args+[out.path],timeout:1800)
                DispatchQueue.main.async {
                    guard let self=self,self.generation==token else{try? FileManager.default.removeItem(at:folder);return}
                    self.load(out,allowProxy:false,ready:ready);self.proxyFolder=folder;self.error=nil
                }
            } catch {
                try? FileManager.default.removeItem(at:folder)
                DispatchQueue.main.async {guard let self=self,self.generation==token else{return};self.error="无法建立本地预览："+error.localizedDescription;self.previewContext=nil}
            }
        }
    }
    private func capture(_ seconds:Double) {
        guard let generator=generator,!framePending,abs(seconds-lastFrameTime)>0.12 || frame==nil else{return}
        framePending=true;lastFrameTime=seconds;let token=generation
        generator.generateCGImagesAsynchronously(forTimes:[NSValue(time:CMTime(seconds:seconds,preferredTimescale:60000))]) { [weak self] _,cg,_,_,_ in
            DispatchQueue.main.async {guard let self=self,self.generation==token else{return};self.framePending=false;if let cg=cg {self.frame=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))}}
        }
    }
    private static func readWaveform(_ asset:AVAsset,install:(AVAssetReader)->Bool)->[Float] {
        guard let track=asset.tracks(withMediaType:.audio).first,let reader=try? AVAssetReader(asset:asset) else{return []}
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false,AVSampleRateKey:8000,AVNumberOfChannelsKey:1])
        output.alwaysCopiesSampleData=false;guard reader.canAdd(output),install(reader) else{return []};reader.add(output);guard reader.startReading() else{return []}
        let duration=asset.duration.seconds;guard duration.isFinite,duration>0 else{return []}
        var peaks=[Float](repeating:0,count:900)
        while let buffer=output.copyNextSampleBuffer() {
            guard let block=CMSampleBufferGetDataBuffer(buffer) else{continue}
            var length=0;var pointer:UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block,atOffset:0,lengthAtOffsetOut:nil,totalLengthOut:&length,dataPointerOut:&pointer)==kCMBlockBufferNoErr,let pointer=pointer else{continue}
            let time=CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            pointer.withMemoryRebound(to:Float.self,capacity:length/4) { samples in
                for i in 0..<length/4 {let index=min(899,max(0,Int((time+Double(i)/8000)/duration*900)));let sample=abs(samples[i]);if sample.isFinite {peaks[index]=max(peaks[index],sample)}}
            }
        }
        let high=max(0.01,peaks.max() ?? 1);return peaks.map{min(1,$0/high)}
    }
}

private struct LSTimeline:View {
    @Binding var position:Double
    @Binding var start:Double
    @Binding var end:Double
    let duration:Double
    let samples:[Float]
    let points:[Double]
    let ranges:[TimeRange]
    let onSeek:(Double)->Void
    private func ratio(_ value:Double)->Double {min(1,max(0,value/max(0.001,duration)))}
    var body:some View {
        GeometryReader { g in
            let width=g.size.width
            ZStack(alignment:.topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.canvas)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1).allowsHitTesting(false))
                Canvas { context,size in
                    let count=max(1,samples.count)
                    var path=Path()
                    for (i,sample) in samples.enumerated() {let x=Double(i)/Double(count)*size.width;let amplitude=max(1,CGFloat(sample)*size.height*0.4);path.move(to:CGPoint(x:x,y:size.height/2-amplitude));path.addLine(to:CGPoint(x:x,y:size.height/2+amplitude))}
                    context.stroke(path,with:.color(Theme.muted.opacity(0.65)),lineWidth:1)
                    for range in ranges {context.fill(Path(CGRect(x:ratio(range.start)*size.width,y:0,width:max(0,ratio(range.end)-ratio(range.start))*size.width,height:size.height)),with:.color(.red.opacity(0.22)))}
                    for point in points {var p=Path();p.move(to:CGPoint(x:ratio(point)*size.width,y:0));p.addLine(to:CGPoint(x:ratio(point)*size.width,y:size.height));context.stroke(p,with:.color(Theme.accent.opacity(0.85)),lineWidth:2)}
                }
                Rectangle().fill(Theme.accent.opacity(0.15)).frame(width:max(0,ratio(end)-ratio(start))*width).offset(x:ratio(start)*width).allowsHitTesting(false)
                Rectangle().fill(Theme.text.opacity(0.85)).frame(width:2).offset(x:ratio(position)*width).allowsHitTesting(false)
                HStack(spacing:0) { Rectangle().fill(Theme.accent).frame(width:9);Spacer() }.frame(width:9).contentShape(Rectangle()).offset(x:ratio(start)*width-4).highPriorityGesture(DragGesture(minimumDistance:0,coordinateSpace:.named("LSTimeline")).onChanged {v in start=min(max(0,Double(v.location.x)/width*duration),max(0,end-0.01))})
                HStack(spacing:0) {Rectangle().fill(Theme.accent).frame(width:9);Spacer()}.frame(width:9).contentShape(Rectangle()).offset(x:ratio(end)*width-4).highPriorityGesture(DragGesture(minimumDistance:0,coordinateSpace:.named("LSTimeline")).onChanged {v in end=max(start+0.01,min(duration,Double(v.location.x)/width*duration))})
            }
            .coordinateSpace(name:"LSTimeline")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged {v in let value=min(duration,max(0,Double(v.location.x/width)*duration));position=value;onSeek(value)})
        }
    }
}
private struct LSVisualizerPreview:View {
    let samples:[Float]
    let settings:ConversionSettings
    var body:some View {
        GeometryReader { g in
            ZStack {
                Color(nsColor:LSColor.hex(settings.backgroundColorHex))
                if let u=settings.backgroundImage,let image=NSImage(contentsOf:u) {Image(nsImage:image).resizable().scaledToFill().frame(width:g.size.width,height:g.size.height).clipped().opacity(0.65)}
                Canvas { context,size in
                    var path=Path();let bins=80
                    for i in 0..<bins {let index=min(max(0,samples.count-1),i*max(1,samples.count)/bins);let value=samples.isEmpty ? 0.05 : CGFloat(samples[index]);let x=size.width*0.08+CGFloat(i)/CGFloat(bins)*size.width*0.84;let h=max(3,value*size.height*0.5);path.move(to:CGPoint(x:x,y:size.height/2-h/2));path.addLine(to:CGPoint(x:x,y:size.height/2+h/2))}
                    context.stroke(path,with:.color(Color(nsColor: LSColor.hex("#FF8A32"))),style:StrokeStyle(lineWidth:4,lineCap:.round))
                }
            }.aspectRatio(settings.visualizerLayout == "portrait" ? 9/16 : settings.visualizerLayout == "square" ? 1 : 16/9,contentMode:.fit)
        }
    }
}

private struct LSCollagePreview:NSViewRepresentable {
    let urls:[URL]
    let settings:ConversionSettings
    func makeNSView(context:Context)->LSCollageView {LSCollageView()}
    func updateNSView(_ v:LSCollageView,context:Context) {v.urls=urls;v.settings=settings;v.needsDisplay=true}
}
private final class LSCollageView:NSView {
    var urls:[URL]=[]
    var settings=ConversionSettings()
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        let w=Double(settings.width),h=Double(settings.height),p=settings.padding,n=urls.count
        guard w>0,h>0,n>0 else{return}
        let scale=min((bounds.width-20)/w,(bounds.height-20)/h)
        let origin=CGPoint(x:(bounds.width-w*scale)/2,y:(bounds.height-h*scale)/2)
        let canvas=CGRect(x:origin.x,y:origin.y,width:w*scale,height:h*scale)
        LSColor.hex(settings.backgroundColorHex).setFill();canvas.fill()
        var cells:[CGRect]=[]
        if settings.collageLayout=="featured",n>1 {
            let mainW=(w-3*p)*0.66,rightW=w-3*p-mainW,smallH=(h-Double(n)*p)/Double(n-1)
            guard mainW>0,rightW>0,smallH>0 else{return}
            cells.append(CGRect(x:p,y:p,width:mainW,height:h-2*p))
            for i in 0..<n-1 {cells.append(CGRect(x:2*p+mainW,y:p+Double(i)*(smallH+p),width:rightW,height:smallH))}
        } else {
            let columns=settings.collageLayout=="row" ? n : settings.collageLayout=="column" ? 1 : max(1,min(n,settings.collageColumns))
            let rows=(n+columns-1)/columns,cw=(w-Double(columns+1)*p)/Double(columns),ch=(h-Double(rows+1)*p)/Double(rows)
            guard cw>0,ch>0 else{return}
            for i in 0..<n {cells.append(CGRect(x:p+Double(i%columns)*(cw+p),y:p+Double(i/columns)*(ch+p),width:cw,height:ch))}
        }
        for (i,url) in urls.enumerated() {
            guard let image=NSImage(contentsOf:url),cells.indices.contains(i) else{continue}
            let cell=cells[i],rect=CGRect(x:origin.x+cell.minX*scale,y:origin.y+cell.minY*scale,width:cell.width*scale,height:cell.height*scale)
            NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:rect,xRadius:settings.cornerRadius*scale,yRadius:settings.cornerRadius*scale).addClip()
            let imageScale=max(rect.width/max(1,image.size.width),rect.height/max(1,image.size.height))
            let size=NSSize(width:image.size.width*imageScale,height:image.size.height*imageScale)
            image.draw(in:CGRect(x:rect.midX-size.width/2,y:rect.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

enum LSUIVerification {
    static func canvasChecks()->[(String,Bool)] {
        let image=NSImage(size:NSSize(width:320,height:200));image.lockFocus();NSColor.orange.setFill();NSRect(x:0,y:0,width:320,height:200).fill();image.unlockFocus()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let view=LSCanvasView(frame:NSRect(x:0,y:0,width:600,height:400));view.image=image;window.contentView=view
        func event(_ kind:NSEvent.EventType,_ x:Double,_ y:Double)->NSEvent {NSEvent.mouseEvent(with:kind,location:CGPoint(x:x,y:400-y),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!}
        view.mode="crop";view.mouseDown(with:event(.leftMouseDown,70,70));view.mouseDragged(with:event(.leftMouseDragged,360,250));view.mouseUp(with:event(.leftMouseUp,360,250))
        let crop=view.crop
        var checks=[("Image canvas drag creates normalized crop",crop != nil && (crop?.width ?? 0)>0.4 && (crop?.height ?? 0)>0.3)]
        view.mode="rectangle";view.mouseDown(with:event(.leftMouseDown,80,80));view.mouseDragged(with:event(.leftMouseDragged,250,200));view.mouseUp(with:event(.leftMouseUp,250,200))
        checks.append(("Image canvas drag creates editable annotation",view.annotations.count==1 && view.annotations[0].kind=="rectangle"))
        let before=view.annotations.first?.rect.x ?? 0
        view.mouseDown(with:event(.leftMouseDown,130,130));view.mouseDragged(with:event(.leftMouseDragged,160,130));view.mouseUp(with:event(.leftMouseUp,160,130))
        checks.append(("Image annotation can be moved",(view.annotations.first?.rect.x ?? 0)>before))
        view.mode="redact";view.mouseDown(with:event(.leftMouseDown,330,110));view.mouseDragged(with:event(.leftMouseDragged,440,200));view.mouseUp(with:event(.leftMouseUp,440,200))
        checks.append(("Image canvas drag creates redaction region",view.redactions.count==1))
        checks.append(("Native canvas renders crop annotations and redactions",view.dataWithPDF(inside:view.bounds).count>500))
        window.close();return checks
    }
}

// Opt-in UI diagnostics for reproducible native drag acceptance; no logging in normal runs.
enum LSUIEventLog {
    static func emit(_ event: String, detail: String = "") {
        guard let path=ProcessInfo.processInfo.environment["LOCALSHIFT_UI_EVENT_LOG"] else{return}
        let line=Date().ISO8601Format()+" "+event+" "+detail+"\n"
        guard let data=line.data(using:.utf8) else{return}
        if let handle=FileHandle(forWritingAtPath:path) {defer{try? handle.close()};do{try handle.seekToEnd();try handle.write(contentsOf:data)}catch{}}
        else {try? data.write(to:URL(fileURLWithPath:path),options:.atomic)}
    }
}
