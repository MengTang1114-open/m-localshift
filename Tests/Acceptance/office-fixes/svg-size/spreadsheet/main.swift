import Cocoa
import PDFKit
// Spreadsheet text/PDF cases never call the raster encoder.
enum AdvancedNative { static func convert(_ files:[URL],option:String,settings:ConversionSettings,scratch:URL,context:OperationContext,progress:@escaping(Double,String)->Void) throws -> [URL] { throw ConverterError.message("Unexpected raster path") } }
let args=CommandLine.arguments,root=URL(fileURLWithPath:args[1]),out=URL(fileURLWithPath:args[2])
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
var rows:[[String:Any]]=[]
for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({["xlsx","xls","ods","csv"].contains($0.pathExtension)}).sorted(by:{$0.path<$1.path}) {
 for target in file.pathExtension=="csv" ? ["pdf"] : ["csv","tsv"] {
 let name=file.lastPathComponent+"-"+target,folder=out.appendingPathComponent(name)
 try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 do {
  let urls=try OfficeEngine.convert([file],option:"format_"+target,settings:ConversionSettings(),scratch:folder,context:OperationContext()){_,_ in}
  var row:[String:Any] = ["name":name,"outputs":urls.map(\.path),"converted":true]
  if target=="pdf",let pdf=PDFDocument(url:urls[0]) {row["pdfkit_text"]=pdf.string ?? ""}
  rows.append(row);print(name,urls.map(\.lastPathComponent));fflush(stdout)
 } catch {rows.append(["name":name,"converted":false,"error":error.localizedDescription]);print(name,error.localizedDescription);fflush(stdout)}
 }
}
try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("engine-results.json"))
