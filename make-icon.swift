import AppKit

let canvasSize = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvasSize, pixelsHigh: canvasSize,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("could not create the drawing surface")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let bodyRectangle = NSRect(x: 100, y: 100, width: 824, height: 824)
let body = NSBezierPath(roundedRect: bodyRectangle, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.78, alpha: 1).setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.16, green: 0.80, blue: 0.72, alpha: 1),
    ending: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.80, alpha: 1)
)
gradient?.draw(in: body, angle: -90)

NSColor.white.setFill()
NSColor.white.setStroke()

let speaker = NSBezierPath()
speaker.move(to: NSPoint(x: 290, y: 452))
speaker.line(to: NSPoint(x: 380, y: 452))
speaker.line(to: NSPoint(x: 510, y: 340))
speaker.line(to: NSPoint(x: 510, y: 684))
speaker.line(to: NSPoint(x: 380, y: 572))
speaker.line(to: NSPoint(x: 290, y: 572))
speaker.close()
speaker.lineJoinStyle = .round
speaker.lineWidth = 36
speaker.fill()
speaker.stroke()

for radius in [118.0, 212.0] {
    let wave = NSBezierPath()
    wave.appendArc(withCenter: NSPoint(x: 520, y: 512), radius: radius, startAngle: -42, endAngle: 42)
    wave.lineWidth = 46
    wave.lineCapStyle = .round
    wave.stroke()
}

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("could not encode the icon")
}
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
try data.write(to: URL(fileURLWithPath: outputPath))
