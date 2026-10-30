import Cocoa
import PDFKit
enum AdvancedNative { static func convert(_ files:[URL],option:String,settings:ConversionSettings,scratch:URL,context:OperationContext,progress:@escaping(Double,String)->Void) throws -> [URL] { throw ConverterError.message("Unexpected raster fallback") } }
let args=CommandLine.arguments,input=URL(fileURLWithPath:args[1]),out=URL(fileURLWithPath:args[2])
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
var rows:[[String:Any]]=[]
for file in try FileManager.default.contentsOfDirectory(at:input,includingPropertiesForKeys:nil).filter({$0.pathExtension=="pdf"}).sorted(by:{$0.path<$1.path}) {
 for target in file.lastPathComponent=="rich.pdf" ? ["docx","pptx","xlsx"] : ["docx"] {
  let name=file.deletingPathExtension().lastPathComponent+"-"+target,folder=out.appendingPathComponent(name)
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  do {let urls=try OfficeEngine.convert([file],option:"format_"+target,settings:ConversionSettings(),scratch:folder,context:OperationContext()){_,_ in};rows.append(["name":name,"converted":true,"outputs":urls.map(\.path)]);print(name,"converted");fflush(stdout)}
  catch {rows.append(["name":name,"converted":false,"error":error.localizedDescription]);print(name,error.localizedDescription);fflush(stdout)}
 }
}
try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("engine-results.json"))
