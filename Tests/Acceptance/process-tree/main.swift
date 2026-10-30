import Cocoa
let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
var rows:[[String:Any]]=[]
for mode in ["cancel","timeout","timeout-zero-exit","normal-exit"] {
    let folder=root.appendingPathComponent(mode);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let script=folder.appendingPathComponent("spawn.sh"),marker=folder.appendingPathComponent("orphan-marker")
    let parent=mode=="normal-exit" ? "exit 0" : "wait"
    let trap=mode=="timeout-zero-exit" ? "trap 'exit 0' TERM\n" : ""
    try "#!/bin/sh\n\(trap)(trap '' TERM; sleep 3; echo orphan > '\(marker.path)') &\n\(parent)\n".write(to:script,atomically:true,encoding:.utf8)
    let context=OperationContext();if mode=="cancel" {DispatchQueue.global().asyncAfter(deadline:.now()+0.2){context.cancel()}}
    var cancelled=false,errored=false
    do{try context.run("/bin/sh",[script.path],timeout:mode.hasPrefix("timeout") ? 0.2:10)}catch ConverterError.cancelled{cancelled=true;errored=true}catch{errored=true}
    RunLoop.current.run(until:Date().addingTimeInterval(3.3))
    let leaked=FileManager.default.fileExists(atPath:marker.path)
    let outcome=mode=="cancel" ? cancelled : mode.hasPrefix("timeout") ? errored : !errored
    rows.append(["mode":mode,"expected_result":outcome,"descendant_wrote_after_return":leaked,"passed":outcome && !leaked])
}
let failed=rows.filter{$0["passed"] as? Bool != true}.count
let result:[String:Any]=["passed":rows.count-failed,"failed":failed,"cases":rows]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("report.json"));print(result)
exit(failed==0 ? 0:1)
