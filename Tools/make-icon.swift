// Renders Nook's app icon (original artwork) to Resources/AppIcon.icns.
// Usage: swift Tools/make-icon.swift   (run from the package root)
import AppKit

let size: CGFloat = 1024

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824pt body centred, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()

    // Background: deep indigo to near-black.
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.19, blue: 0.42, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.12, alpha: 1)])!
        .draw(in: body, angle: -90)

    // Soft glow under the island.
    let glowCenter = NSPoint(x: body.midX, y: body.maxY - 300)
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.45, blue: 0.55, alpha: 0.55),
                        NSColor(srgbRed: 0.55, green: 0.35, blue: 1.0, alpha: 0.0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 420, options: [])

    // Top-edge "screen" sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.maxY - 220, width: body.width, height: 220), angle: -90)

    // The island: a black pill hanging from the top edge.
    let island = NSRect(x: body.midX - 290, y: body.maxY - 330, width: 580, height: 176)
    let pill = NSBezierPath(roundedRect: island, xRadius: 88, yRadius: 88)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    NSColor.black.setFill(); pill.fill()
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.10).setStroke()
    pill.lineWidth = 3; pill.stroke()

    // Artwork tile (left).
    let art = NSRect(x: island.minX + 44, y: island.midY - 46, width: 92, height: 92)
    let artPath = NSBezierPath(roundedRect: art, xRadius: 24, yRadius: 24)
    ctx.saveGState(); artPath.addClip()
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.62, blue: 0.25, alpha: 1),
                        NSColor(srgbRed: 0.95, green: 0.25, blue: 0.55, alpha: 1)])!.draw(in: art, angle: -45)
    ctx.restoreGState()

    // Equalizer bars (right).
    let heights: [CGFloat] = [46, 84, 60, 100, 52]
    let barW: CGFloat = 16, gap: CGFloat = 12
    var x = island.maxX - 52 - CGFloat(heights.count) * barW - CGFloat(heights.count - 1) * gap
    for h in heights {
        let r = NSRect(x: x, y: island.midY - h / 2, width: barW, height: h)
        let bar = NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2)
        ctx.saveGState(); bar.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.45, green: 0.95, blue: 0.85, alpha: 1),
                            NSColor(srgbRed: 0.45, green: 0.65, blue: 1.0, alpha: 1)])!.draw(in: r, angle: 90)
        ctx.restoreGState()
        x += barW + gap
    }

    // Three soft "content" rows below, hinting at the panels (tasks/notes).
    for (i, w) in [CGFloat(460), 360, 410].enumerated() {
        let y = island.minY - 120 - CGFloat(i) * 78
        let row = NSRect(x: body.midX - 230, y: y, width: w, height: 34)
        NSColor.white.withAlphaComponent(0.16 - CGFloat(i) * 0.04).setFill()
        NSBezierPath(roundedRect: row, xRadius: 17, yRadius: 17).fill()
    }
    ctx.restoreGState()

    // Hairline rim.
    NSColor.white.withAlphaComponent(0.12).setStroke()
    squircle.lineWidth = 2; squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = render().representation(using: .png, properties: [:])!
let masterURL = root.appendingPathComponent("docs/icon.png")
try! master.write(to: masterURL)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", masterURL.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
let ic = Process()
ic.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
ic.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! ic.run(); ic.waitUntilExit()
print(ic.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
