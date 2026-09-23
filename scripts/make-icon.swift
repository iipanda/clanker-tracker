// Renders AppIcon.icns: a dark rounded square with a purple ring gauge, matching the menu bar icon.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
let iconset = out.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.13, blue: 0.26, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.07, blue: 0.11, alpha: 1))!.draw(in: shape, angle: -60)

    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = body.width * 0.29
    let width = body.width * 0.1
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    NSColor.white.withAlphaComponent(0.16).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * 0.72, clockwise: true)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.64, green: 0.48, blue: 1, alpha: 1).setStroke()
    arc.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appending(path: "AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
