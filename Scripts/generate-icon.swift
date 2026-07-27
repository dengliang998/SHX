import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift generate-icon.swift <output.png>")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create bitmap")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func roundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func strokeLine(
    from start: NSPoint,
    to end: NSPoint,
    width: CGFloat,
    color: NSColor,
    cap: NSBezierPath.LineCapStyle = .round
) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = width
    path.lineCapStyle = cap
    color.setStroke()
    path.stroke()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Unable to create graphics context")
}
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.interpolationQuality = .high
context.clear(CGRect(origin: .zero, size: size))

// Native macOS icon plate with a deep infrastructure-blue gradient.
let plateRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let plate = NSBezierPath(roundedRect: plateRect, xRadius: 205, yRadius: 205)
let plateShadow = NSShadow()
plateShadow.shadowColor = color(0.01, 0.04, 0.10, 0.34)
plateShadow.shadowBlurRadius = 42
plateShadow.shadowOffset = NSSize(width: 0, height: -18)
plateShadow.set()
color(0.06, 0.18, 0.34).setFill()
plate.fill()

NSGraphicsContext.saveGraphicsState()
plate.addClip()
NSGradient(colors: [
    color(0.10, 0.45, 0.82),
    color(0.07, 0.25, 0.53),
    color(0.04, 0.12, 0.28)
])!.draw(in: plateRect, angle: -58)

let cyanGlow = NSGradient(colorsAndLocations:
    (color(0.16, 0.84, 0.95, 0.34), 0),
    (color(0.12, 0.62, 0.94, 0), 1)
)!
cyanGlow.draw(
    fromCenter: NSPoint(x: 278, y: 790),
    radius: 0,
    toCenter: NSPoint(x: 278, y: 790),
    radius: 420,
    options: [.drawsAfterEndingLocation]
)

let topHighlight = NSBezierPath(roundedRect: NSRect(x: 112, y: 570, width: 800, height: 345), xRadius: 170, yRadius: 170)
color(0.55, 0.86, 1.0, 0.08).setFill()
topHighlight.fill()
NSGraphicsContext.restoreGraphicsState()

// Terminal window.
let windowRect = NSRect(x: 166, y: 218, width: 692, height: 594)
let windowShadow = NSShadow()
windowShadow.shadowColor = color(0, 0.02, 0.08, 0.42)
windowShadow.shadowBlurRadius = 30
windowShadow.shadowOffset = NSSize(width: 0, height: -14)
windowShadow.set()
roundedRect(windowRect, radius: 88, fill: color(0.025, 0.075, 0.14))
NSShadow().set()

let windowBorder = NSBezierPath(roundedRect: windowRect, xRadius: 88, yRadius: 88)
windowBorder.lineWidth = 5
color(0.45, 0.78, 1.0, 0.38).setStroke()
windowBorder.stroke()

let titleBarRect = NSRect(x: 169, y: 704, width: 686, height: 105)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: windowRect, xRadius: 86, yRadius: 86).addClip()
NSGradient(colors: [color(0.10, 0.24, 0.40), color(0.055, 0.15, 0.28)])!
    .draw(in: titleBarRect, angle: 90)
NSGraphicsContext.restoreGraphicsState()
strokeLine(
    from: NSPoint(x: 181, y: 704),
    to: NSPoint(x: 843, y: 704),
    width: 4,
    color: color(0.30, 0.62, 0.86, 0.28),
    cap: .butt
)

for (x, dotColor) in [
    (232.0, color(1.0, 0.38, 0.38)),
    (284.0, color(1.0, 0.72, 0.25)),
    (336.0, color(0.27, 0.85, 0.48))
] {
    dotColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: x, y: 744, width: 24, height: 24)).fill()
}

// Server rack: three clear machines with live status lights.
let rackRect = NSRect(x: 222, y: 306, width: 218, height: 338)
roundedRect(rackRect, radius: 38, fill: color(0.065, 0.20, 0.34))
let rackBorder = NSBezierPath(roundedRect: rackRect, xRadius: 38, yRadius: 38)
rackBorder.lineWidth = 4
color(0.24, 0.64, 0.92, 0.42).setStroke()
rackBorder.stroke()

for index in 0..<3 {
    let y = CGFloat(535 - index * 91)
    let slot = NSRect(x: 247, y: y, width: 168, height: 67)
    roundedRect(slot, radius: 18, fill: color(0.10, 0.30, 0.49))

    color(0.25, 0.93, 0.62).setFill()
    NSBezierPath(ovalIn: NSRect(x: 270, y: y + 24, width: 19, height: 19)).fill()
    strokeLine(
        from: NSPoint(x: 312, y: y + 34),
        to: NSPoint(x: 385, y: y + 34),
        width: 10,
        color: color(0.48, 0.75, 0.93, 0.70)
    )
}

// SSH connection path between rack and terminal prompt.
let connection = NSBezierPath()
connection.move(to: NSPoint(x: 440, y: 472))
connection.curve(
    to: NSPoint(x: 522, y: 472),
    controlPoint1: NSPoint(x: 475, y: 472),
    controlPoint2: NSPoint(x: 487, y: 472)
)
connection.lineWidth = 10
connection.lineCapStyle = .round
color(0.18, 0.86, 0.92, 0.78).setStroke()
connection.stroke()
color(0.29, 0.98, 0.67).setFill()
NSBezierPath(ovalIn: NSRect(x: 497, y: 457, width: 30, height: 30)).fill()

// Large terminal prompt remains recognizable at small icon sizes.
let promptAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 148, weight: .bold),
    .foregroundColor: color(0.77, 0.94, 1.0)
]
let prompt = ">_"
prompt.draw(at: NSPoint(x: 507, y: 398), withAttributes: promptAttributes)

// A few output lines add terminal context without visual noise.
strokeLine(
    from: NSPoint(x: 534, y: 360),
    to: NSPoint(x: 754, y: 360),
    width: 12,
    color: color(0.27, 0.57, 0.78, 0.62)
)
strokeLine(
    from: NSPoint(x: 534, y: 324),
    to: NSPoint(x: 680, y: 324),
    width: 12,
    color: color(0.23, 0.48, 0.69, 0.54)
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode PNG")
}
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
