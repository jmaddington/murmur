// Renders installer artwork: the DMG window background and the PKG sidebar art.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func png(_ w: Int, _ h: Int, scale: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [.compressionFactor: 1])!
}

let violet = NSColor(srgbRed: 0.36, green: 0.30, blue: 0.98, alpha: 1)
let orchid = NSColor(srgbRed: 0.73, green: 0.32, blue: 0.93, alpha: 1)
let coral = NSColor(srgbRed: 1.00, green: 0.45, blue: 0.48, alpha: 1)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: CGPoint) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
    let a = NSAttributedString(string: s, attributes: attrs)
    let sz = a.size()
    a.draw(in: CGRect(x: center.x - 300, y: center.y - sz.height / 2, width: 600, height: sz.height))
}

func waveMark(center: CGPoint, height: CGFloat, color: NSColor) {
    let hs: [CGFloat] = [0.3, 0.55, 0.85, 1.0, 0.85, 0.55, 0.3]
    let w = height * 0.09, gap = height * 0.07
    var x = center.x - (CGFloat(hs.count) * w + CGFloat(hs.count - 1) * gap) / 2
    color.setFill()
    for h in hs {
        let bh = height * h
        NSBezierPath(roundedRect: CGRect(x: x, y: center.y - bh / 2, width: w, height: bh), xRadius: w / 2, yRadius: w / 2).fill()
        x += w + gap
    }
}

// DMG background, 660×420 (window), icons at (178,196) and (482,196) from top-left.
func dmg(_ r: CGRect) {
    NSColor(srgbRed: 0.985, green: 0.98, blue: 1.0, alpha: 1).setFill(); r.fill()
    // Soft brand aurora along the top.
    NSGradient(colors: [violet.withAlphaComponent(0.18), orchid.withAlphaComponent(0.12), coral.withAlphaComponent(0.14)])!
        .draw(in: NSBezierPath(ovalIn: CGRect(x: -120, y: r.height - 170, width: r.width + 240, height: 300)), angle: 0)
    text("Install Murmur", size: 22, weight: .bold, color: NSColor(white: 0.1, alpha: 1), center: CGPoint(x: r.midX, y: r.height - 58))
    text("Drag the icon into Applications", size: 13, weight: .regular, color: NSColor(white: 0.45, alpha: 1), center: CGPoint(x: r.midX, y: r.height - 84))
    // Arrow between the icons (icon centres at y = 420 − 196).
    let y = r.height - 196
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 262, y: y)); arrow.line(to: CGPoint(x: 392, y: y))
    arrow.lineWidth = 3; arrow.lineCapStyle = .round
    let dash: [CGFloat] = [0.1, 9]; arrow.setLineDash(dash, count: 2, phase: 0)
    violet.withAlphaComponent(0.55).setStroke(); arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: 386, y: y + 9)); head.line(to: CGPoint(x: 398, y: y)); head.line(to: CGPoint(x: 386, y: y - 9))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()
    text("Hold fn to talk · release to type", size: 11.5, weight: .medium, color: NSColor(white: 0.55, alpha: 1), center: CGPoint(x: r.midX, y: 38))
}

// PKG sidebar art (Installer shows it bottom-left behind the pane).
func pkg(_ r: CGRect, dark: Bool) {
    let grad = NSGradient(colors: [violet, orchid, coral])!
    let glow = NSBezierPath(ovalIn: CGRect(x: -160, y: -140, width: 420, height: 420))
    NSGraphicsContext.saveGraphicsState()
    glow.addClip()
    grad.draw(in: glow, angle: 50)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: dark ? 0.12 : 1, alpha: 0.0).setFill()
    waveMark(center: CGPoint(x: 70, y: 82), height: 70, color: .white)
}

try! png(660, 420, scale: 1, dmg).write(to: URL(fileURLWithPath: "\(out)/dmg-background.png"))
try! png(660, 420, scale: 2, dmg).write(to: URL(fileURLWithPath: "\(out)/dmg-background@2x.png"))
try! png(260, 260, scale: 2, { pkg($0, dark: false) }).write(to: URL(fileURLWithPath: "\(out)/pkg-background.png"))
try! png(260, 260, scale: 2, { pkg($0, dark: true) }).write(to: URL(fileURLWithPath: "\(out)/pkg-background-dark.png"))
