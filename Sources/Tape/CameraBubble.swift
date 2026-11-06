import AppKit
@preconcurrency import AVFoundation

/// A round, draggable, always-on-top camera preview. Because it's a real
/// window on screen, the screen recording picks it up, so there's no separate
/// camera track to composite.
@MainActor
final class CameraBubble {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tape.camera")
    private var panel: NSPanel?
    private var preview: AVCaptureVideoPreviewLayer?
    private var contentView: NSView?

    /// Shows the bubble inside `area` (global screen coordinates), unless the
    /// user already dragged it somewhere inside that area.
    func show(cameraID: String, shape: BubbleShape, inside area: CGRect) throws {
        guard let device = AVCaptureDevice(uniqueID: cameraID) else { return }
        let input = try AVCaptureDeviceInput(device: device)
        let s = session
        s.beginConfiguration()
        s.inputs.forEach { s.removeInput($0) }
        if s.canAddInput(input) { s.addInput(input) }
        if s.canSetSessionPreset(.high) { s.sessionPreset = .high }
        s.commitConfiguration()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        apply(shape, to: panel)
        if let connection = preview?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        if !area.contains(panel.frame) {
            panel.setFrameOrigin(NSPoint(x: area.minX + 24, y: area.minY + 24))
        }
        panel.orderFrontRegardless()
        sessionQueue.async { if !s.isRunning { s.startRunning() } }
    }

    func hide() {
        panel?.orderOut(nil)
        let s = session
        sessionQueue.async { s.stopRunning() }
    }

    /// Resizes the window for the shape, keeping its bottom-left corner put.
    private func apply(_ shape: BubbleShape, to panel: NSPanel) {
        let size = shape.size
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
        contentView?.layer?.cornerRadius = shape.cornerRadius
        panel.invalidateShadow()
    }

    private func makePanel() -> NSPanel {
        let frame = NSRect(origin: .zero, size: BubbleShape.circle.size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = DraggableView(frame: frame)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(preview)
        self.preview = preview

        panel.contentView = view
        contentView = view
        return panel
    }
}

private final class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

enum BubbleShape: String, CaseIterable {
    case roundedSquare, circle

    var title: String {
        switch self {
        case .circle: "Circle"
        case .roundedSquare: "Rounded Square"
        }
    }

    var size: NSSize {
        switch self {
        case .circle: NSSize(width: 200, height: 200)
        case .roundedSquare: NSSize(width: 220, height: 220)
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .circle: size.width / 2
        case .roundedSquare: 44
        }
    }
}
