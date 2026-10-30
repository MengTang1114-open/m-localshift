import Foundation
let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let root=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
var rows:[[String:Any]]=[]
for job in jobs {
    let name=job["name"] as! String,option=job["option"] as! String,inputs=(job["inputs"] as! [String]).map{URL(fileURLWithPath:$0)}
    let scratch=root.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
    var s=ConversionSettings();s.quality=1;s.width=160;s.height=120
    s.startSeconds=job["start"] as? Double ?? 0;s.endSeconds=job["end"] as? Double ?? 1
    s.speed=job["speed"] as? Double ?? 2;s.exactSize=job["exactSize"] as? Bool ?? false
    s.width=job["width"] as? Int ?? s.width;s.height=job["height"] as? Int ?? s.height
    s.splitPoints=job["splitPoints"] as? [Double] ?? [0.5,1.0]
    s.snapshotTimes=job["snapshotTimes"] as? [Double] ?? [0.2]
    s.compressionMode=job["compressionMode"] as? String ?? "quality";s.targetBytes=Int64(job["targetBytes"] as? Int ?? 0)
    if let rect=job["crop"] as? [Double] {s.cropRect=NormalizedRect(x:rect[0],y:rect[1],width:rect[2],height:rect[3])}
    if let rect=job["redaction"] as? [Double] {s.redactions=[RedactionRegion(rect:NormalizedRect(x:rect[0],y:rect[1],width:rect[2],height:rect[3]),start:job["redactStart"] as? Double ?? 0,end:job["redactEnd"] as? Double ?? 1,style:job["style"] as? String ?? "solid")]}
    do {
        let original=try inputs.map{try Data(contentsOf:$0)}
        let urls=try AdvancedMedia.convert(inputs,option:option,settings:s,scratch:scratch,context:OperationContext()){_,_ in}
        let unchanged=try original==inputs.map{try Data(contentsOf:$0)}
        rows.append(["name":name,"success":true,"outputs":urls.map(\.path),"sources_unchanged":unchanged]);print("DONE "+name)
    } catch {rows.append(["name":name,"success":false,"error":error.localizedDescription]);print("ERROR "+name+": "+error.localizedDescription)}
}
try JSONSerialization.data(withJSONObject:["cases":rows],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("runner-report.json"))
