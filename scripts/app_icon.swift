// Draws the app icon into an .iconset: a raft of planks on a sea-blue squircle, on
// Apple's icon grid (824-point body in a 1024 canvas), in every standard size.
//   swift scripts/app_icon.swift OUTPUT.iconset
import AppKit

let output=URL(fileURLWithPath:CommandLine.arguments[1])
try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)

func draw(_ pixels:Int) -> Data {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,
                             hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    let s=CGFloat(pixels)/1024
    let body=NSRect(x:100*s,y:100*s,width:824*s,height:824*s)
    let shape=NSBezierPath(roundedRect:body,xRadius:185*s,yRadius:185*s)
    NSGradient(colors:[NSColor(red:0.30,green:0.75,blue:0.93,alpha:1),NSColor(red:0.03,green:0.36,blue:0.62,alpha:1)])!.draw(in:shape,angle:-90)
    shape.addClip()
    // Waves.
    NSColor(white:1,alpha:0.16).setFill()
    for (row,y) in [(0,300.0),(1,230.0),(2,160.0)] {
        let wave=NSBezierPath(); wave.move(to:NSPoint(x:100*s,y:CGFloat(y)*s))
        for i in 0..<9 {
            let x=CGFloat(100+i*103+(row%2)*50)
            wave.curve(to:NSPoint(x:(x+103)*s,y:CGFloat(y)*s),controlPoint1:NSPoint(x:(x+34)*s,y:CGFloat(y+38)*s),controlPoint2:NSPoint(x:(x+69)*s,y:CGFloat(y-38)*s))
        }
        wave.line(to:NSPoint(x:1024*s,y:0)); wave.line(to:NSPoint(x:0,y:0)); wave.close(); wave.fill()
    }
    // Planks, seen from above at an angle, with two cross beams.
    let transform=NSAffineTransform(); transform.translateX(by:512*s,yBy:520*s); transform.rotate(byDegrees:-8); transform.concat()
    for i in 0..<5 {
        let plank=NSRect(x:(-250+CGFloat(i)*102)*s,y:-150*s,width:92*s,height:330*s)
        NSColor(red:0.80,green:0.58,blue:0.33,alpha:1).setFill()
        NSBezierPath(roundedRect:plank,xRadius:18*s,yRadius:18*s).fill()
        NSColor(red:0.62,green:0.42,blue:0.22,alpha:1).setFill()
        NSBezierPath(rect:NSRect(x:plank.minX+40*s,y:plank.minY+30*s,width:10*s,height:plank.height-60*s)).fill()
    }
    NSColor(red:0.52,green:0.34,blue:0.17,alpha:1).setFill()
    for y in [-95.0,110.0] { NSBezierPath(roundedRect:NSRect(x:-275*s,y:CGFloat(y)*s,width:550*s,height:42*s),xRadius:12*s,yRadius:12*s).fill() }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using:.png,properties:[:])!
}
for (points,scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let name="icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! draw(points*scale).write(to:output.appendingPathComponent(name))
}
