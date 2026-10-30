import Cocoa
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers

private final class LSOfficeRasterScan {
    let depth: Int
    var found = false
    init(depth: Int) { self.depth=depth }
}

/// Offline Office, ebook and archive conversions. Only temporary copies are passed to external applications.
enum OfficeEngine {
    private static let fm = FileManager.default
    private static let archiveTypes: Set<String> = ["zip","tar","gz","gzip","tgz","rar"]
    private static let imageTypes: Set<String> = ["png","jpg","jpeg","webp","heic","tiff","bmp","avif"]
    private static func resource(_ name: String) -> URL? {
        let roots = [OperationContext.resourceURL, URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"), URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources")].compactMap { $0 }
        return roots.map { $0.appendingPathComponent(name) }.first { fm.fileExists(atPath: $0.path) }
    }
    private static func python() throws -> String {
        let paths = [resource("bin/python3")?.path, resource("Python/bin/python3")?.path, OperationContext.executable("python3")].compactMap { $0 }
        guard let p = paths.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw ConverterError.message("缺少随应用附带的离线 Python 运行时。") }
        return p
    }
    @discardableResult private static func helper(_ args: [String], context: OperationContext) throws -> String {
        guard let script = resource("office-helper.py") else { throw ConverterError.message("缺少 Office 辅助程序。") }
        return try context.run(try python(), [script.path] + args)
    }
    private static func directory(_ parent: URL, _ name: String) throws -> URL {
        let u = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static func checked(_ url: URL) throws -> URL {
        guard fm.fileExists(atPath: url.path) else { throw ConverterError.message("转换器未生成预期文件：" + url.lastPathComponent) }
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true {
            guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 else { throw ConverterError.message("转换结果为空。") }
        }
        return url
    }
    static func convert(_ files: [URL], option: String, settings: ConversionSettings, scratch: URL, context: OperationContext, progress: @escaping (Double, String) -> Void) throws -> [URL] {
        guard let source = files.first else { throw ConverterError.message("请先添加文件。") }
        try context.check()
        let ext = source.pathExtension.lowercased(), target = option.hasPrefix("format_") ? String(option.dropFirst(7)) : ""
        let stem = source.deletingPathExtension().lastPathComponent
        let result = scratch.appendingPathComponent(stem + "-converted." + target)
        let inputIsFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !["pages","rtfd"].contains(ext)
        progress(0.05, "准备本地转换")
        if option == "extractArchive" || archiveTypes.contains(ext) || inputIsFolder {
            guard option == "extractArchive" || ["zip","tar","gz"].contains(target) else { throw ConverterError.message("不支持的归档目标格式。") }
            if option == "extractArchive" {
                let output = scratch.appendingPathComponent(stem + "-extracted", isDirectory: true)
                try helper(["extract",source.path,output.path],context:context)
                progress(1,"已安全解压");return [try checked(output)]
            }
            let unpack = scratch.appendingPathComponent("archive-work",isDirectory:true)
            try helper(["archive",source.path,result.path,target,unpack.path],context:context)
            progress(1,"已生成归档");return [try checked(result)]
        }
        guard !target.isEmpty else { throw ConverterError.message("Office 引擎不支持这个操作。") }
        if ext == "svg" {
            let safe = scratch.appendingPathComponent("sanitized.svg")
            let details = try helper(["svg",source.path,safe.path],context:context)
            guard let data=details.data(using:.utf8),let size=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let width=size["width"] as? Double,let height=size["height"] as? Double,
                  let pixelsWide=size["pixelWidth"] as? Int,let pixelsHigh=size["pixelHeight"] as? Int,
                  width.isFinite,height.isFinite,width>0,height>0,pixelsWide>0,pixelsHigh>0,
                  pixelsWide<=16384,pixelsHigh<=16384,Int64(pixelsWide)*Int64(pixelsHigh)<=100_000_000 else { throw ConverterError.message("无法确定安全的 SVG 画布尺寸。") }
            let imported = try libreoffice(safe,target:"pdf",scratch:scratch,context:context)
            let pdf = scratch.appendingPathComponent("svg-canvas.pdf")
            try normalizeSVGCanvas(imported,to:pdf,size:CGSize(width:width*0.75,height:height*0.75),context:context)
            if target == "pdf" { try fm.copyItem(at:pdf,to:result);return [try checked(result)] }
            guard imageTypes.contains(target) else { throw ConverterError.message("不支持的 SVG 输出格式。") }
            return try render(pdf:pdf,target:target,stem:stem,settings:settings,scratch:scratch,context:context,pixelSize:(pixelsWide,pixelsHigh),dpi:96)
        }
        if ext == "pdf" {
            if imageTypes.contains(target) { return try render(pdf:source,target:target,stem:stem,settings:settings,scratch:scratch,context:context,dpi:["png","jpg","jpeg"].contains(target) ? 300 : 144) }
            let model = scratch.appendingPathComponent("pdf-content.json")
            try pdfModel(source,to:model,context:context)
            progress(0.45,"已提取 PDF 文字与页面位置")
            if target == "pages" {
                let docx = scratch.appendingPathComponent("reconstructed.docx")
                try helper(["convert",model.path,docx.path,"docx"],context:context)
                try pages(docx,to:result,format:"pages",scratch:scratch,context:context)
            } else {
                guard ["docx","pptx","xlsx","epub","txt","md","html"].contains(target) else { throw ConverterError.message("不支持的 PDF 输出格式。") }
                try helper(["convert",model.path,result.path,target],context:context)
            }
            progress(1,"已生成可编辑内容");return [try checked(result)]
        }
        let work = try directory(scratch,"document-work")
        var input = source
        // Pages and RTFD are packages on some macOS releases. Reject links before copying the package.
        if ["pages","rtfd"].contains(ext) { try validatePackage(source) }
        if ext == "pages" {
            let exported = work.appendingPathComponent("pages-export.docx")
            if target == "pdf" || target == "docx" || target == "epub" || target == "txt" {
                try pages(source,to:result,format:target,scratch:work,context:context)
                progress(1,"已从 Pages 导出");return [try checked(result)]
            }
            try pages(source,to:exported,format:"docx",scratch:work,context:context);input=exported
        } else if ext == "epub" {
            // Parse ZIP/OPF/spine ourselves; never let a web renderer load ebook links.
            let normalized = work.appendingPathComponent("ebook.docx")
            if ["txt","md","html","docx"].contains(target) {
                try helper(["convert",source.path,result.path,target],context:context);return [try checked(result)]
            }
            try helper(["convert",source.path,normalized.path,"docx"],context:context);input=normalized
        } else if ["txt","md","textclipping","csv","tsv","html","htm"].contains(ext) {
            let normalized = work.appendingPathComponent(["csv","tsv"].contains(ext) ? "table.xlsx" : "document.docx")
            if ["txt","md","html","docx","epub","xlsx","ods","csv","tsv"].contains(target) {
                try helper(["convert",source.path,result.path,target],context:context);return [try checked(result)]
            }
            try helper(["convert",source.path,normalized.path,normalized.pathExtension],context:context);input=normalized
        } else if ext == "rtfd" {
            let normalized = work.appendingPathComponent("richtext.docx")
            _ = try context.run("/usr/bin/textutil",["-convert","docx","-output",normalized.path,source.path])
            input=try checked(normalized)
        }
        try context.check()
        if target == "pages" {
            var importFile=input
            if input.pathExtension.lowercased() != "docx" { importFile = try libreoffice(input,target:"docx",scratch:work,context:context) }
            try pages(importFile,to:result,format:"pages",scratch:work,context:context)
            progress(1,"已保存 Pages 文稿");return [try checked(result)]
        }
        if target == "epub" || target == "md" || target == "txt" {
            var doc=input
            if input.pathExtension.lowercased() != "docx" { doc=try libreoffice(input,target:"docx",scratch:work,context:context) }
            try helper(["convert",doc.path,result.path,target],context:context)
            progress(1,"已生成电子文档");return [try checked(result)]
        }
        if imageTypes.contains(target) {
            let pdf = try libreoffice(input,target:"pdf",scratch:work,context:context)
            return try render(pdf:pdf,target:target,stem:stem,settings:settings,scratch:scratch,context:context)
        }
        if ["csv","tsv"].contains(target),["xlsx","xls","ods"].contains(input.pathExtension.lowercased()) {
            return try spreadsheetText(input,target:target,stem:stem,scratch:scratch,context:context)
        }
        if target == "tsv" {
            let csv = try libreoffice(input,target:"csv",scratch:work,context:context)
            try helper(["convert",csv.path,result.path,"tsv"],context:context);return [try checked(result)]
        }
        let output = try libreoffice(input,target:target,scratch:work,context:context)
        // HTML exports may include images. Publish one containing folder so relative assets remain usable.
        if target == "html" {
            let siblings=try fm.contentsOfDirectory(at:output.deletingLastPathComponent(),includingPropertiesForKeys:nil)
            if siblings.count>1 {
                let folder=try directory(scratch,stem+"-html")
                for f in siblings { try fm.copyItem(at:f,to:folder.appendingPathComponent(f.lastPathComponent)) }
                return [folder]
            }
        }
        try fm.copyItem(at:output,to:result)
        progress(1,"已完成 Office 转换");return [try checked(result)]
    }
    private static func validatePackage(_ url: URL) throws {
        let values=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
        guard values.isSymbolicLink != true else { throw ConverterError.message("文稿包不能是符号链接。") }
        if values.isDirectory == true, let en=fm.enumerator(at:url,includingPropertiesForKeys:[.isSymbolicLinkKey]) {
            var count=0
            for case let child as URL in en {
                count+=1
                let childValues=try child.resourceValues(forKeys:[.isSymbolicLinkKey])
                if count>20000 || childValues.isSymbolicLink==true { throw ConverterError.message("文稿包含链接或过多文件。") }
            }
        }
    }
    private static func libreoffice(_ input: URL, target: String, scratch: URL, context: OperationContext, allSheets: Bool = false) throws -> URL {
        let overrides=ProcessInfo.processInfo.environment["LOCALSHIFT_SOFFICE"]
        let paths=[resource("OfficeRuntime/LibreOffice.app/Contents/MacOS/soffice")?.path,resource("OfficeRuntime/LibreOfficeDev.app/Contents/MacOS/soffice")?.path,overrides,OperationContext.executable("soffice")].compactMap{$0}+OperationContext.systemCandidates(["/Applications/LibreOffice.app/Contents/MacOS/soffice"])
        guard let exe=paths.first(where:{fm.isExecutableFile(atPath:$0)}) else { throw ConverterError.message("缺少随应用附带的离线 LibreOffice 运行时。") }
        let job=try directory(scratch,"lo-"+UUID().uuidString)
        let sourceDir=try directory(job,"input"),outDir=try directory(job,"output")
        let copy=sourceDir.appendingPathComponent(input.lastPathComponent)
        try fm.copyItem(at:input,to:copy)
        if ["docx","pptx","xlsx","ods","odt"].contains(copy.pathExtension.lowercased()) { try helper(["checkzip",copy.path],context:context) }
        let filter: String
        switch target {
        case "docx":filter="docx:Office Open XML Text"
        case "xlsx":filter="xlsx:Calc Office Open XML"
        case "csv":filter="csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,"+(allSheets ? "-1" : "0")
        case "txt":throw ConverterError.message("文本导出使用离线解析器。")
        case "pdf","ods","html","pptx","rtf","odt":filter=target
        default:throw ConverterError.message("LibreOffice 不支持此目标格式："+target)
        }
        let profile=job.appendingPathComponent("profile",isDirectory:true).absoluteString
        guard let script=resource("office-helper.py") else { throw ConverterError.message("缺少 Office 辅助程序。") }
        let log=try context.run(try python(),[script.path,"office",exe,"-env:UserInstallation="+profile,"--headless","--nologo","--nodefault","--norestore","--nolockcheck","--convert-to",filter,"--outdir",outDir.path,copy.path],timeout:180)
        if allSheets { return outDir }
        let expected=outDir.appendingPathComponent(copy.deletingPathExtension().lastPathComponent).appendingPathExtension(target)
        guard fm.fileExists(atPath:expected.path) else { throw ConverterError.message("Office 转换没有生成结果。"+String(log.suffix(1000))) }
        return try checked(expected)
    }
    private static func spreadsheetText(_ input: URL, target: String, stem: String, scratch: URL, context: OperationContext) throws -> [URL] {
        let owned=try directory(scratch,"sheets-"+UUID().uuidString)
        let workbook = input.pathExtension.lowercased()=="xlsx" ? input : try libreoffice(input,target:"xlsx",scratch:owned,context:context)
        let info=try helper(["sheets",workbook.path],context:context)
        guard let data=info.data(using:.utf8),let sheets=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],!sheets.isEmpty else { throw ConverterError.message("无法读取完整工作表顺序。") }
        let folder=try libreoffice(workbook,target:"csv",scratch:owned,context:context,allSheets:true)
        let entries=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard entries.count==sheets.count else { throw ConverterError.message("CSV 导出工作表数量不匹配，未发布不完整结果。") }
        var outputs:[URL]=[]
        var shortStem=stem
        while shortStem.utf8.count>100 { shortStem.removeLast() }
        for (index,sheet) in sheets.enumerated() {
            try context.check()
            guard let name=sheet["name"] as? String,let label=sheet["label"] as? String,
                  !name.contains("/"),!name.contains("\\"),!label.contains("/"),!label.contains("\\") else { throw ConverterError.message("工作表文件名无效。") }
            let source=folder.appendingPathComponent(workbook.deletingPathExtension().lastPathComponent+"-"+name+".csv")
            let values=try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true,
                  source.resolvingSymlinksInPath().deletingLastPathComponent()==folder.resolvingSymlinksInPath() else { throw ConverterError.message("CSV 工作表输出不安全或不完整。") }
            let suffix=sheets.count==1 ? "-converted" : String(format:"-sheet-%04d-",index+1)+label
            let output=scratch.appendingPathComponent((sheets.count==1 ? stem : shortStem)+suffix+"."+target)
            if target=="tsv" { try helper(["convert",source.path,output.path,"tsv"],context:context) }
            else { try fm.copyItem(at:source,to:output) }
            outputs.append(try checked(output))
        }
        return outputs
    }
    private static func pagesStageIsComplete(_ stage: URL, format: String, context: OperationContext) throws -> Bool {
        guard fm.fileExists(atPath:stage.path) else { return false }
        let values=try stage.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey,.fileSizeKey])
        guard values.isSymbolicLink != true else { return false }
        if values.isDirectory==true {
            guard format=="pages" else { return false }
            try validatePackage(stage)
            let document=stage.appendingPathComponent("Index/Document.iwa")
            return ((try? document.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0
        }
        guard (values.fileSize ?? 0)>0 else { return false }
        if format=="pdf" { return PDFDocument(url:stage).map{!$0.isLocked && $0.pageCount>0} ?? false }
        if format=="txt" {
            let bytes=try Data(contentsOf:stage)
            return String(data:bytes,encoding:.utf8) != nil || String(data:bytes,encoding:.utf16) != nil
        }
        guard ["pages","docx","epub"].contains(format) else { return false }
        do {
            // A valid central directory alone does not prove a completed save.
            // Test every exported ZIP member's CRC without extracting any files.
            try context.run("/usr/bin/unzip",["-tqq",stage.path],timeout:20)
            let entries=Set(try context.run("/usr/bin/unzip",["-Z1",stage.path],timeout:10).split(separator:"\n").map(String.init))
            let required=format=="pages" ? "Index/Document.iwa" : format=="docx" ? "word/document.xml" : "META-INF/container.xml"
            return entries.contains(required)
        } catch {
            try context.check()
            return false
        }
    }
    private static func pages(_ input: URL, to output: URL, format: String, scratch: URL, context: OperationContext) throws {
        guard fm.fileExists(atPath:"/Applications/Pages.app"),let script=resource("OfficePages.applescript") else { throw ConverterError.message("Pages 转换需要安装 Apple Pages 和随附自动化脚本。") }
        let owned=try directory(scratch,"pages-"+UUID().uuidString)
        let uniqueName="LocalShift-"+UUID().uuidString
        let copy=owned.appendingPathComponent(uniqueName).appendingPathExtension(input.pathExtension)
        let stage=(try directory(owned,"export")).appendingPathComponent(uniqueName).appendingPathExtension(format)
        try fm.copyItem(at:input,to:copy)
        func disconnected(_ error: Error) -> Bool {
            error.localizedDescription.range(of:#"\(-609\)\s*$"#,options:.regularExpression) != nil
        }
        var cleanupNeeded=false
        func cleanup() {
            guard cleanupNeeded else { return }
            cleanupNeeded=false
            // Cleanup must survive cancellation of the conversion's context.
            let cleanupContext=OperationContext()
            // New osascript processes reconnect independently. They may close
            // only this UUID prefix, never unrelated documents or the app.
            for attempt in 0..<2 {
                do { _=try cleanupContext.run("/usr/bin/osascript",[script.path,copy.path,stage.path,format,uniqueName,"cleanup"],timeout:8);return }
                catch { if attempt==1 || !disconnected(error) { return } }
            }
        }
        defer { cleanup() }
        var complete=false,lastError:Error?
        for attempt in 0..<2 {
            try context.check()
            do {
                // LaunchServices grants Pages access to the owned input copy.
                cleanupNeeded=true
                _=try context.run("/usr/bin/open",["-g","-a","Pages",copy.path],timeout:20)
                _=try context.run("/usr/bin/osascript",[script.path,copy.path,stage.path,format,uniqueName,"convert"],timeout:100)
                guard try pagesStageIsComplete(stage,format:format,context:context) else { throw ConverterError.message("Pages 没有生成完整文件。") }
                complete=true;break
            } catch {
                try context.check();lastError=error
                guard disconnected(error) else { break }
                // A disconnected AppleEvent is an uncertain reply. Read the
                // private result before retrying; never export a completed file twice.
                if try pagesStageIsComplete(stage,format:format,context:context) { complete=true;break }
                guard attempt==0 else { break }
                cleanup();try context.check()
                Thread.sleep(forTimeInterval:0.25)
                if try pagesStageIsComplete(stage,format:format,context:context) { complete=true;break }
                if fm.fileExists(atPath:stage.path) { try fm.removeItem(at:stage) }
            }
        }
        cleanup();try context.check()
        guard complete else {
            throw ConverterError.message("Pages 自动化失败；仅处理临时副本，未生成完整文件。请检查 Pages 首次启动提示或系统设置→隐私与安全性→自动化。\n"+(lastError?.localizedDescription ?? "缺少完整导出文件。"))
        }
        guard !fm.fileExists(atPath:output.path) else { throw ConverterError.message("Pages 输出位置已存在文件，未覆盖。") }
        // The document name stays UUID-owned even after Save. Publish once only
        // after success/readback validation, separately from close/reconnect errors.
        try fm.moveItem(at:stage,to:output)
        _=try checked(output)
    }
    private static func normalizeSVGCanvas(_ input: URL, to output: URL, size: CGSize, context: OperationContext) throws {
        try context.check()
        guard let document=CGPDFDocument(input as CFURL),document.numberOfPages==1,let page=document.page(at:1) else { throw ConverterError.message("SVG 未生成单页矢量画布。") }
        let source=page.getBoxRect(.mediaBox)
        guard source.width.isFinite,source.height.isFinite,source.width>0,source.height>0 else { throw ConverterError.message("SVG 中间 PDF 画布无效。") }
        var media=CGRect(origin:.zero,size:size)
        guard let consumer=CGDataConsumer(url:output as CFURL),let cg=CGContext(consumer:consumer,mediaBox:&media,nil) else { throw ConverterError.message("无法创建 SVG 矢量 PDF。") }
        cg.beginPDFPage(nil)
        // Redraw PDF operators into the exact CSS-pixel canvas. This retains
        // vectors while removing LibreOffice's hundredth-mm page quantization.
        cg.scaleBy(x:size.width/source.width,y:size.height/source.height)
        cg.translateBy(x:-source.minX,y:-source.minY);cg.drawPDFPage(page)
        cg.endPDFPage();cg.closePDF()
        try context.check();_=try checked(output)
    }
    private static func render(pdf: URL, target: String, stem: String, settings: ConversionSettings, scratch: URL, context: OperationContext, pixelSize: (Int,Int)? = nil, dpi: Double = 144) throws -> [URL] {
        guard let doc=PDFDocument(url:pdf),doc.pageCount>0,!doc.isLocked else { throw ConverterError.message("无法读取 PDF 页面。") }
        guard doc.pageCount<=10000 else { throw ConverterError.message("PDF 超过 10000 页安全上限。") }
        var outputs:[URL]=[]
        for i in 0..<doc.pageCount {
            try context.check()
            guard let page=doc.page(at:i),let reference=page.pageRef else { throw ConverterError.message("无法读取 PDF 页面绘图数据。") }
            let box=reference.getBoxRect(.mediaBox),rotation=((Int(reference.rotationAngle)%360)+360)%360
            let rect=CGRect(origin:.zero,size:rotation==90 || rotation==270 ? CGSize(width:box.height,height:box.width) : box.size),scale=CGFloat(dpi/72)
            guard rect.width>0,rect.height>0,rect.width.isFinite,rect.height.isFinite,
                  pixelSize != nil || (rect.width*scale<=16384 && rect.height*scale<=16384) else { throw ConverterError.message("页面尺寸无效或超过安全渲染上限。") }
            let width=pixelSize?.0 ?? Int(ceil(rect.width*scale-1e-8)),height=pixelSize?.1 ?? Int(ceil(rect.height*scale-1e-8))
            guard width>0,height>0,width<=16384,height<=16384,Int64(width)*Int64(height)<=100_000_000 else { throw ConverterError.message("页面尺寸超过 16384 或单页像素超过一亿安全上限。") }
            guard let cg=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConverterError.message("无法分配页面图像。") }
            let canvas=CGRect(x:0,y:0,width:width,height:height)
            cg.setFillColor(NSColor.white.cgColor);cg.fill(canvas)
            // CoreGraphics incorporates the page's intrinsic rotation and
            // nonzero mediaBox origin. The canvas follows its displayed size.
            // getDrawingTransform does not enlarge a smaller page on every
            // supported CoreGraphics runtime. Apply the DPI scale explicitly,
            // then obtain only rotation/origin mapping in physical point space.
            cg.scaleBy(x:CGFloat(width)/rect.width,y:CGFloat(height)/rect.height)
            cg.concatenate(reference.getDrawingTransform(.mediaBox,rect:rect,rotate:0,preserveAspectRatio:true))
            cg.drawPDFPage(reference)
            guard let image=cg.makeImage() else { throw ConverterError.message("页面渲染失败。") }
            let suffix=doc.pageCount>1 ? "-page-\(i+1)" : ""
            let output=scratch.appendingPathComponent(stem+suffix+"."+target)
            let type:CFString
            switch target {
            case "png":type=UTType.png.identifier as CFString
            case "jpg","jpeg":type=UTType.jpeg.identifier as CFString
            case "heic":type=UTType.heic.identifier as CFString
            case "tiff":type=UTType.tiff.identifier as CFString
            case "bmp":type=UTType.bmp.identifier as CFString
            case "webp":type="org.webmproject.webp" as CFString
            case "avif":type="public.avif" as CFString
            default:throw ConverterError.message("不支持的页面图片格式。")
            }
            let available=CGImageDestinationCopyTypeIdentifiers() as! [String]
            if available.contains(type as String),let dest=CGImageDestinationCreateWithURL(output as CFURL,type,1,nil) {
                CGImageDestinationAddImage(dest,image,[kCGImageDestinationLossyCompressionQuality:settings.quality,kCGImagePropertyDPIWidth:dpi,kCGImagePropertyDPIHeight:dpi] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ConverterError.message("图片编码失败。") }
            } else {
                let png=scratch.appendingPathComponent("render-"+UUID().uuidString+".png")
                guard let dest=CGImageDestinationCreateWithURL(png as CFURL,UTType.png.identifier as CFString,1,nil) else { throw ConverterError.message("无法写入中间图片。") }
                CGImageDestinationAddImage(dest,image,[kCGImagePropertyDPIWidth:dpi,kCGImagePropertyDPIHeight:dpi] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw ConverterError.message("无法写入中间图片。") }
                // Share the native encoder path: macOS ImageIO cannot write WebP/AVIF on every supported OS.
                let encoded = try AdvancedNative.convert([png], option:"format_"+target, settings:settings, scratch:scratch, context:context, progress:{_,_ in})
                guard let generated=encoded.first else { throw ConverterError.message("图片编码未产生结果。") }
                if generated != output { try fm.moveItem(at:generated,to:output) }
                try? fm.removeItem(at:png)
            }
            outputs.append(try checked(output))
        }
        return outputs
    }
    private static func pdfBlockRect(_ block: [String:Any]) -> CGRect {
        func value(_ key: String) -> CGFloat {
            if let n=block[key] as? NSNumber { return CGFloat(n.doubleValue) }
            if let n=block[key] as? CGFloat { return n }
            return 0
        }
        return CGRect(x:value("x"),y:value("y"),width:value("width"),height:value("height"))
    }
    private static func pdfPageHasRasterContent(_ page: PDFPage) -> Bool {
        guard let reference=page.pageRef else { return false }
        var dictionary=reference.dictionary
        // Resources may be inherited from a Pages node rather than stored on the page.
        for _ in 0..<16 {
            guard let current=dictionary else { break }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current,"Resources",&resources),let resources=resources {
                return pdfResourcesHaveImages(resources,depth:0)
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current,"Parent",&parent) else { break }
            dictionary=parent
        }
        return false
    }
    private static func pdfResourcesHaveImages(_ resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth<16 else { return false }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects=objects else { return false }
        let state=LSOfficeRasterScan(depth:depth)
        CGPDFDictionaryApplyFunction(objects,{ _,object,context in
            guard let context=context else { return }
            let state=Unmanaged<LSOfficeRasterScan>.fromOpaque(context).takeUnretainedValue()
            if state.found { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object,.stream,&stream),let stream=stream else { return }
            guard let dictionary=CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary,"Subtype",&subtype),let subtype=subtype else { return }
            let kind=String(cString:subtype)
            if kind=="Image" { state.found=true }
            else if kind=="Form" {
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary,"Resources",&nested),let nested=nested {
                    state.found=OfficeEngine.pdfResourcesHaveImages(nested,depth:state.depth+1)
                }
            }
        },Unmanaged.passUnretained(state).toOpaque())
        return state.found
    }
    private static func pdfImageMaskingNativeText(_ image: CGImage, pageBounds: CGRect, blocks: [[String:Any]]) throws -> CGImage {
        guard !blocks.isEmpty else { return image }
        guard let bitmap=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConverterError.message("无法分配扫描文字识别画布。") }
        bitmap.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let sx=CGFloat(image.width)/pageBounds.width,sy=CGFloat(image.height)/pageBounds.height
        bitmap.setFillColor(NSColor.white.cgColor)
        for block in blocks {
            let r=pdfBlockRect(block).insetBy(dx:-1.5,dy:-1.5)
            bitmap.fill(CGRect(x:r.minX*sx,y:(pageBounds.height-r.maxY)*sy,width:r.width*sx,height:r.height*sy))
        }
        guard let result=bitmap.makeImage() else { throw ConverterError.message("无法准备扫描文字识别画布。") }
        return result
    }
    private static func pdfOCRDuplicatesNative(_ text: String, rect: CGRect, blocks: [[String:Any]]) -> Bool {
        func normalized(_ value: String) -> String {
            value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")).unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.map{String($0)}.joined()
        }
        let recognized=normalized(text)
        guard !recognized.isEmpty else { return false }
        let nearby=blocks.filter{pdfBlockRect($0).insetBy(dx:-3,dy:-3).intersects(rect)}.sorted{pdfBlockRect($0).minX<pdfBlockRect($1).minX}
        if nearby.contains(where:{ normalized(($0["text"] as? String) ?? "").contains(recognized) }) { return true }
        return !nearby.isEmpty && normalized(nearby.compactMap{$0["text"] as? String}.joined(separator:" "))==recognized
    }
    private static func pdfIsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            (0x2E80...0x9FFF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value) ||
            (0xF900...0xFAFF).contains(s.value) || (0x20000...0x323AF).contains(s.value)
        }
    }
    private static func pdfCJKCoordinatesAreSuspect(_ text: String, rect: CGRect, glyphs: [CGRect]) -> Bool {
        guard glyphs.count>=2,rect.width>rect.height*1.25 else { return false }
        // Do not reinterpret RTL, bidi controls or vertical text as horizontal LTR.
        guard !text.unicodeScalars.contains(where:{ s in
            (0x0590...0x08FF).contains(s.value) || (0xFB1D...0xFDFF).contains(s.value) ||
            (0xFE70...0xFEFF).contains(s.value) || (0x200E...0x200F).contains(s.value) ||
            (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
        }),let first=glyphs.first,glyphs.allSatisfy({ abs($0.midY-first.midY)<rect.height*0.3 }) else { return false }
        if glyphs.contains(where:{$0.width<max(0.25,rect.height*0.05)}) { return true }
        return zip(glyphs,glyphs.dropFirst()).contains { previous,current in current.midX<previous.midX-rect.height*0.15 }
    }
    private static func pdfCorrectCJKOrder(_ blocks: [[String:Any]], suspects: Set<Int>, page: PDFPage, bounds: CGRect, context: OperationContext) throws -> [[String:Any]] {
        guard !suspects.isEmpty,bounds.width>0,bounds.height>0 else { return blocks }
        var result=blocks
        do {
            try context.check()
            let scale=min(3,4096/max(bounds.width,bounds.height))
            let thumb=page.thumbnail(of:NSSize(width:bounds.width*scale,height:bounds.height*scale),for:.mediaBox)
            var proposed=CGRect(origin:.zero,size:thumb.size)
            guard let image=thumb.cgImage(forProposedRect:&proposed,context:nil,hints:nil) else { return blocks }
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
            request.usesLanguageCorrection=false;request.automaticallyDetectsLanguage=true;request.minimumTextHeight=0.005
            let supported=try request.supportedRecognitionLanguages()
            request.recognitionLanguages=["zh-Hans","zh-Hant","ja","ko","en-US"].filter{supported.contains($0)}
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request]);try context.check()
            func letters(_ value: String) -> [UInt32] { value.unicodeScalars.filter{!CharacterSet.whitespacesAndNewlines.contains($0)}.map(\.value) }
            for index in suspects.sorted() {
                guard let text=blocks[index]["text"] as? String else { continue }
                let native=letters(text),rect=pdfBlockRect(blocks[index])
                guard !native.isEmpty,native.count<=10000 else { continue }
                for observation in request.results ?? [] {
                    let box=observation.boundingBox
                    let r=CGRect(x:box.minX*bounds.width,y:(1-box.maxY)*bounds.height,width:box.width*bounds.width,height:box.height*bounds.height)
                    let overlap=rect.intersection(r)
                    guard !overlap.isNull,overlap.height>=min(rect.height,r.height)*0.65,
                          abs(rect.midY-r.midY)<=max(rect.height,r.height)*0.4,
                          overlap.width>=min(rect.width,r.width)*0.8 else { continue }
                    for candidate in observation.topCandidates(3) {
                        let visual=letters(candidate.string)
                        // OCR may reorder only the existing characters: never use
                        // it to insert, drop, substitute or case-fold native text.
                        if native != visual,native.sorted()==visual.sorted() {
                            result[index]["text"]=candidate.string;break
                        }
                    }
                }
            }
        } catch {
            // An uncertain OCR repair keeps all native content. Cancellation still
            // propagates; PDF extraction never requires a network or Poppler.
            try context.check()
        }
        return result
    }
    private static func pdfModel(_ source: URL, to output: URL, context: OperationContext) throws {
        guard let doc=PDFDocument(url:source),doc.pageCount>0,!doc.isLocked else { throw ConverterError.message("PDF 无法读取或需要密码。") }
        var pages:[[String:Any]]=[]
        for i in 0..<doc.pageCount {
            try context.check()
            guard let page=doc.page(at:i) else { continue }
            let bounds=page.bounds(for:.mediaBox)
            var blocks:[[String:Any]]=[]
            var suspectCJK=Set<Int>()
            if let whole=page.selection(for:bounds), !(whole.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                for line in whole.selectionsByLine() {
                    guard let text=line.string,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
                    let rect=line.bounds(for:page)
                    // PDF text selections collapse wide table gaps into ordinary spaces. Recover column
                    // fragments from glyph coordinates so spreadsheets receive real separate cells.
                    let pageText=(page.string ?? "") as NSString
                    var fragments:[(String,CGRect)]=[],fragment="",fragmentRect=CGRect.null,pending=""
                    var previousRect: CGRect?
                    var cjkGlyphs:[CGRect]=[]
                    for rangeIndex in 0..<line.numberOfTextRanges(on:page) {
                        let range=line.range(at:rangeIndex,on:page)
                        var index=range.location
                        let end=min(NSMaxRange(range),pageText.length)
                        while index<end {
                            let composed=pageText.rangeOfComposedCharacterSequence(at:index)
                            let character=pageText.substring(with:composed)
                            let glyph=page.selection(for:composed)?.bounds(for:page) ?? page.characterBounds(at:index)
                            if pdfIsCJK(character),!glyph.isNull { cjkGlyphs.append(glyph) }
                            if character.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { pending += character }
                            else if !glyph.isNull && glyph.width>0 {
                                if let previous=previousRect,glyph.minX-previous.maxX>max(12,rect.height*1.25),!fragment.isEmpty {
                                    fragments.append((fragment,fragmentRect));fragment="";fragmentRect = .null;pending=""
                                }
                                if !fragment.isEmpty { fragment += pending }
                                fragment += character;fragmentRect=fragmentRect.union(glyph);pending="";previousRect=glyph
                            }
                            index=max(index+1,NSMaxRange(composed))
                        }
                    }
                    if !fragment.isEmpty { fragments.append((fragment,fragmentRect)) }
                    if fragments.count<2 { fragments=[(text,rect)] }
                    let suspect=pdfCJKCoordinatesAreSuspect(text,rect:rect,glyphs:cjkGlyphs)
                    for (fragment,r) in fragments {
                        if suspect,pdfIsCJK(fragment) { suspectCJK.insert(blocks.count) }
                        blocks.append(["text":fragment,"x":r.minX-bounds.minX,"y":bounds.maxY-r.maxY,"width":r.width,"height":r.height,"fontSize":max(8,min(72,r.height*0.8))])
                    }
                }
            }
            blocks=try pdfCorrectCJKOrder(blocks,suspects:suspectCJK,page:page,bounds:bounds,context:context)
            // A scan may also contain a native footer/header or an existing OCR layer.
            // Keep native text and recognize uncovered raster content on the same page.
            if blocks.isEmpty || pdfPageHasRasterContent(page) {
                guard bounds.width>0,bounds.height>0,bounds.width.isFinite,bounds.height.isFinite else { throw ConverterError.message("PDF 页面尺寸无效。") }
                let ocrScale=min(2,4096/max(bounds.width,bounds.height))
                let thumb=page.thumbnail(of:NSSize(width:bounds.width*ocrScale,height:bounds.height*ocrScale),for:.mediaBox)
                var rect=CGRect(origin:.zero,size:thumb.size)
                guard let image=thumb.cgImage(forProposedRect:&rect,context:nil,hints:nil) else { throw ConverterError.message("无法渲染 PDF 以识别扫描文字。") }
                let nativeBlocks=blocks
                let uncovered=try pdfImageMaskingNativeText(image,pageBounds:bounds,blocks:nativeBlocks)
                let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=true;request.automaticallyDetectsLanguage=true
                request.minimumTextHeight=0.005
                try context.check()
                try VNImageRequestHandler(cgImage:uncovered,options:[:]).perform([request])
                try context.check()
                for observation in request.results ?? [] {
                    guard let candidate=observation.topCandidates(1).first else { continue }
                    let r=observation.boundingBox
                    let positioned=CGRect(x:r.minX*bounds.width,y:(1-r.maxY)*bounds.height,width:r.width*bounds.width,height:r.height*bounds.height)
                    if pdfOCRDuplicatesNative(candidate.string,rect:positioned,blocks:nativeBlocks) { continue }
                    blocks.append(["text":candidate.string,"x":positioned.minX,"y":positioned.minY,"width":positioned.width,"height":positioned.height,"fontSize":max(8,min(72,positioned.height*0.8))])
                }
            }
            blocks.sort { a,b in
                let ar=pdfBlockRect(a),br=pdfBlockRect(b)
                return ar.minY == br.minY ? ar.minX<br.minX : ar.minY<br.minY
            }
            pages.append(["width":bounds.width,"height":bounds.height,"blocks":blocks])
        }
        guard pages.contains(where:{ !(($0["blocks"] as? [[String:Any]]) ?? []).isEmpty }) else { throw ConverterError.message("PDF 中没有可提取或可识别的文字，无法重建可编辑 Office 内容。") }
        let object:[String:Any]=["title":source.deletingPathExtension().lastPathComponent,"pages":pages]
        try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:output)
    }
}
