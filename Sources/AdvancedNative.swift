import Cocoa
import ImageIO
import PDFKit
import CoreImage
import Vision
import UniformTypeIdentifiers
import Darwin
import Quartz

/// Native image/PDF operations. Every returned URL belongs to the caller's scratch directory.
enum AdvancedNative {
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static let fm = FileManager.default
    static var webpAvailable: Bool { webpLibrary != nil }
    private static let webpLibrary: UnsafeMutableRawPointer? = {
        for path in [OperationContext.frameworksURL?.appendingPathComponent("libwebp.7.dylib").path].compactMap({ $0 })
                    + OperationContext.systemCandidates(["/opt/homebrew/lib/libwebp.7.dylib", "/usr/local/lib/libwebp.7.dylib"]) {
            if let lib = dlopen(path, RTLD_NOW | RTLD_LOCAL) { return lib }
        }
        return nil
    }()
    static func convert(_ files: [URL], option: String, settings: ConversionSettings, scratch: URL,
                        context: OperationContext, progress: @escaping (Double, String) -> Void) throws -> [URL] {
        guard let file = files.first else { throw ConverterError.message("没有输入文件。") }
        try context.check()
        if file.pathExtension.lowercased() == "pdf" { return try pdf(files, option: option, settings: settings, scratch: scratch, context: context, progress: progress) }
        if option == "createPDF" {
            let document = PDFDocument()
            for (index, url) in files.enumerated() {
                try context.check()
                let source = multipageTIFFSource(url)
                let count = try source.map { try validateTIFFPages($0, context: context) } ?? 1
                for pageIndex in 0..<count {
                    try context.check()
                    let image: CGImage
                    if let source = source { image = try readFrame(source, index: pageIndex, context: context).0 }
                    else { image = try read(url, scratch: scratch, context: context).0 }
                    try appendPDFImage(image, to: document)
                    progress((Double(index) + Double(pageIndex + 1) / Double(count)) / Double(files.count), "创建 PDF 页面")
                }
            }
            let out = target(file, suffix: "-combined", ext: "pdf", scratch: scratch)
            try writePDF(document, out: out); return [out]
        }
        if option == "createCollage" {
            var images: [CGImage] = []
            for url in files { try context.check(); images.append(try read(url, scratch: scratch, context: context).0) }
            let result = try collage(images, settings: settings, scratch: scratch, context: context)
            let out = target(file, suffix: "-collage", ext: "png", scratch: scratch)
            try encode(result, to: out, format: "png", quality: 1, properties: [:], context: context)
            progress(1, "已创建拼贴"); return [out]
        }
        if let source = multipageTIFFSource(file) {
            guard option.hasPrefix("format_") else { throw multipageToolError(file, count: CGImageSourceGetCount(source)) }
            return try convertTIFFPages(source, file: file, format: normalizedFormat(String(option.dropFirst(7))), settings: settings, scratch: scratch, context: context, progress: progress)
        }
        var (image, properties) = try read(file, scratch: scratch, context: context)
        if option=="readQRCode" {
            let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request]);try context.check()
            let payloads=(request.results ?? []).compactMap{$0.payloadStringValue}
            guard !payloads.isEmpty else {throw ConverterError.message("图片中未检测到包含可读文字的二维码。")}
            let text=payloads.count==1 ? payloads[0]+"\n" : payloads.enumerated().map{"--- QR \($0.offset+1) ---\n"+$0.element}.joined(separator:"\n\n")+"\n"
            let output=target(file,suffix:"-qr-codes",ext:"txt",scratch:scratch)
            try text.write(to:output,atomically:true,encoding:.utf8);progress(1,"已读取 \(payloads.count) 个二维码");return [output]
        }
        let original = normalizedFormat(file.pathExtension)
        var format = option.hasPrefix("format_") ? String(option.dropFirst(7)) : (settings.outputFormat.isEmpty ? original : normalizedFormat(settings.outputFormat))
        if !["png","jpg","webp","heic","tiff","avif","bmp","gif","pdf"].contains(format) { format = "png" }
        var suffix = option.hasPrefix("format_") ? "" : "-" + option
        if option == "compress" { suffix = "-compressed" }
        if option == "removeMetadata" {
            if format=="bmp",!settings.metadata.isEmpty {throw ConverterError.message("BMP 容器不支持 EXIF/IPTC 标签；请选择 PNG、TIFF、WebP 等输出格式编辑元数据。")}
            properties = settings.removeMetadata ? [:] : properties
            applyMetadata(settings.metadata, properties: &properties)
        } else {
            // Pixels have baked orientation; stale dimensions/orientation must not override them.
            properties[kCGImagePropertyOrientation] = 1
        }
        switch option {
        case "editImage": image = try edit(image, settings: settings)
        case "cropImage": image = try crop(image, settings: settings)
        case "annotateImage": image = try annotate(image, annotations: settings.annotations)
        case "frameImage": image = try frame(image, settings: settings, scratch: scratch, context: context)
        case "redactImage": image = try redact(image, settings: settings, context: context)
        case "removeMetadata", "compress": break
        default: guard option.hasPrefix("format_") else { throw ConverterError.message("不支持的图片操作：" + option) }
        }
        try context.check()
        let out = target(file, suffix: suffix, ext: format, scratch: scratch)
        if option == "compress" {
            try compress(image, original: file, to: out, format: format, settings: settings, properties: settings.removeMetadata ? [:] : properties, context: context, progress: progress)
        } else if format == "pdf" {
            let doc = PDFDocument()
            guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { throw ConverterError.message("无法创建 PDF。") }
            doc.insert(page, at: 0); try writePDF(doc, out: out)
        } else {
            if option == "removeMetadata", !settings.metadata.isEmpty, ["avif"].contains(format) {
                // AVIF metadata is carried through the encoder's container tag interface.
                try encode(image, to: out, format: format, quality: settings.quality, properties: properties, context: context, tags: settings.metadata)
            } else { try encode(image, to: out, format: format, quality: settings.quality, properties: properties, context: context) }
        }
        progress(1, "图片处理完成"); return [out]
    }
    private static func normalizedFormat(_ value: String) -> String {
        let s = value.lowercased(); return ["jpeg":"jpg","tif":"tiff","heif":"heic"][s] ?? s
    }
    private static func target(_ file: URL, suffix: String, ext: String, scratch: URL) -> URL {
        scratch.appendingPathComponent(file.deletingPathExtension().lastPathComponent + suffix + "." + ext)
    }
    private static func read(_ file: URL, scratch: URL, context: OperationContext) throws -> (CGImage, [CFString: Any]) {
        try context.check()
        var url = file
        let initial=CGImageSourceCreateWithURL(url as CFURL,nil)
        if let source=initial, isTIFF(source), CGImageSourceGetCount(source)>1 {
            throw multipageToolError(file, count: CGImageSourceGetCount(source))
        }
        if let initial=initial,let props=CGImageSourceCopyPropertiesAtIndex(initial,0,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int {
            guard width>0,height>0,width<=16384,height<=16384,Int64(width)*Int64(height)<=100_000_000 else {throw ConverterError.message("图片超过支持的尺寸（16384 / 一亿像素）。")}
        }
        if initial == nil || CGImageSourceCreateImageAtIndex(initial!,0,[kCGImageSourceShouldCache:false] as CFDictionary) == nil {
            if let ns = NSImage(contentsOf: file), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) { return (cg, [:]) }
            guard let ff = OperationContext.executable("ffmpeg") else { throw ConverterError.message("系统无法解码图片，且没有 FFmpeg。") }
            url = scratch.appendingPathComponent("decode-" + UUID().uuidString + ".png")
            try context.run(ff, ["-nostdin","-v","error","-y","-protocol_whitelist","file,pipe","-i",file.path,"-frames:v","1",url.path])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConverterError.message("无法解码图片：" + file.lastPathComponent) }
        return try readFrame(source, index: 0, context: context)
    }
    private static func isTIFF(_ source: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(source) else { return false }
        return (type as String) == UTType.tiff.identifier
    }
    private static func multipageTIFFSource(_ file: URL) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), isTIFF(source), CGImageSourceGetCount(source)>1 else { return nil }
        return source
    }
    private static func multipageToolError(_ file: URL, count: Int) -> ConverterError {
        .message("“" + file.lastPathComponent + "”包含 \(count) 页 TIFF。此操作暂不支持直接编辑、拼贴或作为背景处理多页 TIFF；请先转换为 PNG/JPEG 导出全部页面，再选择需要的页面。源文件未更改。")
    }
    private static func validateDimensions(_ width: Int, _ height: Int) throws {
        guard width>0,height>0,width<=16384,height<=16384,Int64(width)*Int64(height)<=100_000_000 else { throw ConverterError.message("图片超过支持的尺寸（16384 / 一亿像素）。") }
    }
    private static func validateTIFFPages(_ source: CGImageSource, context: OperationContext) throws -> Int {
        let count = CGImageSourceGetCount(source)
        guard count>0,count<=10000 else { throw ConverterError.message("TIFF 页数无效或超过 10000 页。") }
        var totalPixels: Int64 = 0
        for index in 0..<count {
            try context.check()
            guard let props = CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { throw ConverterError.message("无法读取 TIFF 第 \(index+1) 页的尺寸，未导出不完整结果。") }
            try validateDimensions(width,height)
            totalPixels += Int64(width)*Int64(height)
            guard totalPixels<=100_000_000 else { throw ConverterError.message("多页 TIFF 总像素超过一亿，无法安全处理全部页面；未导出不完整结果。") }
        }
        return count
    }
    private static func readFrame(_ source: CGImageSource, index: Int, context: OperationContext) throws -> (CGImage, [CFString:Any]) {
        try context.check()
        if let props=CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any],let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int { try validateDimensions(width,height) }
        guard var image = CGImageSourceCreateImageAtIndex(source,index,[kCGImageSourceShouldCache:false] as CFDictionary) else { throw ConverterError.message("无法解码图片第 \(index+1) 页，未导出不完整结果。") }
        try validateDimensions(image.width,image.height)
        var props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation != 1 {
            let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
            guard let result = ci.createCGImage(oriented, from: oriented.extent) else { throw ConverterError.message("图片方向处理失败。") }
            image = result
        }
        var tiff=props[kCGImagePropertyTIFFDictionary] as? [CFString:Any] ?? [:]
        let iptc=props[kCGImagePropertyIPTCDictionary] as? [CFString:Any] ?? [:],png=props[kCGImagePropertyPNGDictionary] as? [CFString:Any] ?? [:]
        if tiff[kCGImagePropertyTIFFArtist]==nil {tiff[kCGImagePropertyTIFFArtist]=(iptc[kCGImagePropertyIPTCByline] as? [String])?.joined(separator:", ") ?? png[kCGImagePropertyPNGAuthor]}
        if !tiff.isEmpty {props[kCGImagePropertyTIFFDictionary]=tiff}
        props[kCGImagePropertyOrientation] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth); props.removeValue(forKey: kCGImagePropertyPixelHeight)
        return (image, props)
    }
    private static func appendPDFImage(_ image: CGImage, to document: PDFDocument) throws {
        guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { throw ConverterError.message("无法创建图片 PDF 页面。") }
        document.insert(page, at: document.pageCount)
    }
    /// TIFF pages remain in source order. Single-frame targets produce one named file per page;
    /// PDF/TIFF targets retain the pages in one container. Tools reject hidden-page editing.
    private static func convertTIFFPages(_ source: CGImageSource, file: URL, format: String, settings: ConversionSettings, scratch: URL, context: OperationContext, progress: @escaping (Double,String)->Void) throws -> [URL] {
        let count = try validateTIFFPages(source, context: context)
        guard ["png","jpg","webp","heic","tiff","avif","bmp","gif","pdf"].contains(format) else { throw ConverterError.message("不支持的多页 TIFF 输出格式。") }
        if format == "pdf" {
            let document = PDFDocument()
            for index in 0..<count {
                try appendPDFImage(readFrame(source,index:index,context:context).0, to:document)
                progress(Double(index+1)/Double(count), "创建 PDF 第 \(index+1) / \(count) 页")
            }
            let output = target(file,suffix:"",ext:"pdf",scratch:scratch)
            try context.check();try writePDF(document,out:output)
            return [output]
        }
        if format == "tiff" {
            let output = target(file,suffix:"",ext:"tiff",scratch:scratch)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL,UTType.tiff.identifier as CFString,count,nil) else { throw ConverterError.message("无法创建多页 TIFF。") }
            for index in 0..<count {
                var (image,properties) = try readFrame(source,index:index,context:context)
                properties[kCGImageDestinationLossyCompressionQuality]=settings.quality
                CGImageDestinationAddImage(destination,image,properties as CFDictionary)
                progress(Double(index+1)/Double(count), "写入 TIFF 第 \(index+1) / \(count) 页")
            }
            try context.check()
            guard CGImageDestinationFinalize(destination),let check=CGImageSourceCreateWithURL(output as CFURL,nil),CGImageSourceGetCount(check)==count else { throw ConverterError.message("多页 TIFF 写出或页数验证失败。") }
            return [output]
        }
        var outputs: [URL] = []
        for index in 0..<count {
            let (image,properties) = try readFrame(source,index:index,context:context)
            let output = target(file,suffix:String(format:"-page-%04d",index+1),ext:format,scratch:scratch)
            try encode(image,to:output,format:format,quality:settings.quality,properties:properties,context:context)
            outputs.append(output)
            progress(Double(index+1)/Double(count), "导出第 \(index+1) / \(count) 页")
        }
        return outputs
    }
    private static func canvas(_ width: Int, _ height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 16384, height <= 16384, Int64(width) * Int64(height) <= 100_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConverterError.message("图片画布过大或尺寸无效（最大一亿像素）。") }
        ctx.interpolationQuality = .high; return ctx
    }
    private static func result(_ ctx: CGContext) throws -> CGImage {
        guard let image = ctx.makeImage() else { throw ConverterError.message("无法生成图像。") }; return image
    }
    private static func resize(_ image: CGImage, _ width: Int, _ height: Int) throws -> CGImage {
        let ctx = try canvas(width, height); ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return try result(ctx)
    }
    private static func validRect(_ r: NormalizedRect) throws -> NormalizedRect {
        guard [r.x,r.y,r.width,r.height].allSatisfy({$0.isFinite}), r.x >= 0, r.y >= 0, r.width > 0, r.height > 0, r.x+r.width <= 1.000001, r.y+r.height <= 1.000001 else { throw ConverterError.message("裁剪/遮挡区域必须在图片范围内。") }
        return r
    }
    private static func pixels(_ r: NormalizedRect, width: Int, height: Int, bottomLeft: Bool = true) -> CGRect {
        CGRect(x: r.x * Double(width), y: (bottomLeft ? 1-r.y-r.height : r.y) * Double(height), width: r.width * Double(width), height: r.height * Double(height))
    }
    private static func crop(_ image: CGImage, settings: ConversionSettings) throws -> CGImage {
        var r = settings.cropRect
        if r == nil {
            let ratio = Double(settings.width)/Double(settings.height), ir = Double(image.width)/Double(image.height)
            r = ir > ratio ? NormalizedRect(x: (1-ratio/ir)/2, y: 0, width: ratio/ir, height: 1) : NormalizedRect(x: 0, y: (1-ir/ratio)/2, width: 1, height: ir/ratio)
        }
        let rect = try validRect(r!)
        guard let cropped = image.cropping(to: pixels(rect, width: image.width, height: image.height, bottomLeft: false).integral) else { throw ConverterError.message("无法裁剪图片。") }
        return settings.exactSize ? try resize(cropped, settings.width, settings.height) : cropped
    }
    private static func edit(_ image: CGImage, settings: ConversionSettings) throws -> CGImage {
        let values = [settings.exposure,settings.brightness,settings.saturation,settings.contrast,settings.sharpness,settings.sepia,settings.vignette]
        guard values.allSatisfy({$0.isFinite}), abs(settings.exposure)<=10, abs(settings.brightness)<=1, (0...4).contains(settings.saturation), (0...4).contains(settings.contrast), (0...2).contains(settings.sharpness), (0...1).contains(settings.sepia), (0...2).contains(settings.vignette) else { throw ConverterError.message("照片调整参数超出范围。") }
        var output = CIImage(cgImage: image)
        output = output.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        output = output.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: settings.brightness, kCIInputSaturationKey: settings.saturation, kCIInputContrastKey: settings.contrast])
        if settings.sharpness > 0 { output = output.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpness]) }
        if settings.sepia > 0 { output = output.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: settings.sepia]) }
        if settings.vignette > 0 { output = output.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: settings.vignette, kCIInputRadiusKey: Double(min(image.width,image.height))/3]) }
        guard let cg = ci.createCGImage(output, from: CGRect(x:0,y:0,width:image.width,height:image.height)) else { throw ConverterError.message("照片滤镜处理失败。") }
        return settings.exactSize ? try resize(cg, settings.width, settings.height) : cg
    }
    private static func color(_ hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines); if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let n = UInt64(s, radix: 16), [6,8].contains(s.count) else { return .black }
        let alpha = s.count == 8 ? Double(n & 255)/255 : 1
        let rgb = s.count == 8 ? n >> 8 : n
        return NSColor(srgbRed:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255,alpha:alpha)
    }
    private static func annotate(_ image: CGImage, annotations: [ImageAnnotation]) throws -> CGImage {
        let ctx = try canvas(image.width, image.height); ctx.draw(image, in: CGRect(x:0,y:0,width:image.width,height:image.height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, a) in annotations.enumerated() {
            let r = try validRect(a.rect), rect = pixels(r,width:image.width,height:image.height)
            guard a.lineWidth.isFinite,a.fontSize.isFinite,a.lineWidth>0,a.lineWidth<=200,a.fontSize>0,a.fontSize<=1000 else { throw ConverterError.message("标注线宽/字号无效。") }
            let c = color(a.colorHex); ctx.setStrokeColor(c.cgColor); ctx.setFillColor(c.cgColor); ctx.setLineWidth(a.lineWidth); ctx.setLineCap(.round)
            switch a.kind {
            case "rectangle": ctx.stroke(rect)
            case "ellipse": ctx.strokeEllipse(in:rect)
            case "arrow":
                let start=CGPoint(x:rect.minX,y:rect.maxY),end=CGPoint(x:rect.maxX,y:rect.minY)
                let angle=atan2(end.y-start.y,end.x-start.x), len=max(10,a.lineWidth*4)
                ctx.move(to:start);ctx.addLine(to:end)
                ctx.move(to:CGPoint(x:end.x-len*cos(angle - .pi/6),y:end.y-len*sin(angle - .pi/6)));ctx.addLine(to:end)
                ctx.addLine(to:CGPoint(x:end.x-len*cos(angle + .pi/6),y:end.y-len*sin(angle + .pi/6)));ctx.strokePath()
            case "text", "number":
                let text=a.text.isEmpty && a.kind=="number" ? String(index+1) : a.text
                var box=rect
                if a.kind=="number" { let d=min(rect.width,rect.height);box=CGRect(x:rect.midX-d/2,y:rect.midY-d/2,width:d,height:d);ctx.fillEllipse(in:box) }
                let p=NSMutableParagraphStyle();p.alignment=a.kind=="number" ? .center : .left
                let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:a.fontSize,weight:.semibold),.foregroundColor:a.kind=="number" ? NSColor.white : c,.paragraphStyle:p]
                let content=NSAttributedString(string:text,attributes:attrs)
                if a.kind=="number" { box.origin.y=box.midY-a.fontSize*0.65;box.size.height=a.fontSize*1.4 }
                content.draw(in:box)
            default: throw ConverterError.message("未知标注类型："+a.kind)
            }
        }
        return try result(ctx)
    }
    private static func background(_ ctx: CGContext, width: Int, height: Int, settings: ConversionSettings, scratch: URL, context: OperationContext) throws {
        let rect=CGRect(x:0,y:0,width:width,height:height)
        ctx.setFillColor(color(settings.backgroundColorHex).cgColor);ctx.fill(rect)
        if !settings.gradientEndHex.isEmpty, let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color(settings.backgroundColorHex).cgColor,color(settings.gradientEndHex).cgColor] as CFArray,locations:[0,1]) {
            ctx.drawLinearGradient(gradient,start:CGPoint(x:0,y:height),end:CGPoint(x:width,y:0),options:[])
        }
        if let url=settings.backgroundImage {
            let image=try read(url,scratch:scratch,context:context).0
            drawCover(image,in:rect,context:ctx,radius:0)
        }
    }
    private static func drawCover(_ image: CGImage, in rect: CGRect, context: CGContext, radius: Double) {
        context.saveGState();context.addPath(CGPath(roundedRect:rect,cornerWidth:radius,cornerHeight:radius,transform:nil));context.clip()
        let scale=max(rect.width/Double(image.width),rect.height/Double(image.height))
        let size=CGSize(width:Double(image.width)*scale,height:Double(image.height)*scale)
        context.draw(image,in:CGRect(x:rect.midX-size.width/2,y:rect.midY-size.height/2,width:size.width,height:size.height));context.restoreGState()
    }
    private static func frame(_ image: CGImage, settings: ConversionSettings, scratch: URL, context: OperationContext) throws -> CGImage {
        guard settings.padding.isFinite,settings.cornerRadius.isFinite,settings.aspectRatio.isFinite,settings.padding>=0,settings.padding<=4000,settings.cornerRadius>=0,settings.aspectRatio>=0,settings.aspectRatio<=10 else { throw ConverterError.message("背景参数无效。") }
        let p=settings.padding
        var w=Double(image.width)+2*p,h=Double(image.height)+2*p
        if settings.aspectRatio>0 { if w/h<settings.aspectRatio {w=h*settings.aspectRatio} else {h=w/settings.aspectRatio} }
        let ctx=try canvas(Int(ceil(w)),Int(ceil(h)));try background(ctx,width:ctx.width,height:ctx.height,settings:settings,scratch:scratch,context:context)
        let rect=CGRect(x:(w-Double(image.width))/2,y:(h-Double(image.height))/2,width:Double(image.width),height:Double(image.height))
        drawCover(image,in:rect,context:ctx,radius:min(settings.cornerRadius,min(rect.width,rect.height)/2));return try result(ctx)
    }
    private static func collage(_ images: [CGImage], settings: ConversionSettings, scratch: URL, context: OperationContext) throws -> CGImage {
        guard !images.isEmpty,images.count<=100,settings.padding.isFinite,settings.padding>=0,settings.padding<=1000,settings.cornerRadius.isFinite,settings.cornerRadius>=0 else { throw ConverterError.message("拼贴参数无效。") }
        let w=settings.width,h=settings.height,p=settings.padding,n=images.count
        let ctx=try canvas(w,h);try background(ctx,width:w,height:h,settings:settings,scratch:scratch,context:context)
        var cells:[CGRect]=[]
        if settings.collageLayout=="featured", n>1 {
            let mainW=(Double(w)-3*p)*0.66,rightW=Double(w)-3*p-mainW
            let smallH=(Double(h)-Double(n)*p)/Double(n-1)
            guard mainW>0,rightW>0,smallH>0 else {throw ConverterError.message("拼贴间距过大。")}
            cells.append(CGRect(x:p,y:p,width:mainW,height:Double(h)-2*p))
            for i in 0..<(n-1) {cells.append(CGRect(x:2*p+mainW,y:Double(h)-p-Double(i+1)*smallH-Double(i)*p,width:rightW,height:smallH))}
        } else {
            let columns=settings.collageLayout=="row" ? n : (settings.collageLayout=="column" ? 1 : max(1,min(n,settings.collageColumns)))
            let rows=(n+columns-1)/columns,cw=(Double(w)-Double(columns+1)*p)/Double(columns),ch=(Double(h)-Double(rows+1)*p)/Double(rows)
            guard cw>0,ch>0 else {throw ConverterError.message("拼贴间距过大。")}
            for i in 0..<n {cells.append(CGRect(x:p+Double(i%columns)*(cw+p),y:Double(h)-p-Double(i/columns+1)*ch-Double(i/columns)*p,width:cw,height:ch))}
        }
        for (i,image) in images.enumerated() {try context.check();drawCover(image,in:cells[i],context:ctx,radius:min(settings.cornerRadius,min(cells[i].width,cells[i].height)/2))}
        return try result(ctx)
    }
    private static func redact(_ image: CGImage, settings: ConversionSettings, context: OperationContext) throws -> CGImage {
        var regions=settings.redactions
        if settings.detectFaces || settings.detectText {
            let handler=VNImageRequestHandler(cgImage:image,options:[:])
            if settings.detectFaces {
                let request=VNDetectFaceRectanglesRequest();try handler.perform([request]);try context.check()
                for o in request.results ?? [] {let r=o.boundingBox;regions.append(RedactionRegion(rect:NormalizedRect(x:r.minX,y:1-r.maxY,width:r.width,height:r.height),style:settings.redactionStyle,colorHex:settings.redactionColorHex))}
            }
            if settings.detectText {
                let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false
                try handler.perform([request]);try context.check()
                for o in request.results ?? [] {let r=o.boundingBox;regions.append(RedactionRegion(rect:NormalizedRect(x:r.minX,y:1-r.maxY,width:r.width,height:r.height),style:settings.redactionStyle,colorHex:settings.redactionColorHex))}
            }
        }
        guard !regions.isEmpty else {throw ConverterError.message("未选择遮挡区域，也未检测到匹配的人脸/文字。")}
        let ctx=try canvas(image.width,image.height);ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let blur=CIImage(cgImage:image).clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey: max(12,Double(min(image.width,image.height))/35)])
        for region in regions {
            try context.check();let r=try validRect(region.rect),rect=pixels(r,width:image.width,height:image.height)
            if region.style=="solid" {ctx.setFillColor(color(region.colorHex).cgColor);ctx.fill(rect)}
            else if region.style=="blur" {guard let part=ci.createCGImage(blur,from:rect) else {throw ConverterError.message("遮挡区域模糊失败。")};ctx.draw(part,in:rect)}
            else {throw ConverterError.message("未知遮挡样式。")}
        }
        return try result(ctx)
    }
    private static func applyMetadata(_ tags: [String:String], properties: inout [CFString:Any]) {
        var exif=properties[kCGImagePropertyExifDictionary] as? [CFString:Any] ?? [:]
        var tiff=properties[kCGImagePropertyTIFFDictionary] as? [CFString:Any] ?? [:]
        var gps=properties[kCGImagePropertyGPSDictionary] as? [CFString:Any] ?? [:]
        var iptc=properties[kCGImagePropertyIPTCDictionary] as? [CFString:Any] ?? [:]
        for (key,value) in tags {
            let k=key.lowercased().replacingOccurrences(of:"_",with:"").replacingOccurrences(of:" ",with:"")
            switch k {
            case "title","description","imagedescription":tiff[kCGImagePropertyTIFFImageDescription]=value
            case "author","artist","creator":tiff[kCGImagePropertyTIFFArtist]=value
            case "copyright":tiff[kCGImagePropertyTIFFCopyright]=value
            case "software":tiff[kCGImagePropertyTIFFSoftware]=value
            case "make":tiff[kCGImagePropertyTIFFMake]=value
            case "model":tiff[kCGImagePropertyTIFFModel]=value
            case "date","datetime","datetimeoriginal":exif[kCGImagePropertyExifDateTimeOriginal]=value
            case "comment","usercomment":exif[kCGImagePropertyExifUserComment]=value
            case "keywords":iptc[kCGImagePropertyIPTCKeywords]=value.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)}
            case "latitude","gpslatitude":if let n=Double(value),abs(n)<=90 {gps[kCGImagePropertyGPSLatitude]=abs(n);gps[kCGImagePropertyGPSLatitudeRef]=n<0 ? "S":"N"}
            case "longitude","gpslongitude":if let n=Double(value),abs(n)<=180 {gps[kCGImagePropertyGPSLongitude]=abs(n);gps[kCGImagePropertyGPSLongitudeRef]=n<0 ? "W":"E"}
            case "altitude","gpsaltitude":if let n=Double(value) {gps[kCGImagePropertyGPSAltitude]=abs(n);gps[kCGImagePropertyGPSAltitudeRef]=n<0 ? 1:0}
            default:
                let parts=key.split(separator:".",maxSplits:1).map(String.init)
                if parts.count==2 {switch parts[0].lowercased() {case "exif":exif[parts[1] as CFString]=Double(value).map{NSNumber(value:$0)} ?? value as Any;case "gps":gps[parts[1] as CFString]=Double(value) as Any;case "tiff":tiff[parts[1] as CFString]=value;case "iptc":iptc[parts[1] as CFString]=value;default:iptc[kCGImagePropertyIPTCCaptionAbstract]=value}}
                else {iptc[kCGImagePropertyIPTCCaptionAbstract]=value}
            }
        }
        if !exif.isEmpty {properties[kCGImagePropertyExifDictionary]=exif};if !tiff.isEmpty {properties[kCGImagePropertyTIFFDictionary]=tiff};if !gps.isEmpty {properties[kCGImagePropertyGPSDictionary]=gps};if !iptc.isEmpty {properties[kCGImagePropertyIPTCDictionary]=iptc}
    }
    private static func encode(_ image: CGImage, to out: URL, format: String, quality: Double, properties: [CFString:Any], context: OperationContext, tags:[String:String]=[:]) throws {
        try context.check()
        if format=="webp" {try writeWebP(image,to:out,quality:quality,properties:properties);return}
        let mapping=["png":"public.png","jpg":"public.jpeg","heic":"public.heic","tiff":"public.tiff","bmp":"com.microsoft.bmp","gif":"com.compuserve.gif","avif":"public.avif"]
        if let type=mapping[format],(CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type),let dest=CGImageDestinationCreateWithURL(out as CFURL,type as CFString,1,nil) {
            var props=properties;props[kCGImageDestinationLossyCompressionQuality]=quality;props[kCGImagePropertyOrientation]=1
            CGImageDestinationAddImage(dest,image,props as CFDictionary)
            if CGImageDestinationFinalize(dest) {return}
        }
        if format=="avif" {
            let png=out.deletingLastPathComponent().appendingPathComponent("avif-source-"+UUID().uuidString+".png")
            try encode(image,to:png,format:"png",quality:1,properties:properties,context:context);defer{try? fm.removeItem(at:png)}
            let pythonCandidates=[OperationContext.resourceURL?.appendingPathComponent("bin/python3").path,
                                  OperationContext.resourceURL?.appendingPathComponent("Python/bin/python3").path,
                                  OperationContext.executable("python3")].compactMap{$0}
            let script="from PIL import Image; import sys; im=Image.open(sys.argv[1]); im.save(sys.argv[2],format='AVIF',quality=int(sys.argv[3]),speed=8,exif=im.getexif())"
            for python in Array(NSOrderedSet(array:pythonCandidates)) as! [String] where fm.isExecutableFile(atPath:python) {
                do {try context.run(python,["-c",script,png.path,out.path,String(Int(quality*100))]);return}
                catch ConverterError.cancelled {throw ConverterError.cancelled}
                catch {try context.check()}
            }
            guard let ff=OperationContext.executable("ffmpeg") else {throw ConverterError.message("AVIF 输出需要离线 Pillow 或 FFmpeg AV1 编码器。")}
            let encoders=try context.run(ff,["-hide_banner","-encoders"])
            let encoder=encoders.contains("libsvtav1") ? "libsvtav1" : (encoders.contains("libaom-av1") ? "libaom-av1" : "")
            guard !encoder.isEmpty else {throw ConverterError.message("FFmpeg 没有可用的 AVIF 编码器。")}
            // Most AV1 encoders cannot encode alpha. Never silently discard transparency.
            if hasTransparency(image) {throw ConverterError.message("当前 AVIF 编码器不支持透明通道；请使用 PNG、WebP 或 HEIC 保留透明度。")}
            var args=["-nostdin","-v","error","-y","-i",png.path,"-frames:v","1","-c:v",encoder,"-crf",String(Int((1-quality)*55)),"-pix_fmt","yuv420p"]
            if encoder=="libsvtav1" {args += ["-preset","8"]} else {args += ["-cpu-used","6"]}
            for key in tags.keys.sorted() {args += ["-metadata",key+"="+(tags[key] ?? "")]}
            args += [out.path];try context.run(ff,args);return
        }
        throw ConverterError.message("此 Mac 无法编码 "+format.uppercased()+" 图片。")
    }
    private static func hasTransparency(_ image:CGImage) -> Bool {
        guard [.first,.last,.premultipliedFirst,.premultipliedLast,.alphaOnly].contains(image.alphaInfo) else {return false}
        // Detect actual transparency, rather than rejecting an opaque image in an RGBA buffer.
        let w=image.width,h=image.height,stride=w*4
        guard let data=calloc(h,stride) else {return true};defer{free(data)}
        guard let c=CGContext(data:data,width:w,height:h,bitsPerComponent:8,bytesPerRow:stride,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {return true}
        c.draw(image,in:CGRect(x:0,y:0,width:w,height:h));let p=data.assumingMemoryBound(to:UInt8.self)
        for i in Swift.stride(from:3,to:h*stride,by:4) where p[i]<255 {return true};return false
    }
    private static func writeWebP(_ image: CGImage, to out: URL, quality: Double, properties: [CFString:Any]) throws {
        typealias Encoder = @convention(c)(UnsafePointer<UInt8>?,Int32,Int32,Int32,Float,UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?)->Int
        typealias Releaser = @convention(c)(UnsafeMutableRawPointer?)->Void
        guard let lib=webpLibrary,let symbol=dlsym(lib,"WebPEncodeRGBA"),let freeSymbol=dlsym(lib,"WebPFree") else {throw ConverterError.message("WebP 编码器不可用；请修复应用内 libwebp。")}
        let encoder=unsafeBitCast(symbol,to:Encoder.self),release=unsafeBitCast(freeSymbol,to:Releaser.self)
        let width=image.width,height=image.height,stride=width*4
        guard let data=calloc(height,stride) else {throw ConverterError.message("WebP 编码内存不足。")};defer{free(data)}
        guard let c=CGContext(data:data,width:width,height:height,bitsPerComponent:8,bytesPerRow:stride,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw ConverterError.message("WebP 像素缓冲失败。")}
        c.draw(image,in:CGRect(x:0,y:0,width:width,height:height));let p=data.assumingMemoryBound(to:UInt8.self)
        for i in Swift.stride(from:0,to:height*stride,by:4) {let a=Int(p[i+3]);if a>0 && a<255 {for channel in 0..<3 {p[i+channel]=UInt8(min(255,(Int(p[i+channel])*255+a/2)/a))}}}
        var encoded:UnsafeMutablePointer<UInt8>?
        let size=encoder(p,Int32(width),Int32(height),Int32(stride),Float(quality*100),&encoded)
        guard let bytes=encoded,size>0 else {throw ConverterError.message("WebP 编码失败。")};defer{release(bytes)}
        var output=Data(bytes:bytes,count:size)
        // A standard XMP RIFF chunk retains editable metadata without relying on FFmpeg's absent WebP encoder.
        if !properties.isEmpty {
            let metadata=CGImageMetadataCreateMutable()
            for (dictKey,ns,prefix) in [(kCGImagePropertyTIFFDictionary,"http://ns.adobe.com/tiff/1.0/","tiff"),(kCGImagePropertyExifDictionary,"http://ns.adobe.com/exif/1.0/","exif"),(kCGImagePropertyGPSDictionary,"http://ns.adobe.com/exif/1.0/","exif")] {
                CGImageMetadataRegisterNamespaceForPrefix(metadata,ns as CFString,prefix as CFString,nil)
                if let dict=properties[dictKey] as? [CFString:Any] {for (key,value) in dict {CGImageMetadataSetValueWithPath(metadata,nil,(prefix+":"+(key as String)) as CFString,value as CFTypeRef)}}
            }
            if let xmp=CGImageMetadataCreateXMPData(metadata,nil) as Data? {
                // Extended WebP headers are required when adding metadata to a simple VP8 stream.
                if output.count>=20, String(data:output.subdata(in:12..<16),encoding:.ascii) != "VP8X" {
                    var vp8x=Data([UInt8(0x04 | (hasTransparency(image) ? 0x10 : 0)),0,0,0])
                    for n in [width-1,height-1] {vp8x.append(contentsOf:[UInt8(n&255),UInt8((n>>8)&255),UInt8((n>>16)&255)])}
                    var chunk=Data("VP8X".utf8);var len=UInt32(10).littleEndian;withUnsafeBytes(of:&len){chunk.append(contentsOf:$0)};chunk.append(vp8x);output.insert(contentsOf:chunk,at:12)
                } else if output.count>20 {output[20] |= 0x04}
                output.append(contentsOf:Array("XMP ".utf8));var len=UInt32(xmp.count).littleEndian;withUnsafeBytes(of:&len){output.append(contentsOf:$0)};output.append(xmp);if xmp.count%2==1 {output.append(0)}
                var riff=UInt32(output.count-8).littleEndian;withUnsafeBytes(of:&riff){output.replaceSubrange(4..<8,with:$0)}
            }
        }
        try output.write(to:out)
    }
    private static func compress(_ source: CGImage, original: URL, to out: URL, format: String, settings: ConversionSettings, properties: [CFString:Any], context: OperationContext, progress:@escaping(Double,String)->Void) throws {
        var target:Int64=0
        if settings.compressionMode=="target" {guard settings.targetBytes>0 else {throw ConverterError.message("请输入大于零的目标大小。")};target=settings.targetBytes}
        else if settings.compressionMode=="percent" {
            guard settings.reductionPercent.isFinite,(0..<100).contains(settings.reductionPercent) else {throw ConverterError.message("减小百分比必须在 0 到 100 之间。")}
            let bytes=(try original.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0;target=Int64(Double(bytes)*(1-settings.reductionPercent/100))
        }
        if target==0 {try encode(source,to:out,format:format,quality:settings.quality,properties:properties,context:context);return}
        var image=source
        for attempt in 0..<24 {
            try context.check()
            let quality=max(0.03,settings.quality-Double(attempt%6)*0.15)
            try encode(image,to:out,format:format,quality:quality,properties:properties,context:context)
            let bytes=(try fm.attributesOfItem(atPath:out.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
            progress(min(0.95,Double(attempt+1)/24),"压缩到目标大小")
            if bytes<=target {return}
            if attempt%6==5 || ["png","bmp","tiff"].contains(format) {
                let scale=max(0.1,min(0.82,sqrt(Double(target)/Double(bytes))*0.9))
                let w=max(1,Int(Double(image.width)*scale)),h=max(1,Int(Double(image.height)*scale))
                if w==image.width && h==image.height {break};image=try resize(image,w,h)
            }
        }
        throw ConverterError.message("无法达到目标大小；请增加大小上限或选择其他格式。没有输出不满足上限的文件。")
    }
    private static func writePDF(_ document: PDFDocument, out: URL, options: [PDFDocumentWriteOption:Any]?=nil) throws {
        guard document.pageCount>0,document.write(to:out,withOptions:options),let check=PDFDocument(url:out),check.pageCount==document.pageCount else {throw ConverterError.message("PDF 写出或验证失败。")}
    }
    private static func quartzCompress(_ document:PDFDocument,to out:URL,quality:Double,context:OperationContext) throws {
        let props:[String:Any]=["FilterType":1,"Name":"LocalShift Image Compression","Domains":["Applications":true],"FilterData":["ColorSettings":["ImageSettings":["Compression Quality":quality,"ImageCompression":"ImageJPEGCompress","ImageScaleSettings":["ImageResolution":144,"ImageScaleInterpolate":true,"ImageSizeMax":2400,"ImageSizeMin":0]]]]]
        guard let filter=QuartzFilter(properties:props),let consumer=CGDataConsumer(url:out as CFURL),let cg=CGContext(consumer:consumer,mediaBox:nil,nil),filter.apply(to:cg) else {throw ConverterError.message("系统 PDF 图像压缩过滤器不可用。")}
        for index in 0..<document.pageCount {
            try context.check();guard let page=document.page(at:index) else {throw ConverterError.message("PDF 页面读取失败。")}
            var rect=page.bounds(for:.mediaBox)
            let box=Data(bytes:&rect,count:MemoryLayout<CGRect>.size)
            cg.beginPDFPage([kCGPDFContextMediaBox as String:box] as CFDictionary)
            page.draw(with:.mediaBox,to:cg);cg.endPDFPage()
        }
        filter.remove(from:cg);cg.closePDF()
        guard let check=PDFDocument(url:out),check.pageCount==document.pageCount else {throw ConverterError.message("系统 PDF 压缩输出无效。")}
    }
    private static func pdf(_ files: [URL], option: String, settings: ConversionSettings, scratch: URL, context: OperationContext, progress:@escaping(Double,String)->Void) throws -> [URL] {
        guard let file=files.first,let source=PDFDocument(url:file),!source.isLocked,source.pageCount>0 else {throw ConverterError.message("无法打开 PDF，或文件已加密。")}
        let out=target(file,suffix:"-"+option,ext:"pdf",scratch:scratch)
        switch option {
        case "mergePDF":
            let document=PDFDocument()
            for (i,url) in files.enumerated() {
                try context.check();guard let input=PDFDocument(url:url),!input.isLocked else {throw ConverterError.message("无法打开 PDF："+url.lastPathComponent)}
                for p in 0..<input.pageCount {try context.check();guard let page=input.page(at:p)?.copy() as? PDFPage else {throw ConverterError.message("PDF 页面读取失败。")};document.insert(page,at:document.pageCount)}
                progress(Double(i+1)/Double(files.count),"合并 PDF")
            }
            try writePDF(document,out:out);return [out]
        case "splitPDF":
            var outputs:[URL]=[]
            let order=settings.pageOrder.isEmpty ? Array(0..<source.pageCount) : settings.pageOrder
            guard order.count<=10000,order.allSatisfy({$0>=0 && $0<source.pageCount}) else {throw ConverterError.message("PDF 拆页顺序无效。")}
            for (index,p) in order.enumerated() {
                try context.check();guard let page=source.page(at:p)?.copy() as? PDFPage else {throw ConverterError.message("PDF 页面读取失败。")}
                let rotation=settings.pageRotations[index] ?? page.rotation
                guard rotation%90==0 else {throw ConverterError.message("PDF 旋转角度必须是 90 的整数倍。")}
                page.rotation=((rotation%360)+360)%360
                let doc=PDFDocument();doc.insert(page,at:0)
                let url=target(file,suffix:String(format:"-page-%04d",index+1),ext:"pdf",scratch:scratch)
                try writePDF(doc,out:url);outputs.append(url);progress(Double(index+1)/Double(order.count),"拆分 PDF")
            };return outputs
        case "organizePDF":
            let order=settings.pageOrder.isEmpty ? Array(0..<source.pageCount) : settings.pageOrder
            guard !order.isEmpty,order.count<=10000,order.allSatisfy({$0>=0 && $0<source.pageCount}) else {throw ConverterError.message("PDF 页面顺序无效。")}
            let doc=PDFDocument();doc.documentAttributes=source.documentAttributes
            for (index,p) in order.enumerated() {try context.check();guard let page=source.page(at:p)?.copy() as? PDFPage else {throw ConverterError.message("无法复制页面。")};let rotation=settings.pageRotations[index] ?? page.rotation;guard rotation%90==0 else {throw ConverterError.message("PDF 旋转角度必须是 90 的整数倍。")};page.rotation=((rotation%360)+360)%360;doc.insert(page,at:index)}
            try writePDF(doc,out:out);return [out]
        case "removeMetadata":
            var attrs=settings.removeMetadata ? [:] : (source.documentAttributes ?? [:])
            let keys:[String:PDFDocumentAttribute]=["title":.titleAttribute,"author":.authorAttribute,"creator":.creatorAttribute,"producer":.producerAttribute,"subject":.subjectAttribute,"keywords":.keywordsAttribute,"creationdate":.creationDateAttribute,"modificationdate":.modificationDateAttribute]
            for (key,value) in settings.metadata {
                let attr=keys[key.lowercased()] ?? PDFDocumentAttribute(rawValue:key)
                if key.lowercased().contains("date") {let formatter=ISO8601DateFormatter();guard let date=formatter.date(from:value) else {throw ConverterError.message("PDF 日期元数据需 ISO 8601 格式。")};attrs[attr]=date}
                else if key.lowercased()=="keywords" {attrs[attr]=value.split(separator:",").map(String.init)} else {attrs[attr]=value}
            }
            source.documentAttributes=attrs;try writePDF(source,out:out);return [out]
        case "compress":
            if settings.compressionMode=="target",settings.targetBytes<=0 {throw ConverterError.message("请输入有效的 PDF 目标字节数。")}
            if settings.compressionMode=="percent",(!settings.reductionPercent.isFinite || !(0..<100).contains(settings.reductionPercent)) {throw ConverterError.message("PDF 压缩百分比无效。")}
            // PDFKit recompresses embedded images without rasterizing vector/text pages.
            if #available(macOS 13.4, *) {
                try context.check()
                try writePDF(source,out:out,options:[.saveImagesAsJPEGOption:true,.optimizeImagesForScreenOption:true])
                var limit=settings.targetBytes
                if settings.compressionMode=="percent" {guard (0..<100).contains(settings.reductionPercent) else {throw ConverterError.message("压缩百分比无效。")};limit=Int64(Double((try file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)*(1-settings.reductionPercent/100))}
                if settings.compressionMode != "quality",limit>0,Int64((try out.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>limit {throw ConverterError.message("保留文字的 PDF 压缩未达到目标大小；请提高上限。未使用整页栅格化。")}
                progress(1,"PDF 图像已重编码，文字与矢量保留");return [out]
            }
            // macOS 13.0–13.3: Quartz's system image filter also preserves page text/vector drawing.
            try quartzCompress(source,to:out,quality:settings.quality,context:context)
            let limit=settings.compressionMode=="target" ? settings.targetBytes : (settings.compressionMode=="percent" ? Int64(Double((try file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)*(1-settings.reductionPercent/100)) : 0)
            if limit>0,Int64((try out.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>limit {throw ConverterError.message("PDF 图像压缩未达到目标大小，请提高上限。未使用整页栅格化。")}
            return [out]
        default:throw ConverterError.message("不支持的 PDF 操作："+option)
        }
    }
}
