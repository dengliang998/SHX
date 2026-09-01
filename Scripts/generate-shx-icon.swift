import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift generate-shx-icon.swift <output.png>") }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create bitmap")
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
graphicsContext.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))

let plateRect = NSRect(x: 42, y: 42, width: 940, height: 940)
let plate = NSBezierPath(roundedRect: plateRect, xRadius: 220, yRadius: 220)
let shadow = NSShadow()
shadow.shadowColor = color(0.01, 0.02, 0.07, 0.65)
shadow.shadowBlurRadius = 32
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSGradient(colors: [color(0.09, 0.17, 0.30), color(0.045, 0.08, 0.18), color(0.015, 0.03, 0.08)])!.draw(in: plate, angle: -55)
NSShadow().set()

NSGraphicsContext.saveGraphicsState()
plate.addClip()
let glass = NSBezierPath()
glass.move(to: NSPoint(x: 42, y: 720))
glass.curve(to: NSPoint(x: 950, y: 960), controlPoint1: NSPoint(x: 290, y: 1120), controlPoint2: NSPoint(x: 750, y: 1060))
glass.line(to: NSPoint(x: 1024, y: 1024))
glass.line(to: NSPoint(x: 42, y: 1024))
glass.close()
color(0.20, 0.70, 1.0, 0.11).setFill()
glass.fill()
NSGraphicsContext.restoreGraphicsState()

let cyan = color(0.39, 0.97, 1.0)
let frame = NSBezierPath()
frame.move(to: NSPoint(x: 280, y: 710)); frame.line(to: NSPoint(x: 226, y: 710))
frame.curve(to: NSPoint(x: 172, y: 710), controlPoint1: NSPoint(x: 200, y: 710), controlPoint2: NSPoint(x: 172, y: 682))
frame.line(to: NSPoint(x: 172, y: 326))
frame.curve(to: NSPoint(x: 172, y: 272), controlPoint1: NSPoint(x: 172, y: 300), controlPoint2: NSPoint(x: 200, y: 272))
frame.line(to: NSPoint(x: 280, y: 272))
frame.move(to: NSPoint(x: 744, y: 710)); frame.line(to: NSPoint(x: 798, y: 710))
frame.curve(to: NSPoint(x: 852, y: 710), controlPoint1: NSPoint(x: 824, y: 710), controlPoint2: NSPoint(x: 852, y: 682))
frame.line(to: NSPoint(x: 852, y: 326))
frame.curve(to: NSPoint(x: 852, y: 272), controlPoint1: NSPoint(x: 852, y: 300), controlPoint2: NSPoint(x: 824, y: 272))
frame.line(to: NSPoint(x: 744, y: 272))
frame.lineWidth = 38; frame.lineCapStyle = .round; frame.lineJoinStyle = .round
cyan.setStroke(); frame.stroke()

let route = NSBezierPath()
route.move(to: NSPoint(x: 300, y: 512)); route.line(to: NSPoint(x: 454, y: 612)); route.line(to: NSPoint(x: 300, y: 712))
route.move(to: NSPoint(x: 454, y: 612)); route.line(to: NSPoint(x: 700, y: 612))
route.lineWidth = 46; route.lineCapStyle = .round; route.lineJoinStyle = .round
cyan.setStroke(); route.stroke()

color(0.55, 1.0, 0.78).setFill()
NSBezierPath(ovalIn: NSRect(x: 676, y: 588, width: 48, height: 48)).fill()
color(1, 1, 1, 0.9).setFill()
NSBezierPath(ovalIn: NSRect(x: 692, y: 604, width: 16, height: 16)).fill()

let footer = NSBezierPath(); footer.move(to: NSPoint(x: 244, y: 792)); footer.line(to: NSPoint(x: 780, y: 792))
footer.lineWidth = 12; footer.lineCapStyle = .round; color(0.36, 0.86, 1.0, 0.25).setStroke(); footer.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to encode PNG") }
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
