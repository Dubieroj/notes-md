// Draws the app icon (a Notes-style page: yellow band, ruled paper, the Markdown mark)
// into Resources/AppIcon.icns, plus PNG copies for the README and the example document.
// Run from the project folder: swift tools/make-icon.swift
// The Markdown mark is by Dustin Curtis, dedicated to the public domain (CC0).
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    let paper = NSColor(srgbRed: 0.995, green: 0.985, blue: 0.955, alpha: 1).cgColor
    let yellow = NSColor(srgbRed: 0.99, green: 0.78, blue: 0.20, alpha: 1).cgColor
    let rule = NSColor(srgbRed: 0.86, green: 0.84, blue: 0.80, alpha: 1).cgColor
    let ink = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).cgColor

    // Tile on the macOS icon grid: 824 pt body, soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.setFillColor(paper)
    ctx.addPath(tilePath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // The yellow band of a notepad, with its perforation.
    ctx.setFillColor(yellow)
    ctx.fill(CGRect(x: 100, y: 740, width: 824, height: 184))
    ctx.setFillColor(rule)
    for i in 0..<15 {
        ctx.fillEllipse(in: CGRect(x: 136 + CGFloat(i) * 54, y: 706, width: 16, height: 16))
    }
    // Ruled lines.
    ctx.setStrokeColor(rule)
    ctx.setLineWidth(6)
    for y in stride(from: 640, through: 160, by: -96) {
        ctx.move(to: CGPoint(x: 100, y: y))
        ctx.addLine(to: CGPoint(x: 924, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // The Markdown mark (M↓), from its 208×128 SVG with y pointing down.
    let s: CGFloat = 2.6, ox: CGFloat = 512 - 104 * s, oy: CGFloat = 418 - 64 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + (128 - y) * s) }
    let frame = CGPath(roundedRect: CGRect(x: ox + 5 * s, y: oy + 5 * s, width: 198 * s, height: 118 * s),
                       cornerWidth: 15 * s, cornerHeight: 15 * s, transform: nil)
    ctx.setFillColor(paper)
    ctx.addPath(frame)
    ctx.fillPath()
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(10 * s)
    ctx.addPath(frame)
    ctx.strokePath()
    let glyphs = CGMutablePath()
    glyphs.addLines(between: [p(30, 98), p(30, 30), p(50, 30), p(70, 55), p(90, 30), p(110, 30),
                              p(110, 98), p(90, 98), p(90, 59), p(70, 84), p(50, 59), p(50, 98)])
    glyphs.closeSubpath()
    glyphs.addLines(between: [p(155, 98), p(125, 65), p(145, 65), p(145, 30), p(165, 30), p(165, 65), p(185, 65)])
    glyphs.closeSubpath()
    ctx.setFillColor(ink)
    ctx.addPath(glyphs)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ size: CGFloat) -> Data { drawIcon(size: size).representation(using: .png, properties: [:])! }

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(CGFloat(base * scale)).write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try png(512).write(to: URL(fileURLWithPath: "docs/icon.png"))
try png(256).write(to: URL(fileURLWithPath: "examples/icon.png"))
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
