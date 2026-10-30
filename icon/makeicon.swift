import AppKit

// Touchwheel app icon: same construction as the Crocus and Mekong icons (rounded
// dark tile, soft radial glow, layered gradient forms) in warm amber, drawn as
// the 3G iPod's touch wheel with a bright sweep where a thumb is turning it.

let S: CGFloat = 1024
let C = NSPoint(x: S / 2, y: S / 2)

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

/// An arc band around the centre whose thickness tapers to a point at both ends,
/// like the Mekong ribbons bent into a circle. Angles in degrees, anticlockwise.
func sweep(radius: CGFloat, thickness: CGFloat, from a0: CGFloat, to a1: CGFloat) -> NSBezierPath {
    let steps = 120
    var outer: [NSPoint] = [], inner: [NSPoint] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let a = (a0 + (a1 - a0) * t) * .pi / 180
        let h = thickness * (0.03 + 0.97 * sin(t * .pi)) / 2
        outer.append(NSPoint(x: C.x + (radius + h) * cos(a), y: C.y + (radius + h) * sin(a)))
        inner.append(NSPoint(x: C.x + (radius - h) * cos(a), y: C.y + (radius - h) * sin(a)))
    }
    let p = NSBezierPath()
    p.move(to: outer[0])
    outer.dropFirst().forEach { p.line(to: $0) }
    inner.reversed().forEach { p.line(to: $0) }
    p.close()
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

// Back to front: the wheel, its four button positions (Menu, Next, Play,
// Previous), the centre button, then the bright thumb sweep.
fillGradient(ring(outer: 290, inner: 150), color(0.36, 0.22, 0.09), color(0.50, 0.32, 0.13), angle: 90)
for a in stride(from: CGFloat(0), to: 360, by: 90) {
    let r = a * .pi / 180
    let p = NSPoint(x: C.x + 220 * cos(r), y: C.y + 220 * sin(r))
    color(0.80, 0.56, 0.26, 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)).fill()
}
fillGradient(circle(104), color(0.86, 0.58, 0.26), color(1.00, 0.84, 0.58), angle: 90)
fillGradient(sweep(radius: 220, thickness: 70, from: -40, to: 170),
             color(0.96, 0.68, 0.30), color(1.00, 0.93, 0.78), angle: 30)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path)")
