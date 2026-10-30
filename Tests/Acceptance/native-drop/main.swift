import Cocoa
import PDFKit
// Standalone integration target: use the production wheel, controller and model,
// while supplying NSDraggingInfo at the native destination boundary. No fake
// converter or fake output is used. This is not a physical Finder gesture test.
final class AppDelegate:NSObject {
    static var shared:AppDelegate? = nil
    var shown = 0
    func showMainWindow() { shown += 1 }
}
final class DropInfo:NSObject,NSDraggingInfo {
    let draggingDestinationWindow:NSWindow?
    let draggingPasteboard:NSPasteboard
    var draggingLocation:NSPoint
    var draggingSourceOperationMask:NSDragOperation { .copy }
    var draggedImageLocation:NSPoint { draggingLocation }
    var draggedImage:NSImage? { nil }
    var draggingSource:Any? { nil }
    var draggingSequenceNumber:Int { 1 }
    var draggingFormation:NSDraggingFormation = .none
    var animatesToDestination=false
    var numberOfValidItemsForDrop=1
    var springLoadingHighlight:NSSpringLoadingHighlight { .none }
    init(window:NSWindow?,pasteboard:NSPasteboard,point:NSPoint) { draggingDestinationWindow=window;draggingPasteboard=pasteboard;draggingLocation=point }
    func slideDraggedImage(to screenPoint:NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination:URL)->[String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions,for view:NSView?,classes classArray:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
}
let root=URL(fileURLWithPath:CommandLine.arguments[1]),fm=FileManager.default
try fm.createDirectory(at:root,withIntermediateDirectories:true);setenv("LOCALSHIFT_STATE_DIR",root.appendingPathComponent("state").path,1)
let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
let model=AppModel.shared;let output=root.appendingPathComponent("outputs");try fm.createDirectory(at:output,withIntermediateDirectories:true);model.settings.outputDirectory=output
let source=root.appendingPathComponent("带 空格'引号#文件.docx");try fm.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[2]),to:source);let bytes=try Data(contentsOf:source)
let panel=DragWheelMonitor.shared.previewForSnapshot(urls:[source],centeredAt:NSPoint(x:500,y:500))!
let wheel=panel.contentView!.subviews.compactMap{$0 as? RadialWheelView}.first!
let index=wheel.options.firstIndex{$0.id=="format_pdf"}!,angle=Double(index)*2 * Double.pi/Double(wheel.options.count)
let point=wheel.convert(NSPoint(x:wheel.bounds.midX+sin(angle)*135,y:wheel.bounds.midY+cos(angle)*135),to:nil)
let pasteboard=NSPasteboard.withUniqueName();pasteboard.writeObjects([source as NSURL]);defer{pasteboard.releaseGlobally()}
let info=DropInfo(window:panel,pasteboard:pasteboard,point:point)
var checks:[[String:Any]]=[]
func check(_ name:String,_ passed:Bool){checks.append(["name":name,"passed":passed])}
func pointOnWheel(_ wheel:RadialWheelView,index:Int,radius:Double,gapSide:Bool)->NSPoint {
    let count=Double(max(wheel.options.count,1)),slice=2*Double.pi/count
    let gap=min(3.2*Double.pi/180,slice*0.08)
    let angle=Double(index)*slice+(gapSide ? slice/2-gap/2 : 0)
    let local=NSPoint(x:wheel.bounds.midX+CGFloat(sin(angle)*radius),y:wheel.bounds.midY+CGFloat(cos(angle)*radius))
    return wheel.convert(local,to:nil)
}
check("Native destination accepts file URL over PDF sector",wheel.draggingEntered(info) == .copy && wheel.prepareForDragOperation(info))
check("Native drop callback accepts the conversion",wheel.performDragOperation(info))
let limit=Date().addingTimeInterval(40)
while Date()<limit && model.history.isEmpty && model.errorMessage==nil {RunLoop.current.run(until:Date().addingTimeInterval(0.04))}
check("Wheel controller model engine history integration completes",!model.isConverting && model.errorMessage==nil && model.history.first?.optionID=="format_pdf")
if let path=model.history.first?.outputs.first,let pdf=PDFDocument(url:URL(fileURLWithPath:path)) {
    check("Actual DOCX PDF preserves both pages",pdf.pageCount==2)
    // PDFKit's string follows content-stream order for some fallback fonts;
    // Poppler layout extraction and raster review validate displayed reading order.
    let reader=Process(),pipe=Pipe();reader.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/pdftotext")
    reader.arguments=["-layout",path,"-"];reader.standardOutput=pipe;try reader.run()
    let text=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "";reader.waitUntilExit()
    check("Actual DOCX PDF retains Chinese content and last page",reader.terminationStatus==0 && text.contains("中文内容不能丢失") && text.contains("LAST_PAGE_SENTINEL_789"))
} else {check("Actual PDF result exists and decodes",false)}
check("File name with spaces apostrophe and hash preserves source",(try Data(contentsOf:source))==bytes)
let panel2=DragWheelMonitor.shared.previewForSnapshot(urls:[source],centeredAt:NSPoint(x:500,y:500))!
let wheel2=panel2.contentView!.subviews.compactMap{$0 as? RadialWheelView}.first!
let center=DropInfo(window:panel2,pasteboard:pasteboard,point:wheel2.convert(NSPoint(x:220,y:220),to:nil))
check("Native drop into center is rejected",!wheel2.performDragOperation(center))
DragWheelMonitor.shared.hide()
let delegate=AppDelegate();AppDelegate.shared=delegate
check("Control alone does not open a wheel",DragWheelMonitor.shared.modeFromFlags(.control)==nil)
check("Shift still opens conversion",DragWheelMonitor.shared.modeFromFlags(.shift) == .conversion)
check("Command still opens tools",DragWheelMonitor.shared.modeFromFlags(.command) == .tools)
let releasePanel=DragWheelMonitor.shared.previewForSnapshot(urls:[source],centeredAt:NSPoint(x:500,y:500))!
let releaseWheel=releasePanel.contentView!.subviews.compactMap{$0 as? RadialWheelView}.first!
let releaseIndex=releaseWheel.options.firstIndex{$0.id=="format_pdf"}!
let centerPoint=releaseWheel.convert(NSPoint(x:releaseWheel.bounds.midX,y:releaseWheel.bounds.midY),to:nil)
check("Release outside a sector does not run",!DragWheelMonitor.shared.commitRelease(atWindowPoint:centerPoint) && delegate.shown==0)
check("Release far from the wheel does not run",!DragWheelMonitor.shared.commitRelease(atWindowPoint:pointOnWheel(releaseWheel,index:releaseIndex,radius:320,gapSide:true)) && delegate.shown==0)
DragWheelMonitor.shared.hide()
let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
let image=root.appendingPathComponent("dot.png");try png.write(to:image)
model.errorMessage=nil
let historyBefore=model.history.count
let toolPanel=DragWheelMonitor.shared.previewForSnapshot(urls:[image],centeredAt:NSPoint(x:500,y:500),mode:.tools)!
let toolWheel=toolPanel.contentView!.subviews.compactMap{$0 as? RadialWheelView}.first!
let toolIndex=toolWheel.options.firstIndex{$0.id=="removeMetadata"}!
check("Release just outside a tool cell runs",DragWheelMonitor.shared.commitRelease(atWindowPoint:pointOnWheel(toolWheel,index:toolIndex,radius:216,gapSide:false)))
let toolLimit=Date().addingTimeInterval(20)
while Date()<toolLimit && model.history.count==historyBefore && model.errorMessage==nil {RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
check("Tool release strips metadata without opening the main window",delegate.shown==0 && model.errorMessage==nil && model.history.first?.optionID=="removeMetadata" && model.history.count==historyBefore+1)
DragWheelMonitor.shared.hide()
let escPanel=DragWheelMonitor.shared.previewForSnapshot(urls:[source],centeredAt:NSPoint(x:500,y:500))!
escPanel.alphaValue=1
escPanel.setFrameOrigin(NSPoint(x:200,y:200))
escPanel.orderFrontRegardless()
let escScreen=escPanel.convertPoint(toScreen:NSPoint(x:220,y:220))
DragWheelMonitor.shared.advance(buttons:0,physical:0,pointer:escScreen,flags:[],escape:true)
check("Escape hides a wheel that is still on screen",!escPanel.isVisible && escPanel.frame.minX < 0)
DragWheelMonitor.shared.stop()
// Tools that need a person's input open their editor on release and never start converting.
let plain=ConversionSettings()
check("Wheel editor rule covers photo edit, video redact, audio bleep and video split",["editImage","redactVideo","redactAudio","splitVideo"].allSatisfy{AppModel.wheelNeedsEditor($0,settings:plain)} && !AppModel.wheelNeedsEditor("removeMetadata",settings:plain))
for id in ["annotateImage","redactImage","cropImage"] {
    model.editingTool=nil;model.errorMessage=nil
    let historyCount=model.history.count,shownCount=delegate.shown
    let outputsBefore=(try? fm.contentsOfDirectory(atPath:output.path).count) ?? 0
    let editorPanel=DragWheelMonitor.shared.previewForSnapshot(urls:[image],centeredAt:NSPoint(x:500,y:500),mode:.tools)!
    let editorWheel=editorPanel.contentView!.subviews.compactMap{$0 as? RadialWheelView}.first!
    guard let editorIndex=editorWheel.options.firstIndex(where:{$0.id==id}) else {check("\(id) release opens its editor without converting",false);continue}
    let committed=DragWheelMonitor.shared.commitRelease(atWindowPoint:pointOnWheel(editorWheel,index:editorIndex,radius:150,gapSide:true))
    RunLoop.current.run(until:Date().addingTimeInterval(0.1))
    let outputsAfter=(try? fm.contentsOfDirectory(atPath:output.path).count) ?? 0
    check("\(id) release opens its editor without converting",committed && model.editingTool?.option.id==id && !model.isConverting && model.history.count==historyCount && outputsAfter==outputsBefore && delegate.shown==shownCount+1)
    model.editingTool=nil
    DragWheelMonitor.shared.hide()
}
let failed=checks.filter{$0["passed"] as? Bool != true}.count
let result:[String:Any]=["passed":checks.count-failed,"failed":failed,"cases":checks,"scope":"Production NSDraggingDestination to wheel controller AppModel engine actual PDF integration with supplied NSDraggingInfo; does not exercise physical Finder drag/global key monitor"]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("report.json"));print(result);exit(failed==0 ? 0:1)
