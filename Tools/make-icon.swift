// Draws Tape's app icon: a screen with a camera bubble in its corner.
// Usage: swift Tools/make-icon.swift <out.icns> [preview.png]
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let previewPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Tape-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)

    // Tile, with the standard macOS icon margin.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [color(44, 46, 58), color(16, 17, 24)])?.draw(in: tilePath, angle: -90)

    // The screen being recorded.
    let screen = NSRect(x: s * 0.22, y: s * 0.34, width: s * 0.58, height: s * 0.40)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.045, yRadius: s * 0.045)
    color(255, 255, 255, 0.10).setFill()
    screenPath.fill()
    color(255, 255, 255, 0.92).setStroke()
    screenPath.lineWidth = s * 0.03
    screenPath.stroke()

    // The camera bubble overlapping its bottom-left corner.
    let d = s * 0.30
    let bubble = NSRect(x: s * 0.16, y: s * 0.18, width: d, height: d)
    let ring = NSBezierPath(ovalIn: bubble.insetBy(dx: -s * 0.022, dy: -s * 0.022))
    color(16, 17, 24).setFill()
    ring.fill()
    let bubblePath = NSBezierPath(ovalIn: bubble)
    NSGradient(colors: [color(255, 94, 87), color(220, 38, 50)])?.draw(in: bubblePath, angle: -90)
    color(255, 255, 255, 0.92).setStroke()
    bubblePath.lineWidth = s * 0.018
    bubblePath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (size, name) in [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
] {
    guard let data = render(size: size) else { continue }
    try? data.write(to: iconset.appendingPathComponent(name))
}
if let previewPath { try? render(size: 512)?.write(to: URL(fileURLWithPath: previewPath)) }

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
