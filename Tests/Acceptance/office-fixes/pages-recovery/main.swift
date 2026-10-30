import Cocoa
let args=CommandLine.arguments,source=URL(fileURLWithPath:args[1]),target=args[2],folder=URL(fileURLWithPath:args[3],isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
let context=OperationContext(),lock=NSLock(),start=Date()
var cancelRequested=false
let watcher=DispatchSource.makeTimerSource(queue:DispatchQueue.global())
watcher.schedule(deadline:.now()+0.05,repeating:0.05)
watcher.setEventHandler {
 guard args.count>4,args[4]=="cancel-after-open",let entries=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:nil) else { return }
 for case let item as URL in entries where item.pathExtension=="faultlog" {
  if ((try? String(contentsOf:item,encoding:.utf8)) ?? "").contains("blocked") {
   lock.lock();cancelRequested=true;lock.unlock();context.cancel();watcher.cancel();break
  }
 }
}
watcher.resume();defer { watcher.cancel() }
var report:[String:Any] = ["source":source.path,"target":target]
do {let urls=try OfficeEngine.convert([source],option:"format_"+target,settings:ConversionSettings(),scratch:folder,context:context){_,_ in};report["converted"]=true;report["outputs"]=urls.map(\.path)}
catch ConverterError.cancelled {report["converted"]=false;report["cancelled"]=true;report["error"]="cancelled"}
catch {report["converted"]=false;report["error"]=error.localizedDescription}
lock.lock();report["cancel_requested"]=cancelRequested;lock.unlock();report["elapsed_seconds"]=Date().timeIntervalSince(start)
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("engine-result.json"))
print(report["converted"] ?? false);fflush(stdout)
