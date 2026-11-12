@preconcurrency import AVFoundation
import AppKit

/// The link-preview image for a shared video: one frame with a play button,
/// as a JPEG of at most 1280 px wide.
enum Poster {
    static func jpeg(from video: URL) async -> Data? {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        // A little way in: the first frames are often the menu bar click.
        let time = CMTime(seconds: min(max(duration * 0.1, 0.5), 3, duration / 2), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time).image else { return nil }
        return draw(frame)
    }

    private static func draw(_ frame: CGImage) -> Data? {
        let w = frame.width, h = frame.height
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        cg.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Play button: a dark circle with a white triangle, sized to the frame.
        let d = CGFloat(min(w, h)) * 0.2
        let circle = CGRect(x: (CGFloat(w) - d) / 2, y: (CGFloat(h) - d) / 2, width: d, height: d)
        cg.setShadow(offset: .zero, blur: d * 0.15, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        cg.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        cg.fillEllipse(in: circle)
        cg.setShadow(offset: .zero, blur: 0)
        let t = d * 0.36
        let cx = circle.midX + t * 0.12, cy = circle.midY
        cg.setFillColor(NSColor.white.cgColor)
        cg.move(to: CGPoint(x: cx - t / 2, y: cy - t * 0.58))
        cg.addLine(to: CGPoint(x: cx - t / 2, y: cy + t * 0.58))
        cg.addLine(to: CGPoint(x: cx + t * 0.6, y: cy))
        cg.closePath()
        cg.fillPath()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
