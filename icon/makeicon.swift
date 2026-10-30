import AppKit

// Jonah app icon: same construction as the Crocus and Mekong icons (rounded dark
// tile, soft radial glow, layered gradient forms) in warm amber, drawn as a
// simplified 3rd-generation iPod — screen, the 3G's row of four buttons, wheel.

let S: CGFloat = 1024
let C = NSPoint(x: S / 2, y: 370)   // wheel centre

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func circle(_ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: C.x - r, y: C.y - r, width: r * 2, height: r * 2))
}

func ring(outer: CGFloat, inner: CGFloat) -> NSBezierPath {
    let p = circle(outer)
    p.append(circle(inner).reversed)
    return p
}

func fillGradient(_ path: NSBezierPath, _ c1: NSColor, _ c2: NSColor, angle: CGFloat = 0) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: c1, ending: c2)!.draw(in: path.bounds, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 70
let tileRect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 200, yRadius: 200)
fillGradient(tile, color(0.19, 0.13, 0.07), color(0.07, 0.05, 0.03), angle: 90)

NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(colors: [color(0.95, 0.65, 0.25, 0.26), color(0.95, 0.65, 0.25, 0.0)])!
    .draw(in: tileRect, relativeCenterPosition: NSPoint(x: 0, y: 0.0))

// Back to front: body, screen, the four buttons, then the wheel with its centre
// button showing the body through.
let body = NSBezierPath(roundedRect: NSRect(x: 320, y: 190, width: 384, height: 644), xRadius: 72, yRadius: 72)
fillGradient(body, color(0.40, 0.25, 0.10), color(0.56, 0.36, 0.15), angle: 90)
let screen = NSBezierPath(roundedRect: NSRect(x: 362, y: 590, width: 300, height: 200), xRadius: 22, yRadius: 22)
fillGradient(screen, color(0.96, 0.70, 0.34), color(1.00, 0.93, 0.78), angle: 60)
for dx: CGFloat in [-105, -35, 35, 105] {
    color(0.92, 0.66, 0.32, 0.75).setFill()
    NSBezierPath(ovalIn: NSRect(x: C.x + dx - 14, y: 534, width: 28, height: 28)).fill()
}
fillGradient(ring(outer: 130, inner: 50), color(0.80, 0.54, 0.24), color(0.96, 0.76, 0.46), angle: 90)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path)")
