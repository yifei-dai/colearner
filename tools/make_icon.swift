// Draws the app icon (a slide with a chat bubble) and writes Resources/AppIcon.icns.
// Run: swift tools/make_icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: tile, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(starting: NSColor(red: 0.19, green: 0.42, blue: 0.86, alpha: 1),
               ending: NSColor(red: 0.11, green: 0.24, blue: 0.55, alpha: 1))!.draw(in: bg, angle: -90)
    // the slide
    let slide = NSRect(x: s * 0.18, y: s * 0.38, width: s * 0.50, height: s * 0.36)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: slide, xRadius: s * 0.03, yRadius: s * 0.03).fill()
    NSColor(red: 0.19, green: 0.42, blue: 0.86, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: slide.minX + s * 0.05, y: slide.maxY - s * 0.09, width: s * 0.28, height: s * 0.035)).fill()
    NSColor(white: 0.75, alpha: 1).setFill()
    for i in 0..<3 {
        NSBezierPath(rect: NSRect(x: slide.minX + s * 0.05, y: slide.maxY - s * (0.16 + 0.055 * CGFloat(i)), width: s * (0.36 - 0.06 * CGFloat(i)), height: s * 0.022)).fill()
    }
    // the chat bubble
    let bubble = NSRect(x: s * 0.46, y: s * 0.20, width: s * 0.36, height: s * 0.27)
    let b = NSBezierPath(roundedRect: bubble, xRadius: s * 0.07, yRadius: s * 0.07)
    b.move(to: NSPoint(x: bubble.minX + s * 0.08, y: bubble.minY + s * 0.02))
    b.line(to: NSPoint(x: bubble.minX + s * 0.02, y: bubble.minY - s * 0.06))
    b.line(to: NSPoint(x: bubble.minX + s * 0.17, y: bubble.minY + s * 0.01))
    NSColor(red: 0.98, green: 0.62, blue: 0.20, alpha: 1).setFill()
    b.fill()
    NSColor.white.setFill()
    for i in 0..<3 {
        let d = s * 0.045
        NSBezierPath(ovalIn: NSRect(x: bubble.midX - d * 2.2 + CGFloat(i) * d * 1.6, y: bubble.midY - d / 2, width: d, height: d)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("icon written, status \(p.terminationStatus)")
try! draw(512).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
