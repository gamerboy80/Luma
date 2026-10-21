import AppKit
import Foundation
let destination=URL(fileURLWithPath:CommandLine.arguments[1])
var entries:[[String:String]]=[]
for size in [16,32,128,256,512] {
 for scale in [1,2] {
  let pixels=size*scale
  let bounds=NSRect(x:0,y:0,width:pixels,height:pixels)
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:pixels*4,bitsPerPixel:32)!
  NSGraphicsContext.saveGraphicsState()
  let graphics=NSGraphicsContext(bitmapImageRep:bitmap)!
  NSGraphicsContext.current=graphics
  NSGradient(colors:[NSColor(calibratedRed:0.035,green:0.12,blue:0.16,alpha:1),NSColor(calibratedRed:0.018,green:0.045,blue:0.065,alpha:1)])?.draw(in:bounds,angle:90)
  let f=Double(pixels)
  for i in 0..<3 {
   let baseline=f*(0.25+Double(i)*0.20)
   let path=NSBezierPath();path.move(to:NSPoint(x:f*0.18,y:baseline))
   path.curve(to:NSPoint(x:f*0.82,y:baseline),controlPoint1:NSPoint(x:f*0.37,y:baseline+f*0.12),controlPoint2:NSPoint(x:f*0.63,y:baseline+f*0.12))
   path.lineWidth=max(1.2,f*0.026);path.lineCapStyle = .round
   NSColor(calibratedRed:0.43,green:0.88,blue:0.75,alpha:1-Double(i)*0.14).setStroke();path.stroke()
  }
  graphics.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()
  let filename="icon-\(size)-\(scale)x.png"
  try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(filename))
  entries.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":filename])
 }
}
try JSONSerialization.data(withJSONObject:["images":entries,"info":["author":"xcode","version":1]],options:[.prettyPrinted,.sortedKeys]).write(to:destination.appendingPathComponent("Contents.json"))
