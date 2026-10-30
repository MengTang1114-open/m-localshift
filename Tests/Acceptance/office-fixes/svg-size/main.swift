import Cocoa
import PDFKit
import ImageIO
let args=CommandLine.arguments,tests=URL(fileURLWithPath:args[1],isDirectory:true),output=URL(fileURLWithPath:args[2],isDirectory:true),inputs=URL(fileURLWithPath:args[3],isDirectory:true)
func run(_ file:URL,_ target:String,_ folder:URL,_ name:String) throws -> [String:Any] {
 try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 var row:[String:Any] = ["name":name,"source":file.path,"target":target]
 if file.lastPathComponent.hasSuffix("control.pdf") { row["source_pdfkit_text"]=PDFDocument(url:file)?.string ?? "" }
 do {
  let urls=try OfficeEngine.convert([file],option:"format_"+target,settings:ConversionSettings(),scratch:folder,context:OperationContext()){_,_ in}
  row["outputs"]=urls.map(\.path);row["converted"]=true
  if let url=urls.first,urls.count==1 {
   row["output"]=url.path
   if target=="pdf",let doc=PDFDocument(url:url),let page=doc.page(at:0) {let box=page.bounds(for:.mediaBox);row["width"]=Double(box.width);row["height"]=Double(box.height);row["pages"]=doc.pageCount}
   else if let source=CGImageSourceCreateWithURL(url as CFURL,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] {row["width"]=props[kCGImagePropertyPixelWidth];row["height"]=props[kCGImagePropertyPixelHeight]}
  }
 } catch {row["converted"]=false;row["error"]=error.localizedDescription}
 print(name,row["converted"] ?? false);fflush(stdout);return row
}
func save(_ rows:[[String:Any]],_ group:String) throws {
 let folder=output.appendingPathComponent(group,isDirectory:true)
 try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("engine-results.json"))
}
var rows:[[String:Any]]=[]
let onlyRaster=args.count>4 && args[4]=="raster-only"
if !onlyRaster {
for file in try FileManager.default.contentsOfDirectory(at:tests.appendingPathComponent("fixtures"),includingPropertiesForKeys:nil).filter({$0.pathExtension=="svg"}).sorted(by:{$0.path<$1.path}) {
 let targets=file.lastPathComponent=="original.svg" ? ["png","jpg","webp","tiff","avif","bmp","pdf"] : ["png","pdf"]
 for target in targets {let name=file.deletingPathExtension().lastPathComponent+"-"+target;rows.append(try run(file,target,output.appendingPathComponent("svg/"+name),name))}
}
try save(rows,"svg");rows=[]
for file in try FileManager.default.contentsOfDirectory(at:tests.appendingPathComponent("rich-order/fixtures"),includingPropertiesForKeys:nil).filter({$0.pathExtension=="pdf"}).sorted(by:{$0.path<$1.path}) {
 for target in file.lastPathComponent=="rich.pdf" ? ["docx","pptx","xlsx"] : ["docx"] {let name=file.deletingPathExtension().lastPathComponent+"-"+target;rows.append(try run(file,target,output.appendingPathComponent("rich/"+name),name))}
}
try save(rows,"rich");rows=[]
for file in try FileManager.default.contentsOfDirectory(at:inputs,includingPropertiesForKeys:nil).filter({["xlsx","xls","ods","csv"].contains($0.pathExtension)}).sorted(by:{$0.path<$1.path}) {
 for target in file.pathExtension=="csv" ? ["pdf"] : ["csv","tsv"] {let name=file.lastPathComponent+"-"+target;rows.append(try run(file,target,output.appendingPathComponent("spreadsheet/"+name),name))}
}
try save(rows,"spreadsheet");rows=[]
let ordinary=tests.deletingLastPathComponent().appendingPathComponent("fixtures")
for source in ["pure-native","pure-scan","mixed-scan"] {
 for target in ["docx","pptx","xlsx"] {let name=source+"-"+target;rows.append(try run(ordinary.appendingPathComponent(source+".pdf"),target,output.appendingPathComponent("regression/"+name),name))}
}
try save(rows,"regression")
}
rows=[]
for file in try FileManager.default.contentsOfDirectory(at:tests.appendingPathComponent("raster-fixtures"),includingPropertiesForKeys:nil).filter({$0.pathExtension=="pdf"}).sorted(by:{$0.path<$1.path}) {
 let targets=file.lastPathComponent.hasSuffix("limit.pdf") || file.lastPathComponent=="many-pages.pdf" ? ["png"] : ["png","jpg"]
 for target in targets {let name=file.deletingPathExtension().lastPathComponent+"-"+target;rows.append(try run(file,target,output.appendingPathComponent("raster/"+name),name))}
}
try save(rows,"raster")
let ordinary=tests.deletingLastPathComponent().appendingPathComponent("fixtures")
rows=[try run(ordinary.appendingPathComponent("nested-sdt.docx"),"png",output.appendingPathComponent("ordinary-office/nested-sdt-png"),"ordinary-office-144dpi")]
try save(rows,"ordinary-office")
