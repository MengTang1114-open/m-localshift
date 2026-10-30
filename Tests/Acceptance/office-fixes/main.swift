import Cocoa
import PDFKit
// Editable-PDF cases do not call raster image export. Fail loudly if that unrelated path is entered.
enum AdvancedNative {
    static func convert(_ files:[URL],option:String,settings:ConversionSettings,scratch:URL,context:OperationContext,progress:@escaping(Double,String)->Void) throws -> [URL] { throw ConverterError.message("Raster encoder is outside this independent editable-Office harness.") }
}
let args=CommandLine.arguments
let fixtures=URL(fileURLWithPath:args[1],isDirectory:true),output=URL(fileURLWithPath:args[2],isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
var rows:[[String:Any]]=[]
for source in ["pure-native","pure-scan","mixed-scan"] {
    for target in ["docx","pptx","xlsx"] {
        let name=source+"-"+target,folder=output.appendingPathComponent(source+"-"+target,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            let urls=try OfficeEngine.convert([fixtures.appendingPathComponent(source+".pdf")],option:"format_"+target,settings:ConversionSettings(),scratch:folder,context:OperationContext()){_,_ in}
            rows.append(["name":name,"converted":true,"outputs":urls.map(\.path)])
            print(name,"converted");fflush(stdout)
        } catch {rows.append(["name":name,"converted":false,"error":error.localizedDescription]);print(name,error.localizedDescription);fflush(stdout)}
    }
}
try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("engine-results.json"))
