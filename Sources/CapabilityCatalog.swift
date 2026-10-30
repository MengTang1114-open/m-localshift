import Cocoa

enum CapabilityCatalog {
    static let formats: [String:[String]] = [
        "jpg": ["png", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        "png": ["jpg", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        "webp": ["jpg", "png", "heic", "tiff", "avif", "bmp", "pdf"],
        "heic": ["jpg", "png", "webp", "tiff", "avif", "bmp", "pdf"],
        "tiff": ["jpg", "png", "webp", "heic", "avif", "bmp", "pdf"],
        "svg": ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        "avif": ["jpg", "png", "webp", "heic", "tiff", "bmp", "pdf"],
        "bmp": ["jpg", "png", "webp", "heic", "tiff", "avif", "pdf"],
        "mp3": ["m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"],
        "m4a": ["mp3", "wav", "flac", "ogg", "opus", "aiff", "wma"],
        "wav": ["mp3", "m4a", "flac", "ogg", "opus", "aiff", "wma"],
        "flac": ["mp3", "m4a", "wav", "ogg", "opus", "aiff", "wma"],
        "ogg": ["mp3", "m4a", "wav", "flac", "opus", "aiff", "wma"],
        "opus": ["mp3", "m4a", "wav", "flac", "ogg", "aiff", "wma"],
        "aiff": ["mp3", "m4a", "wav", "flac", "ogg", "opus", "wma"],
        "wma": ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"],
        "mp4": ["mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"],
        "mov": ["mp4", "mkv", "webm", "avi", "wmv", "gif", "mp3"],
        "mkv": ["mp4", "mov", "webm", "avi", "wmv", "gif", "mp3"],
        "webm": ["mp4", "mov", "mkv", "avi", "wmv", "gif", "mp3"],
        "avi": ["mp4", "mov", "mkv", "webm", "wmv", "gif", "mp3"],
        "wmv": ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3"],
        "gif": ["mp4", "mov", "mkv", "webm", "avi", "wmv"],
        "pdf": ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"],
        "docx": ["pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "pages": ["docx", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "md": ["docx", "pages", "pdf", "txt", "html", "epub", "png", "jpg"],
        "rtf": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "rtfd": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "textclipping": ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"],
        "ppt": ["pdf", "jpg", "png"],
        "pptx": ["pdf", "jpg", "png"],
        "xlsx": ["ods", "csv", "tsv", "pdf"],
        "xls": ["xlsx", "ods", "csv", "tsv", "pdf"],
        "ods": ["xlsx", "csv", "tsv", "pdf"],
        "csv": ["xlsx", "ods", "tsv", "pdf"],
        "tsv": ["xlsx", "ods", "csv", "pdf"],
        "epub": ["pdf", "docx", "pages", "txt", "md", "html"],
        "txt": ["docx", "pages", "pdf", "md", "html", "epub", "jpg", "png"],
        "srt": ["vtt", "txt"],
        "vtt": ["srt", "txt"],
        "zip": ["tar", "gz"],
        "tar": ["zip", "gz"],
        "gz": ["zip", "tar"],
        "rar": ["zip", "tar", "gz"],
    ]
    static let aliases = ["jpeg":"jpg","tif":"tiff","heif":"heic","aif":"aiff","markdown":"md","tgz":"gz","m4v":"mp4"]
    static func ext(_ url: URL) -> String { let e=url.pathExtension.lowercased(); return aliases[e] ?? e }
    static func category(for url: URL) -> FileCategory {
        if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true && !["pages","rtfd"].contains(url.pathExtension.lowercased()) { return .archive }
        let e=ext(url)
        if ["jpg","png","webp","heic","tiff","svg","avif","bmp"].contains(e) { return .image }
        if ["mp4","mov","mkv","webm","avi","wmv","gif"].contains(e) { return .video }
        if ["mp3","m4a","wav","flac","ogg","opus","aiff","wma","aac"].contains(e) { return .audio }
        if e=="pdf" { return .pdf }
        if ["ppt","pptx"].contains(e) { return .presentation }
        if ["xlsx","xls","ods","csv","tsv"].contains(e) { return .spreadsheet }
        if e=="epub" { return .ebook }
        if ["srt","vtt"].contains(e) { return .subtitle }
        if ["zip","tar","gz","rar"].contains(e) { return .archive }
        if ["docx","pages","md","rtf","rtfd","textclipping","txt","html","htm","doc","odt"].contains(e) { return .document }
        return .other
    }
    static let tools: [(String,String,String)] = [
        ("compress","压缩","arrow.down.right.and.arrow.up.left"),("removeMetadata","元数据","tag"),
        ("editImage","编辑照片","slider.horizontal.3"),("annotateImage","标注照片","pencil.and.outline"),
        ("frameImage","添加背景","photo.artframe"),("cropImage","裁剪图片","crop"),
        ("normalizeAudio","响度标准化","waveform"),("muteVideo","移除声音","speaker.slash"),
        ("trimVideo","裁剪视频时长","scissors"),("splitPDF","拆分 PDF","rectangle.split.2x1"),
        ("organizePDF","整理 PDF 页面","square.grid.2x2"),("extractArchive","解压归档","archivebox"),
        ("createPDF","图片合成 PDF","doc.badge.plus"),("mergePDF","合并 PDF","doc.on.doc"),
        ("cropVideo","裁剪视频画面","crop"),("changeVideoSpeed","调整视频速度","speedometer"),
        ("joinVideos","拼接视频","film.stack"),("videoSnapshots","视频截图","camera"),
        ("splitVideo","分割视频","scissors"),("audioToVideo","音频可视化","waveform.path"),
        ("trimAudio","裁剪音频","scissors"),("audioChannels","转换声道","hifispeaker.2"),
        ("createCollage","图片拼贴","rectangle.3.group"),("redactImage","遮挡照片","eye.slash"),
        ("redactVideo","遮挡视频","eye.slash"),("redactAudio","音频消音提示音","waveform.badge.minus")
    ]
    static func option(_ id: String) -> ConversionOption {
        if id=="readQRCode" { return ConversionOption(id:id,title:"识别二维码",subtitle:"本地读取二维码内容",symbol:"qrcode.viewfinder") }
        let t=tools.first { $0.0==id }
        return ConversionOption(id:id,title:t?.1 ?? id,subtitle:t?.1 ?? id,symbol:t?.2 ?? "wand.and.stars")
    }
    static func options(for url: URL, mode: WheelMode) -> [ConversionOption] {
        let cat=category(for:url), e=ext(url)
        if mode == .actions { return [] }
        if mode == .conversion {
            var outputs=formats[e] ?? []
            if cat == .archive && (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true { outputs=["zip","tar","gz"] }
            if ["html","htm","doc","odt"].contains(e) { outputs=["docx","pdf","txt","md","html","epub","png","jpg"].filter{$0 != e} }
            if cat == .audio || cat == .video { if OperationContext.executable("ffmpeg")==nil { return [] } }
            return outputs.map { ConversionOption(id:"format_"+$0,title:$0=="gz" ? "GZIP" : $0.uppercased(),subtitle:"转换为 "+$0.uppercased(),symbol:cat.symbol) }
        }
        let ids:[String]
        switch cat {
        case .image: ids=["compress","removeMetadata","editImage","annotateImage","frameImage","cropImage","redactImage","createPDF","createCollage","readQRCode"]
        case .video: ids=["compress","removeMetadata","muteVideo","trimVideo","cropVideo","changeVideoSpeed","joinVideos","videoSnapshots","splitVideo","redactVideo"]
        case .audio: ids=["compress","removeMetadata","normalizeAudio","audioToVideo","trimAudio","audioChannels","redactAudio"]
        case .pdf: ids=["compress","removeMetadata","splitPDF","organizePDF","mergePDF"]
        case .archive: ids=(try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true ? [] : ["extractArchive"]
        default: ids=[]
        }
        if (cat == .audio || cat == .video) && OperationContext.executable("ffmpeg")==nil { return [] }
        return ids.map(option)
    }
}
