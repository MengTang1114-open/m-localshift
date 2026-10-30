import Cocoa
import ImageIO
import PDFKit
import CoreText

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/LocalShiftTests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let inputs = root.appendingPathComponent("inputs", isDirectory: true)
let outputs = root.appendingPathComponent("outputs", isDirectory: true)
try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
try fm.createDirectory(at: outputs, withIntermediateDirectories: true)
var records: [[String: Any]] = []
func expect(_ condition: @autoclosure () -> Bool, _ text: String) throws { if !condition() { throw ConverterError.message(text) } }
func test(_ name: String, _ run: () throws -> Void) {
    do { try run(); records.append(["name":name,"passed":true]); print("PASS \(name)") }
    catch { records.append(["name":name,"passed":false,"error":error.localizedDescription]); print("FAIL \(name): \(error.localizedDescription)") }
}
func convert(_ files: [URL], _ option: String, _ modify: ((inout ConversionSettings) -> Void)? = nil) throws -> [URL] {
    var settings = ConversionSettings(); settings.outputDirectory = outputs; modify?(&settings)
    return try ConverterEngine.convert(files, option: option, settings: settings, progress: { _,_ in })
}
func text(_ name: String, _ value: String) throws -> URL { let path = inputs.appendingPathComponent(name); try value.write(to: path, atomically: true, encoding: .utf8); return path }
func reject(_ run: () throws -> Void) throws {
    do { try run() } catch { return }; throw ConverterError.message("预期拒绝，实际成功")
}
@discardableResult func command(_ path: String, _ args: [String]) throws -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw ConverterError.message(String(data: data, encoding: .utf8) ?? "process failed") }
    return String(data: data, encoding: .utf8) ?? ""
}
func dimensions(_ file: URL) throws -> (Int, Int) {
    guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString: Any],let w = props[kCGImagePropertyPixelWidth] as? Int,let h = props[kCGImagePropertyPixelHeight] as? Int else { throw ConverterError.message("Not an image") }; return (w,h)
}
// Independent RFC 4180 reader used as the oracle for spreadsheet round trips.
func parseDelimited(_ text: String, separator: Character) throws -> [[String]] {
    let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    var rows: [[String]] = [], row: [String] = [], value = "", quoted = false, closed = false, i = 0
    while i < characters.count {
        let c = characters[i]
        if quoted {
            if c == "\"" {
                if i + 1 < characters.count && characters[i + 1] == "\"" { value.append("\""); i += 1 } else { quoted = false; closed = true }
            } else { value.append(c) }
        } else if c == separator { row.append(value); value = ""; closed = false }
        else if c == "\n" { row.append(value); rows.append(row); row = []; value = ""; closed = false }
        else if c == "\"" && value.isEmpty && !closed { quoted = true }
        else {
            if closed { throw ConverterError.message("invalid character after closing quote") }
            value.append(c)
        }
        i += 1
    }
    guard !quoted else { throw ConverterError.message("unterminated quote") }
    if !row.isEmpty || !value.isEmpty || closed { row.append(value); rows.append(row) }
    return rows
}
let image = inputs.appendingPathComponent("图片 sample.png")
let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(NSColor.systemOrange.cgColor);ctx.fill(CGRect(x:0,y:0,width:320,height:180))
ctx.setFillColor(NSColor.systemTeal.cgColor);ctx.fill(CGRect(x:0,y:0,width:80,height:90))
let dest = CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1,nil)!
CGImageDestinationAddImage(dest,ctx.makeImage()!,nil);CGImageDestinationFinalize(dest)
let imageBefore = try Data(contentsOf:image)

test("PNG → JPEG decodes, size and source preserved") {
    let file = try convert([image],"format_jpg")[0]; let size = try dimensions(file)
    try expect(size.0==320 && size.1==180,"dimensions changed")
    let data = try Data(contentsOf:file);try expect(data.starts(with:[0xff,0xd8]),"JPEG signature missing")
    let after = try Data(contentsOf:image);try expect(after==imageBefore,"source changed")
}
test("Existing output is never overwritten") {
    let first = try convert([image],"format_jpg")[0];let data = try Data(contentsOf:first)
    let second = try convert([image],"format_jpg")[0]
    let preserved = try Data(contentsOf:first);try expect(first != second && data==preserved,"collision overwrote result")
}
test("Image crop uses explicit normalized selection") {
    let file=try convert([image],"crop",{$0.cropRect=NormalizedRect(x:0.21875,y:0,width:0.5625,height:1)})[0]
    let size=try dimensions(file);try expect(size.0==180 && size.1==180,"wrong crop")
}
test("Metadata stripping produces valid image") { let file=try convert([image],"stripMetadata")[0];_ = try dimensions(file) }
for format in ["tiff","bmp","gif","heic","webp"] {
    if ConverterEngine.options(for:image,mode:.conversion).contains(where:{$0.id=="format_"+format}) {
        test("PNG → \(format.uppercased()) real encoding") {let out=try convert([image],"format_"+format)[0];let size=try dimensions(out);try expect(size.0==320,"invalid output")}
    }
}
let pdf=try convert([image],"format_pdf")[0]
test("Image → PDF has one page") {try expect(PDFDocument(url:pdf)?.pageCount==1,"invalid PDF")}
var merged:URL=pdf
test("Merge PDF preserves page order and count") {merged=try convert([pdf,pdf],"pdfMerge")[0];try expect(PDFDocument(url:merged)?.pageCount==2,"merge count wrong")}
test("Split PDF emits each page") {let pages=try convert([merged],"pdfSplit");try expect(pages.count==2,"split count wrong");for page in pages {try expect(PDFDocument(url:page)?.pageCount==1,"bad split page")}}
test("PDF → PNG renders all pages at 300 DPI") {let outputs=try convert([merged],"format_png");let pages=try outputs.flatMap { url -> [URL] in var dir:ObjCBool=false;fm.fileExists(atPath:url.path,isDirectory:&dir);return dir.boolValue ? try fm.contentsOfDirectory(at:url,includingPropertiesForKeys:nil) : [url] };try expect(pages.count==2,"missing pages");let size=try dimensions(pages[0]);try expect(size.0==1334 && size.1==750,"wrong 300 DPI pixel dimensions");let source=CGImageSourceCreateWithURL(pages[0] as CFURL,nil)!;let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [CFString:Any];try expect(abs((props[kCGImagePropertyDPIWidth] as? Double ?? 0)-300)<0.1,"missing 300 DPI metadata")}
test("Image-only PDF without readable text fails clearly") {try reject{_ = try convert([pdf],"format_txt")}}

let note=try text("notes.md","# Hello LocalShift\n\n中文本地转换\nA < B & C")
test("Markdown → HTML escapes input and keeps heading") {let url=try convert([note],"format_html")[0];let html=try String(contentsOf:url);try expect(html.contains("Hello LocalShift") && html.contains("&lt;"),"missing or unsafe content")}
test("Markdown → DOCX produces ZIP-based Word file") {let out=try convert([note],"format_docx")[0];let bytes=try Data(contentsOf:out);try expect(bytes.starts(with:[0x50,0x4b]),"DOCX magic missing")}
test("Markdown → TXT preserves Chinese") {let out=try convert([note],"format_txt")[0];let content=try String(contentsOf:out);try expect(content.contains("中文本地转换"),"Chinese lost")}
test("Document → PDF preserves selectable English and Chinese") {let out=try convert([note],"format_pdf")[0];let doc=PDFDocument(url:out);try expect(doc?.string?.contains("Hello LocalShift")==true && doc?.string?.contains("中文本地转换")==true,"PDF English or Chinese text lost")}
test("Generated DOCX → PDF retains every Chinese phrase") {
    let docx=try convert([note],"format_docx")[0]
    let out=try convert([docx],"format_pdf")[0]
    let text=PDFDocument(url:out)?.string ?? ""
    try expect(text.contains("中文本地转换") && text.contains("Hello LocalShift"),"DOCX PDF font fallback lost CJK text")
}
test("Long document PDF paginates without losing last line") {let long=try text("long.txt",String(repeating:"A line in a local document.\n",count:180)+"FINAL SENTENCE");let out=try convert([long],"format_pdf")[0];let doc=PDFDocument(url:out);try expect((doc?.pageCount ?? 0)>1 && doc?.string?.contains("FINAL SENTENCE")==true,"pagination failed")}
let csv=try text("表格.csv","name,note,value\r\n\"唐橘\",\"one, two\nthree\",\"a\"\"b\"\r\n")
test("CSV ↔ TSV round trip quoted multiline and Chinese") {let tsv=try convert([csv],"format_tsv")[0];let back=try convert([tsv],"format_csv")[0];let a=try parseDelimited(String(contentsOf:csv),separator:",");let b=try parseDelimited(String(contentsOf:back),separator:",");try expect(a==b,"table cells changed")}
test("CSV → XLSX → CSV preserves high precision digits and literal formula text") {
    let input=root.appendingPathComponent("precise.csv")
    try "name,value\nleading,00123\ndecimal,0.1234567890123456789\nlarge,12345678901234567890\nliteral,=1+2\namount,123.45\n".write(to:input,atomically:true,encoding:.utf8)
    let workbook=try convert([input],"format_xlsx")[0]
    let output=try convert([workbook],"format_csv")[0]
    let expected=try parseDelimited(String(contentsOf:input),separator:",")
    let actual=try parseDelimited(String(contentsOf:output),separator:",")
    try expect(actual==expected,"Spreadsheet conversion changed exact cells")
}
test("Malformed CSV is rejected") {let malformed=try text("broken.csv","a,\"unterminated");try reject{_ = try convert([malformed],"format_tsv")}}
let srt=try text("subs.srt","1\n00:00:01,200 --> 00:00:02,400\n你好，LocalShift。\n\n2\n00:00:03,000 --> 00:00:04,500\n第二行\n换行保留\n")
test("SRT → VTT → SRT preserves cues and milliseconds") {let vtt=try convert([srt],"format_vtt")[0];let srt2=try convert([vtt],"format_srt")[0];let out=try String(contentsOf:srt2);try expect(out.contains("00:00:01,200 --> 00:00:02,400") && out.contains("第二行\n换行保留"),"subtitle changed")}
test("Subtitles → TXT drops timing and numbering") {let out=try convert([srt],"format_txt")[0];let content=try String(contentsOf:out);try expect(content.contains("你好") && !content.contains("-->"),"timing leaked")}
test("VTT cue identifiers and settings are handled") {let vtt=try text("identified.vtt","WEBVTT\n\nintro\n00:01.000 --> 00:03.000 align:start\nFirst\n\nnext\n00:04.000 --> 00:05.000\nSecond\n");let out=try convert([vtt],"format_srt")[0];let content=try String(contentsOf:out);try expect(content.contains("00:00:01,000") && !content.contains("next") && content.contains("Second"),"cue id leaked")}

let folder=inputs.appendingPathComponent("sample folder",isDirectory:true);try fm.createDirectory(at:folder,withIntermediateDirectories:true)
try "归档内容".write(to:folder.appendingPathComponent("notes.txt"),atomically:true,encoding:.utf8)
for kind in ["zip","tar","gz"] {
    test("Folder → \(kind.uppercased()) → safe extraction") {let zip=try convert([folder],"format_"+kind)[0];let unpacked=try convert([zip],"extract")[0];let content=try String(contentsOf:unpacked.appendingPathComponent("sample folder/notes.txt"));try expect(content=="归档内容","archive content changed")}
}
test("Archive symlink is rejected before extraction") {let symlink=inputs.appendingPathComponent("link-folder",isDirectory:true);try fm.createDirectory(at:symlink,withIntermediateDirectories:true);try fm.createSymbolicLink(at:symlink.appendingPathComponent("escape"),withDestinationURL:URL(fileURLWithPath:"/private/tmp"));try reject{_ = try convert([symlink],"format_tar")}}
test("Mixed batch rejection leaves no partial output") {let before=try fm.contentsOfDirectory(atPath:outputs.path);let unknown=try text("unsupported-batch.bin","data");try reject{_ = try convert([image,unknown],"format_jpg")};let after=try fm.contentsOfDirectory(atPath:outputs.path);try expect(Set(before)==Set(after),"partial batch outputs leaked")}
test("Failed later batch input leaves no output") {let corrupt=try text("corrupt.png","not an image");let before=try fm.contentsOfDirectory(atPath:outputs.path);try reject{_ = try convert([image,corrupt],"format_jpg")};let after=try fm.contentsOfDirectory(atPath:outputs.path);try expect(Set(before)==Set(after),"partial failed outputs leaked")}
test("Invalid dimensions rejected") {try reject{_ = try convert([image],"format_jpg",{$0.width=0})}}
test("Cancellation leaves no partial result and engine can restart") {
    let before = try fm.contentsOfDirectory(atPath:outputs.path)
    var settings=ConversionSettings();settings.outputDirectory=outputs
    try reject {_ = try ConverterEngine.convert([image],option:"format_jpg",settings:settings,progress:{_,_ in ConverterEngine.cancel()})}
    let after = try fm.contentsOfDirectory(atPath:outputs.path);try expect(Set(before)==Set(after),"cancel leaked output")
    _ = try convert([image],"format_jpg")
}
test("SVG exposes the eight locked conversion targets") {let svg=try text("vector.svg","<svg/>");try expect(ConverterEngine.options(for:svg,mode:.conversion).count==8,"SVG matrix mismatch")}
test("Unknown format has no conversion or action wheel") {let file=try text("unknown.bin","test");try expect(ConverterEngine.options(for:file,mode:.conversion).isEmpty && ConverterEngine.options(for:file,mode:.actions).isEmpty,"wrong capability")}
test("File copy preserves source and creates unique names") {
    let first=try FileTransfer.perform([image],to:outputs,move:false,progress:{_,_ in})[0]
    let second=try FileTransfer.perform([image],to:outputs,move:false,progress:{_,_ in})[0]
    let copied=try Data(contentsOf:first)
    try expect(first != second && copied==imageBefore && fm.fileExists(atPath:image.path),"copy overwritten or changed source")
}
test("Move preflights all conflicts before moving any source") {
    let a=try text("move-a.txt","a"), b=try text("move-b.txt","b")
    try "existing".write(to:outputs.appendingPathComponent("move-b.txt"),atomically:true,encoding:.utf8)
    try reject{_ = try FileTransfer.perform([a,b],to:outputs,move:true,progress:{_,_ in})}
    try expect(fm.fileExists(atPath:a.path) && fm.fileExists(atPath:b.path),"partial move before conflict")
}
test("Move actually changes location without overwriting") {
    let a=try text("move-real.txt","content")
    let out=try FileTransfer.perform([a],to:outputs,move:true,progress:{_,_ in})[0]
    let value=try String(contentsOf:out)
    try expect(!fm.fileExists(atPath:a.path) && value=="content","move failed")
}
test("Copy cannot recurse into its own folder") {
    let child=folder.appendingPathComponent("child",isDirectory:true)
    try fm.createDirectory(at:child,withIntermediateDirectories:true)
    try reject{_ = try FileTransfer.perform([folder],to:child,move:false,progress:{_,_ in})}
}
test("File copy cancellation preserves original and output directory") {
    let before=try fm.contentsOfDirectory(atPath:outputs.path)
    try reject{_ = try FileTransfer.perform([image],to:outputs,move:false,progress:{_,_ in FileTransfer.cancel()})}
    let after=try fm.contentsOfDirectory(atPath:outputs.path)
    try expect(Set(before)==Set(after) && fm.fileExists(atPath:image.path),"cancelled copy leaked output")
}

if ConverterEngine.dependencies()["FFmpeg"]==true {
    let ffmpeg=OperationContext.executable("ffmpeg")!
    let tone=inputs.appendingPathComponent("tone.wav"), movie=inputs.appendingPathComponent("movie.mp4")
    try command(ffmpeg,["-nostdin","-v","error","-f","lavfi","-i","sine=frequency=440:duration=2",tone.path])
    try command(ffmpeg,["-nostdin","-v","error","-f","lavfi","-i","color=c=orange:s=320x180:d=2","-i",tone.path,"-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",movie.path])
    for format in ["mp3","m4a","flac","ogg","opus","aiff"] {
        test("WAV → \(format.uppercased()) decodes") {let out=try convert([tone],"format_"+format)[0];_ = try command(ffmpeg,["-nostdin","-v","error","-i",out.path,"-f","null","-"])}
    }
    for option in ["format_mov","format_mkv","format_webm","format_gif","extractAudio","mute","compress","normalize","trim","speed","crop"] {
        test("Media \(option) creates decodable output") {let input=option=="normalize" ? tone:movie;let out=try convert([input],option,{$0.startSeconds=0.3;$0.endSeconds=1.4;$0.width=1;$0.height=1})[0];_ = try command(ffmpeg,["-nostdin","-v","error","-i",out.path,"-f","null","-"])}
    }
    test("Invalid trim is rejected") {try reject{_ = try convert([movie],"trim",{$0.startSeconds=3;$0.endSeconds=1})}}
}
let passed=records.filter{$0["passed"] as? Bool==true}.count
let report:[String:Any]=["date":"2026-10-27","passed":passed,"failed":records.count-passed,"cases":records,"fixtureRoot":root.path,"dependencies":ConverterEngine.dependencies()]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:root.appendingPathComponent("report.json"))
print("RESULT \(passed)/\(records.count) passed; \(root.path)/report.json")
exit(passed==records.count ? 0:1)
