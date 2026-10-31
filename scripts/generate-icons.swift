#!/usr/bin/env swift
import AppKit

// Original vector artwork; regenerate with: swift scripts/generate-icons.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBar-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}
func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat) {
    color.setStroke(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
}
func mark(in rect: NSRect, monochrome: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current!.cgContext.translateBy(x: rect.minX, y: rect.minY)
    NSGraphicsContext.current!.cgContext.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
    let light = monochrome ? NSColor.black : color(0.82, 0.98, 0.92)
    let mint = monochrome ? NSColor.black : color(0.39, 0.88, 0.72)
    let orange = monochrome ? NSColor.black : color(1.0, 0.66, 0.43)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: NSPoint(x: 512, y: 532), radius: 254, startAngle: -38, endAngle: 218, clockwise: false)
    stroke(ring, monochrome ? light : light.withAlphaComponent(0.22), width: 56)
    let progress = NSBezierPath()
    progress.appendArc(withCenter: NSPoint(x: 512, y: 532), radius: 254, startAngle: 218, endAngle: 62, clockwise: true)
    stroke(progress, mint, width: 56)
    let last = NSBezierPath()
    last.appendArc(withCenter: NSPoint(x: 512, y: 532), radius: 254, startAngle: 49, endAngle: -38, clockwise: true)
    stroke(last, orange, width: 56)
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: 512, y: 532)); needle.line(to: NSPoint(x: 642, y: 670))
    stroke(needle, light, width: 48)
    light.setFill(); NSBezierPath(ovalIn: NSRect(x: 478, y: 498, width: 68, height: 68)).fill()
    for (x, height, shade) in [(CGFloat(342), CGFloat(78), mint), (CGFloat(472), CGFloat(128), light), (CGFloat(602), CGFloat(184), orange)] {
        shade.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 252, width: 80, height: height), xRadius: 24, yRadius: 24).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}
func drawIcon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.24); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); color(0.04, 0.16, 0.17).setFill(); tile.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.04, 0.14, 0.16), ending: color(0.09, 0.32, 0.31))!.draw(in: tile, angle: 70)
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let shine = NSBezierPath(ovalIn: NSRect(x: -100, y: 610, width: 1050, height: 650))
    NSGradient(starting: .white.withAlphaComponent(0.075), ending: .clear)!.draw(in: shine, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    stroke(tile, .white.withAlphaComponent(0.14), width: 2)
    mark(in: NSRect(x: 18, y: -4, width: 988, height: 988))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let bitmap = drawIcon(size: pointSize * scale)
        let name = "icon_\(pointSize)x\(pointSize)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("AppIcon.png"))
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit(); guard task.terminationStatus == 0 else { fputs("iconutil failed\n", stderr); exit(1) }
final class MenuMarkView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / 584
        mark(in: NSRect(x: -220 * scale, y: -240 * scale, width: 1024 * scale, height: 1024 * scale), monochrome: true)
    }
}
let view = MenuMarkView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
try view.dataWithPDF(inside: view.bounds).write(to: output.appendingPathComponent("MenuBarTemplate.pdf"))
print("Generated AppIcon.icns, AppIcon.png and MenuBarTemplate.pdf")
