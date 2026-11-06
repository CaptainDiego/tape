@preconcurrency import AVFoundation
import AppKit

/// An iPhone-style trim bar: a strip of thumbnails with a yellow frame whose
/// two handles you drag to trim the start and end. Parts cut from the
/// transcript show as darkened stripes. Clicking or dragging elsewhere scrubs.
/// All times are in the original recording ("source" time).
@MainActor
final class TrimBar: NSView {
    var duration: TimeInterval = 0 { didSet { needsDisplay = true } }
    var trimStart: TimeInterval = 0 { didSet { needsDisplay = true } }
    var trimEnd: TimeInterval = 0 { didSet { needsDisplay = true } }
    var cuts: [ClosedRange<TimeInterval>] = [] { didSet { needsDisplay = true } }
    var playhead: TimeInterval = 0 { didSet { if oldValue != playhead { needsDisplay = true } } }

    /// Called once when the user lets go of a handle.
    var onTrim: ((TimeInterval, TimeInterval) -> Void)?
    var onScrub: ((TimeInterval) -> Void)?

    private var thumbnails: [NSImage] = []
    private var dragging: Handle?
    private enum Handle { case start, end, scrub }

    private let handleWidth: CGFloat = 14
    private let minimumLength: TimeInterval = 0.5

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 52) }

    func loadThumbnails(from asset: AVURLAsset) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        Task {
            guard let length = try? await asset.load(.duration).seconds, length > 0 else { return }
            var images: [NSImage] = []
            let count = 14
            for i in 0..<count {
                let time = CMTime(seconds: length * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                if let frame = try? await generator.image(at: time).image {
                    images.append(NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)))
                }
            }
            thumbnails = images
            needsDisplay = true
        }
    }

    // MARK: Geometry

    /// The strip between the two handle columns.
    private var track: NSRect {
        bounds.insetBy(dx: handleWidth, dy: 4)
    }

    private func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return track.minX }
        return track.minX + track.width * CGFloat(min(max(time / duration, 0), 1))
    }

    private func time(for x: CGFloat) -> TimeInterval {
        guard track.width > 0 else { return 0 }
        return duration * Double(min(max((x - track.minX) / track.width, 0), 1))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let strip = track
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: strip, xRadius: 4, yRadius: 4).addClip()
        NSColor.black.setFill()
        strip.fill()
        if !thumbnails.isEmpty {
            let width = strip.width / CGFloat(thumbnails.count)
            for (i, image) in thumbnails.enumerated() {
                let cell = NSRect(x: strip.minX + CGFloat(i) * width, y: strip.minY, width: width, height: strip.height)
                drawFill(image, in: cell)
            }
        }

        // Cuts from the transcript: dark with a red tint.
        for cut in cuts {
            let r = NSRect(x: x(for: cut.lowerBound), y: strip.minY,
                           width: max(x(for: cut.upperBound) - x(for: cut.lowerBound), 1), height: strip.height)
            NSColor.black.withAlphaComponent(0.65).setFill()
            r.fill()
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            r.fill()
        }

        // Trimmed-off ends.
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSRect(x: strip.minX, y: strip.minY, width: x(for: trimStart) - strip.minX, height: strip.height).fill()
        NSRect(x: x(for: trimEnd), y: strip.minY, width: strip.maxX - x(for: trimEnd), height: strip.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Yellow frame with a handle on each side.
        let left = x(for: trimStart), right = x(for: trimEnd)
        let frame = NSRect(x: left - handleWidth, y: bounds.minY + 1, width: right - left + handleWidth * 2,
                           height: bounds.height - 2)
        NSColor.systemYellow.setFill()
        let outer = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        outer.append(NSBezierPath(rect: NSRect(x: left, y: frame.minY + 3, width: right - left, height: frame.height - 6)).reversed)
        outer.fill()
        for handleX in [left - handleWidth / 2, right + handleWidth / 2] {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: handleX - 1.5, y: frame.midY - 8, width: 3, height: 16),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Playhead.
        let px = x(for: playhead)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: px - 1.5, y: bounds.minY, width: 3, height: bounds.height),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// Draws the image scaled to fill `rect`, cropping the overflow.
    private func drawFill(_ image: NSImage, in rect: NSRect) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse

    override func resetCursorRects() {
        for handleX in [x(for: trimStart) - handleWidth, x(for: trimEnd)] {
            addCursorRect(NSRect(x: handleX, y: 0, width: handleWidth, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - (x(for: trimStart) - handleWidth / 2)) <= handleWidth {
            dragging = .start
        } else if abs(point.x - (x(for: trimEnd) + handleWidth / 2)) <= handleWidth {
            dragging = .end
        } else {
            dragging = .scrub
            onScrub?(time(for: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch dragging {
        case .start:
            trimStart = min(max(time(for: point.x + handleWidth / 2), 0), trimEnd - minimumLength)
        case .end:
            trimEnd = max(min(time(for: point.x - handleWidth / 2), duration), trimStart + minimumLength)
        case .scrub:
            onScrub?(time(for: point.x))
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging == .start || dragging == .end {
            onTrim?(trimStart, trimEnd)
            window?.invalidateCursorRects(for: self)
        }
        dragging = nil
    }
}
