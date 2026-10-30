import Cocoa
import PDFKit
let root=URL(fileURLWithPath:CommandLine.arguments[1]),fm=FileManager.default
try fm.createDirectory(at:root,withIntermediateDirectories:true)
let fixtures=URL(fileURLWithPath:CommandLine.arguments[2]);var rows:[[String:Any]]=[]
func check(_ name:String,_ condition:Bool,_ detail:String="") {rows.append(["name":name,"passed":condition,"detail":detail])}
for (index,pair) in [("corrupt.png","format_jpg"),("corrupt.pdf","format_docx"),("corrupt.docx","format_pdf"),("corrupt.zip","extractArchive"),("corrupt.mp4","format_mov"),("traversal.zip","extractArchive"),("symlink.zip","extractArchive"),("macro.docx","format_pdf"),("external.docx","format_pdf"),("external.svg","format_pdf"),("oversized.png","format_jpg")].enumerated() {
 let source=fixtures.appendingPathComponent(pair.0),before=try Data(contentsOf:source),out=root.appendingPathComponent("output-\(index)");try fm.createDirectory(at:out,withIntermediateDirectories:true)
 var s=ConversionSettings();s.outputDirectory=out;var rejected=false,message=""
 do{_=try ConverterEngine.convert([source],option:pair.1,settings:s){_,_ in }}catch{rejected=true;message=error.localizedDescription}
 let unchanged=(try Data(contentsOf:source))==before,empty=(try fm.contentsOfDirectory(atPath:out.path)).isEmpty
 check(pair.0+" rejected without partial result or source changes",rejected && unchanged && empty,message)
}
let first=root.appendingPathComponent("publish-first"),last=root.appendingPathComponent("publish-last");try fm.createDirectory(at:first,withIntermediateDirectories:true);try fm.createDirectory(at:last,withIntermediateDirectories:true)
let base=fixtures.deletingLastPathComponent().appendingPathComponent("fixtures/embedded.png")
let a=first.appendingPathComponent("a.png"),b=last.appendingPathComponent("b.png");try fm.copyItem(at:base,to:a);try fm.copyItem(at:base,to:b)
try fm.setAttributes([.posixPermissions:0o555],ofItemAtPath:last.path)
var rejected=false
var s=ConversionSettings()
do{_=try ConverterEngine.convert([a,b],option:"format_jpg",settings:s){_,_ in }}catch{rejected=true}
try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:last.path)
let firstNames=try fm.contentsOfDirectory(atPath:first.path),lastNames=try fm.contentsOfDirectory(atPath:last.path)
check("Later publish failure rolls back already-published output",rejected && firstNames==["a.png"] && lastNames==["b.png"],"first=\(firstNames) last=\(lastNames)")
check("Archive traversal wrote nothing outside destination",!fm.fileExists(atPath:root.appendingPathComponent("outside-marker.txt").path))
// Invalid selection must fail before touching user data.
var invalid=ConversionSettings();invalid.cropRect=NormalizedRect(x:0.9,y:0,width:0.5,height:0.5);invalid.outputDirectory=root
var invalidRejected=false
do{_=try ConverterEngine.convert([base],option:"cropImage",settings:invalid){_,_ in }}catch{invalidRejected=true}
check("Out-of-bounds image crop rejected",invalidRejected)
let failed=rows.filter{$0["passed"] as? Bool != true};let report:[String:Any]=["passed":rows.count-failed.count,"failed":failed.count,"cases":rows]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("report.json"))
print("Acceptance negative: \(rows.count-failed.count)/\(rows.count) passed");for item in failed{print(item)};exit(failed.isEmpty ? 0:1)
