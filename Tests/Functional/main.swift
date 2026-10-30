import Cocoa
import PDFKit
import ImageIO

final class LSResults {
    let lock=NSLock();var finished=false;var rows:[[String:Any]]=[]
    func add(_ row:[String:Any]) { lock.lock();rows.append(row);lock.unlock() }
    func complete() { lock.lock();finished=true;lock.unlock() }
    var done:Bool { lock.lock();defer{lock.unlock()};return finished }
}
let args=CommandLine.arguments
if args.count<3 { print("Usage: functional-tests jobs.json report.json");exit(2) }
let jobsURL=URL(fileURLWithPath:args[1]),reportURL=URL(fileURLWithPath:args[2])
let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:jobsURL)) as! [[String:Any]]
let results=LSResults()
func validate(_ urls:[URL], context:OperationContext) throws {
    let fm=FileManager.default
    for url in urls {
        var dir:ObjCBool=false;guard fm.fileExists(atPath:url.path,isDirectory:&dir) else { throw ConverterError.message("Missing output") }
        if dir.boolValue {
            let children=try fm.contentsOfDirectory(at:url,includingPropertiesForKeys:nil)
            guard !children.isEmpty else { throw ConverterError.message("Empty output folder") }
            try validate(children.filter{!$0.lastPathComponent.hasPrefix(".")},context:context);continue
        }
        let ext=url.pathExtension.lowercased()
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size>0 else { throw ConverterError.message("Empty file") }
        if ["png","jpg","jpeg","heic","webp","tiff","bmp","avif","gif"].contains(ext) {
            if let source=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceCreateImageAtIndex(source,0,nil) != nil { continue }
            if let probe=OperationContext.executable("ffprobe") { let raw=try context.run(probe,["-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","json",url.path]); let model=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any];let streams=model?["streams"] as? [[String:Any]];guard let stream=streams?.first,(stream["width"] as? Int ?? 0)>0,(stream["height"] as? Int ?? 0)>0 else {throw ConverterError.message("No decoded image dimensions")};continue }
            throw ConverterError.message("Image output cannot decode")
        }
        if ["mp3","m4a","wav","flac","ogg","opus","aiff","wma","mp4","mov","mkv","webm","avi","wmv"].contains(ext) {
            guard let probe=OperationContext.executable("ffprobe") else { throw ConverterError.message("Missing ffprobe validator") }
            let text=try context.run(probe,["-v","error","-show_entries","stream=codec_name","-of","json",url.path])
            guard text.contains("codec_name") else { throw ConverterError.message("No media streams") }
            guard let ffmpeg=OperationContext.executable("ffmpeg") else {throw ConverterError.message("Missing media decode validator")}
            _=try context.run(ffmpeg,["-nostdin","-v","error","-i",url.path,"-f","null","-"],timeout:60);continue
        }
        if ext=="pdf" { guard let pdf=PDFDocument(url:url),pdf.pageCount>0 else { throw ConverterError.message("Invalid PDF") };continue }
        if ["docx","pptx","xlsx","ods","epub"].contains(ext) {
            let names=try context.run("/usr/bin/tar",["-tf",url.path])
            let must=["docx":"word/document.xml","pptx":"ppt/presentation.xml","xlsx":"xl/workbook.xml","ods":"content.xml","epub":"META-INF/container.xml"][ext]!
            guard names.contains(must) else { throw ConverterError.message("Missing format structure: "+must) };continue
        }
        if ext=="pages" {
            let names=try context.run("/usr/bin/tar",["-tf",url.path])
            guard names.contains("Index/") && names.contains(".iwa") else { throw ConverterError.message("Invalid Pages structure") };continue
        }
        if ["zip","tar","gz","tgz"].contains(ext) { _=try context.run("/usr/bin/tar",["-tf",url.path]);continue }
        if ["txt","md","html","csv","tsv","srt","vtt"].contains(ext) {
            guard let text=try? String(contentsOf:url,encoding:.utf8),!text.isEmpty else { throw ConverterError.message("Invalid UTF8 text output") }
        }
    }
}
DispatchQueue.global(qos:.userInitiated).async {
    for (index,job) in jobs.enumerated() {
        let name=job["name"] as? String ?? "job-\(index)"
        let inputs=(job["inputs"] as? [String] ?? []).map{URL(fileURLWithPath:$0)}
        var settings=ConversionSettings()
        let out=reportURL.deletingLastPathComponent().appendingPathComponent("outputs/\(index)")
        try? FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        settings.outputDirectory=out
        settings.width=job["width"] as? Int ?? 160;settings.height=job["height"] as? Int ?? 90
        settings.startSeconds=job["start"] as? Double ?? 0;settings.endSeconds=job["end"] as? Double ?? 0.6
        settings.speed=job["speed"] as? Double ?? 1.5
        settings.splitPoints=job["splitPoints"] as? [Double] ?? [0.4,0.8]
        settings.snapshotTimes=job["snapshotTimes"] as? [Double] ?? [0.1,0.6]
        settings.trimSilence=job["trimSilence"] as? Bool ?? false
        settings.channels=job["channels"] as? Int ?? 1
        settings.normalizeTarget = -18
        settings.pageOrder=job["pageOrder"] as? [Int] ?? [1,0,0]
        settings.pageRotations=[0:90]
        settings.exposure=0.4;settings.saturation=0.7
        settings.annotations=[ImageAnnotation(kind:"text",rect:NormalizedRect(x:0.1,y:0.2,width:0.5,height:0.2),text:"LocalShift 测试")]
        settings.bleepRanges=[TimeRange(start:0.2,end:0.4)]
        settings.redactions=[RedactionRegion(rect:NormalizedRect(x:0.1,y:0.1,width:0.3,height:0.3),start:0.2,end:0.6)]
        settings.padding=10;settings.cornerRadius=8
        settings.metadata=["Author":"LocalShift Test","Title":"本地转换"]
        settings.removeMetadata=job["removeMetadata"] as? Bool ?? false
        settings.cropRect=NormalizedRect(x:0.1,y:0.1,width:0.7,height:0.7)
        settings.exactSize=job["exactSize"] as? Bool ?? false
        settings.compressionMode=job["compressionMode"] as? String ?? "quality"
        settings.targetBytes=Int64(job["targetBytes"] as? Int ?? 0)
        do {
            let before=try inputs.filter{(try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) != true}.map{try Data(contentsOf:$0)}
            let urls=try ConverterEngine.convert(inputs,option:job["option"] as! String,settings:settings) { _,_ in }
            try validate(urls,context:OperationContext())
            let after=try inputs.filter{(try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) != true}.map{try Data(contentsOf:$0)}
            guard before==after else { throw ConverterError.message("Source bytes changed") }
            results.add(["name":name,"passed":true,"outputs":urls.map(\.path)])
        } catch { results.add(["name":name,"passed":false,"error":error.localizedDescription]) }
    }
    results.complete()
}
while !results.done { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
let failed=results.rows.filter{($0["passed"] as? Bool) != true}
let report:[String:Any]=["cases":results.rows,"passed":results.rows.count-failed.count,"failed":failed.count,"scope":"Actual input/output validation; does not prove original native application equivalence"]
try FileManager.default.createDirectory(at:reportURL.deletingLastPathComponent(),withIntermediateDirectories:true)
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL)
print("\(results.rows.count-failed.count) passed, \(failed.count) failed; \(reportURL.path)")
exit(failed.isEmpty ? 0 : 1)
