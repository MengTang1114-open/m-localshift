import Foundation
import PDFKit
let doc=PDFDocument(url:URL(fileURLWithPath:CommandLine.arguments[1]))!
for n in 0..<doc.pageCount {
 let page=doc.page(at:n)!,text=(page.string ?? "") as NSString
 print("PAGE",n,text)
 for i in 0..<text.length {
  let ch=text.substring(with:NSRange(location:i,length:1))
  if ch.rangeOfCharacter(from:CharacterSet(charactersIn:"中内容不能丢失验收")) != nil {
   print(i,ch,page.characterBounds(at:i),page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .zero)
  }
 }
}
