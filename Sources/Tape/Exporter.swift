@preconcurrency import AVFoundation
import AppKit
import CoreImage

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
            let size = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset).renderSize
            let overlays = captionOverlays(captions, size: size)
            // Each frame gets the caption for its own time drawn on top. This
            // doesn't depend on Core Animation timing, which dropped the
            // captions when exporting from inside the running app.
            session.videoComposition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                let t = request.compositionTime.seconds
                var frame = request.sourceImage
                if let overlay = overlays.first(where: { t >= $0.start && t < $0.end }) {
                    frame = overlay.image.composited(over: frame)
                }
                request.finish(with: frame, context: nil)
            }
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

    struct Overlay: @unchecked Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let image: CIImage
    }

    /// One pre-drawn caption box per line, already placed near the bottom
    /// centre of the frame (Core Image's origin is bottom-left).
    private static func captionOverlays(_ captions: [Caption], size: CGSize) -> [Overlay] {
        let fontSize = (size.height * 0.042).rounded()
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let maxWidth = size.width * 0.8
        let padding = CGSize(width: fontSize * 0.6, height: fontSize * 0.35)

        return captions.compactMap { caption in
            guard let image = captionImage(caption.text, font: font, maxWidth: maxWidth, padding: padding)
            else { return nil }
            let x = ((size.width - CGFloat(image.width)) / 2).rounded()
            let y = (size.height * 0.07).rounded()
            return Overlay(start: caption.start, end: caption.end,
                           image: CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: x, y: y)))
        }
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
