// Renders the app icon (1024 px) into an .iconset and converts it with iconutil.
import AppKit

let out = CommandLine.arguments[1]
func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1), NSColor(red: 0.04, green: 0.045, blue: 0.06, alpha: 1)])!
        .draw(in: shape, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    shape.addClip()
    // Spectrum bars
    let bars = 15
    let barArea = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.24)
    let w = barArea.width / CGFloat(bars)
    for i in 0..<bars {
        let t = CGFloat(i) / CGFloat(bars - 1)
        let h = barArea.height * (0.18 + 0.82 * pow(sin(t * .pi), 1.6) * (0.75 + 0.25 * sin(t * 13)))
        let bar = NSRect(x: barArea.minX + CGFloat(i) * w + w * 0.18, y: barArea.midY - h / 2, width: w * 0.64, height: h)
        NSGradient(colors: [NSColor(red: 0.3, green: 0.85, blue: 1, alpha: 1), NSColor(red: 0.2, green: 0.4, blue: 1, alpha: 1)])!
            .draw(in: NSBezierPath(roundedRect: bar, xRadius: w * 0.32, yRadius: w * 0.32), angle: 90)
    }
    // Record dot
    let d = rect.width * 0.17
    let dot = NSRect(x: rect.maxX - d * 1.45, y: rect.maxY - d * 1.45, width: d, height: d)
    NSGradient(colors: [NSColor(red: 1, green: 0.35, blue: 0.3, alpha: 1), NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: dot), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let fm = FileManager.default
try? fm.removeItem(atPath: out); try! fm.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = render(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
