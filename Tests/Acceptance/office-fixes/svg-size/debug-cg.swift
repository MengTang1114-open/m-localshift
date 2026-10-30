import Cocoa
import PDFKit
import ImageIO
import UniformTypeIdentifiers
let input=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2])
let cgdoc=CGPDFDocument(input as CFURL)!,kit=PDFDocument(url:input)!
for mode in ["cg","kit"] {
 let page=mode=="cg" ? cgdoc.page(at:1)! : kit.page(at:0)!.pageRef!
 let box=page.getBoxRect(.mediaBox),canvas=CGRect(x:0,y:0,width:1334,height:750)
 let transform=page.getDrawingTransform(.mediaBox,rect:canvas,rotate:0,preserveAspectRatio:true)
 print(mode,box,page.rotationAngle,transform,"false:",page.getDrawingTransform(.mediaBox,rect:canvas,rotate:0,preserveAspectRatio:false))
 let context=CGContext(data:nil,width:1334,height:750,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 context.setFillColor(NSColor.white.cgColor);context.fill(canvas);context.concatenate(transform);context.drawPDFPage(page)
 let image=context.makeImage()!,dest=CGImageDestinationCreateWithURL(out.appendingPathComponent(mode+".png") as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,image,nil);CGImageDestinationFinalize(dest)
}
