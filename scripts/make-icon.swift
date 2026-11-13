// Renders the Murmur app icon (macOS 26 icon grid) to an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.098, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.27, blue: 0.96, alpha: 1),
                        NSColor(srgbRed: 0.72, green: 0.30, blue: 0.92, alpha: 1),
                        NSColor(srgbRed: 1.00, green: 0.47, blue: 0.47, alpha: 1)])!.draw(in: body, angle: -55)
    // Soft top light.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    let heights: [CGFloat] = [0.26, 0.46, 0.72, 0.46, 0.26]
    let barW = body.width * 0.085, gap = body.width * 0.062
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    let glow = NSShadow(); glow.shadowColor = NSColor.white.withAlphaComponent(0.55); glow.shadowBlurRadius = s * 0.02
    glow.set()
    NSColor.white.setFill()
    for h in heights {
        let bh = body.height * h
        NSBezierPath(roundedRect: NSRect(x: x, y: body.midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    // Hairline edge.
    NSColor.white.withAlphaComponent(0.18).setStroke(); path.lineWidth = max(1, s * 0.004); path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
