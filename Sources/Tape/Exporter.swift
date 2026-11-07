@preconcurrency import AVFoundation
import AppKit
import QuartzCore

enum ExportError: LocalizedError {
    case cannotExport

    var errorDescription: String? { "This video can't be exported." }
}

/// Renders the edited recording to an H.264 MP4 that plays anywhere,
/// optionally with the captions drawn into the picture.
enum Exporter {
    static func export(source: AVURLAsset, audio: AVURLAsset? = nil, timeline: Timeline, captions: [Caption],
                       burnCaptions: Bool, to output: URL,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let asset = try await timeline.editedAsset(from: source, audio: audio)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw ExportError.cannotExport }

        // Sped-up sections keep the voice's natural pitch.
        session.audioTimePitchAlgorithm = .spectral
        if burnCaptions, !captions.isEmpty {
            let video = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            video.animationTool = captionTool(captions, size: video.renderSize)
            session.videoComposition = video
        }

        try? FileManager.default.removeItem(at: output)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { await progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: .mp4)
    }

    /// Core Animation layers composited over the video: one caption box per
    /// line, visible only during its time.
    private static func captionTool(_ captions: [Caption], size: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let fontSize = (size.height * 0.042).rounded()
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let maxWidth = size.width * 0.8
        let padding = CGSize(width: fontSize * 0.6, height: fontSize * 0.35)

        for caption in captions {
            guard let image = captionImage(caption.text, font: font, maxWidth: maxWidth, padding: padding)
            else { continue }
            // Each caption is a pre-drawn image: CATextLayer draws nothing in
            // the offline export renderer.
            let layer = CALayer()
            layer.contents = image
            layer.frame = CGRect(x: ((size.width - CGFloat(image.width)) / 2).rounded(), y: (size.height * 0.07).rounded(),
                                 width: CGFloat(image.width), height: CGFloat(image.height))
            layer.opacity = 0

            // Shown from start to end, hidden otherwise. A begin time of 0
            // means "now" to Core Animation, so use the AVFoundation constant.
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = caption.start <= 0 ? AVCoreAnimationBeginTimeAtZero : caption.start
            show.duration = max(caption.end - caption.start, 0.1)
            show.isRemovedOnCompletion = true
            layer.add(show, forKey: "show")
            parent.addSublayer(layer)
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    /// White centered text on a rounded dark box, as a bitmap.
    private static func captionImage(_ text: String, font: NSFont, maxWidth: CGFloat, padding: CGSize) -> CGImage? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ])
        let textSize = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let width = Int(ceil(textSize.width + padding.width * 2))
        let height = Int(ceil(textSize.height + padding.height * 2))
        guard width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let box = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: font.pointSize * 0.3, yRadius: font.pointSize * 0.3).fill()
        string.draw(with: NSRect(x: padding.width, y: padding.height, width: ceil(textSize.width), height: ceil(textSize.height)),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
