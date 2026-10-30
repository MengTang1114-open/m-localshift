import Cocoa
import ImageIO
import PDFKit
import Vision

@main enum MultiPageProbe {
    static func imageSummary(_ image:CGImage)->[String:Any] {
        var sample=[UInt8](repeating:0,count:4)
        sample.withUnsafeMutableBytes { bytes in
            if let ctx=CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) {
                ctx.interpolationQuality = .none
                ctx.translateBy(x:-10,y:-10)
                ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            }
        }
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["en-US"];request.usesLanguageCorrection=false
        try? VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        let text=(request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n")
        return ["pixels":[image.width,image.height],"corner_rgba":sample.map{Int($0)},"text":text]
    }
    static func inspect(_ url:URL)->[String:Any] {
        var data:[String:Any]=["file":url.path,"bytes":(try? Data(contentsOf:url).count) ?? 0]
        if url.pathExtension.lowercased()=="pdf",let doc=PDFDocument(url:url) {
            data["pages"]=doc.pageCount
            data["images"]=(0..<doc.pageCount).compactMap { index -> [String:Any]? in
                guard let page=doc.page(at:index) else{return nil}
                let size=page.bounds(for:.mediaBox).size
                guard let image=page.thumbnail(of:size,for:.mediaBox).cgImage(forProposedRect:nil,context:nil,hints:nil) else{return nil}
                return imageSummary(image)
            }
        } else if let source=CGImageSourceCreateWithURL(url as CFURL,nil) {
            data["pages"]=CGImageSourceGetCount(source)
            data["images"]=(0..<CGImageSourceGetCount(source)).compactMap { index -> [String:Any]? in
                guard let image=CGImageSourceCreateImageAtIndex(source,index,nil) else{return nil};return imageSummary(image)
            }
        }
        return data
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let phase=CommandLine.arguments[2]
        let fixtures=root.appendingPathComponent("fixtures",isDirectory:true)
        let output=root.appendingPathComponent(phase,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let tiff=fixtures.appendingPathComponent("two-pages.tiff"),red=fixtures.appendingPathComponent("single-red.png"),green=fixtures.appendingPathComponent("single-green.png")
        var cases:[(String,[URL],String,ConversionSettings)]=[]
        var settings=ConversionSettings();settings.width=320;settings.height=180;settings.quality=0.9
        for format in ["pdf","png","jpg","tiff","webp","heic","avif","bmp"] { cases.append(("tiff_to_"+format,[tiff],"format_"+format,settings)) }
        cases.append(("create_pdf_mixed",[tiff,green],"createPDF",settings))
        cases.append(("collage_multipage",[tiff,green],"createCollage",settings))
        for option in ["editImage","cropImage","annotateImage","frameImage","redactImage","removeMetadata","compress","readQRCode"] { cases.append(("tool_"+option,[tiff],option,settings)) }
        cases.append(("single_png_pdf",[red],"format_pdf",settings))
        cases.append(("single_tiff_png",[fixtures.appendingPathComponent("single.tiff")],"format_png",settings))
        cases.append(("single_edit_png",[red],"editImage",settings))
        cases.append(("single_collage",[red,green],"createCollage",settings))
        cases.append(("uppercase_tif_png",[fixtures.appendingPathComponent("uppercase.TIF")],"format_png",settings))
        var background=settings;background.backgroundImage=tiff
        cases.append(("multipage_background",[red],"frameImage",background))
        var records:[[String:Any]]=[]
        for (name,files,option,configuration) in cases {
            let scratch=output.appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
            var record:[String:Any]=["name":name,"option":option,"inputs":files.map{ $0.path }]
            do {
                let urls=try AdvancedNative.convert(files,option:option,settings:configuration,scratch:scratch,context:OperationContext()) { _,_ in }
                record["outputs"]=urls.map(inspect);record["status"]="success"
            } catch {record["status"]="error";record["error"]=error.localizedDescription}
            records.append(record)
        }
        let report:[String:Any]=["phase":phase,"source":inspect(tiff),"cases":records]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        print("Multi-page image probe \(phase): \(records.count) cases, \(output.path)/report.json")
    }
}
