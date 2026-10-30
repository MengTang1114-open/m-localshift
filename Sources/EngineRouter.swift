import Cocoa

enum ConverterEngine {
    private static let serial=NSLock()
    private static let state=NSLock()
    private static var current: OperationContext?
    static func category(for url: URL) -> FileCategory { CapabilityCatalog.category(for:url) }
    static func options(for url: URL, mode: WheelMode) -> [ConversionOption] { CapabilityCatalog.options(for:url,mode:mode) }
    static func dependencies() -> [String:Bool] {
        var d=[String:Bool]()
        d["FFmpeg"]=OperationContext.executable("ffmpeg") != nil
        d["WebP"]=AdvancedNative.webpAvailable
        d["ffprobe"]=OperationContext.executable("ffprobe") != nil
        d["Pages"]=FileManager.default.fileExists(atPath:"/Applications/Pages.app")
        d["Numbers"]=FileManager.default.fileExists(atPath:"/Applications/Numbers.app")
        d["Keynote"]=FileManager.default.fileExists(atPath:"/Applications/Keynote.app")
        return d
    }
    /// First free name in `folder`: "name.ext", then "name (1).ext", "name (2).ext", ...
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let original = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: original.path) { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var n = 1
        while true {
            let next = folder.appendingPathComponent(stem + " (\(n))" + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
    static func cancel() { state.lock();let c=current;state.unlock();c?.cancel();FileTransfer.cancel() }
    static func canonical(_ id: String, category: FileCategory) -> String {
        let aliases=["stripMetadata":"removeMetadata","pdfSplit":"splitPDF","pdfMerge":"mergePDF","extract":"extractArchive","pdfImages":"format_png","extractAudio":"format_mp3"]
        if id=="trim" { return category == .audio ? "trimAudio" : "trimVideo" }
        if id=="crop" { return category == .image ? "cropImage" : "cropVideo" }
        if id=="speed" && category == .video { return "changeVideoSpeed" }
        if id=="normalize" { return "normalizeAudio" }
        if id=="mute" { return "muteVideo" }
        return aliases[id] ?? id
    }
    static func convert(_ files:[URL], option:String, settings:ConversionSettings, progress:@escaping(Double,String)->Void) throws -> [URL] {
        guard serial.try() else { throw ConverterError.message("已有处理任务正在运行。") };defer { serial.unlock() }
        guard let first=files.first else { throw ConverterError.message("请先添加文件。") }
        guard settings.quality.isFinite,(0...1).contains(settings.quality),settings.width>0,settings.height>0,settings.width<=16384,settings.height<=16384 else { throw ConverterError.message("质量或尺寸参数无效。") }
        let id=canonical(option,category:category(for:first))
        for f in files {
            guard f.isFileURL,FileManager.default.isReadableFile(atPath:f.path) else { throw ConverterError.message("无法读取："+f.lastPathComponent) }
            let valid=options(for:f,mode:.conversion)+options(for:f,mode:.tools)
            guard valid.contains(where:{$0.id==id}) else { throw ConverterError.message(f.lastPathComponent+" 不支持这个操作。") }
        }
        let c=OperationContext();state.lock();current=c;state.unlock();defer{state.lock();current=nil;state.unlock()}
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("LocalShift-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:scratch)}
        let combined=["createPDF","createCollage","mergePDF","joinVideos"].contains(id)
        if ["mergePDF","joinVideos","createCollage"].contains(id) && files.count<2 { throw ConverterError.message("此操作需要至少两个文件。") }
        let groups=combined ? [files] : files.map{[$0]}
        var staged:[(URL,URL)]=[]
        for (index,group) in groups.enumerated() {
            try c.check()
            let work=scratch.appendingPathComponent(String(index),isDirectory:true);try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let outputs=try dispatch(group,option:id,settings:settings,scratch:work,context:c) { value,text in progress((Double(index)+value)/Double(groups.count),text) }
            guard !outputs.isEmpty else { throw ConverterError.message("处理没有生成结果。") }
            let folder=settings.outputDirectory ?? group[0].deletingLastPathComponent()
            for output in outputs {
                let real=output.resolvingSymlinksInPath().standardizedFileURL.path
                guard real.hasPrefix(work.resolvingSymlinksInPath().path+"/"),FileManager.default.fileExists(atPath:real) else { throw ConverterError.message("引擎输出超出临时工作区。") }
                staged.append((output,folder))
            }
        }
        try c.check()
        var published:[URL]=[]
        do {
            for (output,folder) in staged {
                try c.check()
                var isDir:ObjCBool=false
                guard FileManager.default.fileExists(atPath:folder.path,isDirectory:&isDir),isDir.boolValue else { throw ConverterError.message("输出文件夹不存在。") }
                let tmp=folder.appendingPathComponent(".localshift-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:tmp)}
                try FileManager.default.copyItem(at:output,to:tmp);try c.check()
                var attempts=0
                while true {
                    let dest=uniqueURL(in:folder,name:output.lastPathComponent)
                    do { try FileManager.default.moveItem(at:tmp,to:dest);published.append(dest);break }
                    catch let err as NSError where err.domain==NSCocoaErrorDomain && err.code==NSFileWriteFileExistsError && attempts<10 { attempts+=1 }
                }
            }
            progress(1,"已完成 \(published.count) 个结果");return published
        } catch { for file in published { try? FileManager.default.removeItem(at:file) };throw error }
    }
    private static func dispatch(_ files:[URL], option:String, settings:ConversionSettings, scratch:URL, context:OperationContext, progress:@escaping(Double,String)->Void) throws -> [URL] {
        let cat=category(for:files[0])
        if cat == .video || cat == .audio { return try AdvancedMedia.convert(files,option:option,settings:settings,scratch:scratch,context:context,progress:progress) }
        if cat == .image {
            if CapabilityCatalog.ext(files[0])=="svg" && option.hasPrefix("format_") { return try OfficeEngine.convert(files,option:option,settings:settings,scratch:scratch,context:context,progress:progress) }
            return try AdvancedNative.convert(files,option:option,settings:settings,scratch:scratch,context:context,progress:progress)
        }
        if cat == .pdf && !option.hasPrefix("format_") { return try AdvancedNative.convert(files,option:option,settings:settings,scratch:scratch,context:context,progress:progress) }
        if cat == .subtitle {
            guard option.hasPrefix("format_") else { throw ConverterError.message("字幕只支持格式转换。") }
            return try files.map { try SubtitleEngine.convert($0, format: String(option.dropFirst(7)), scratch: scratch) }
        }
        return try OfficeEngine.convert(files,option:option,settings:settings,scratch:scratch,context:context,progress:progress)
    }
}
