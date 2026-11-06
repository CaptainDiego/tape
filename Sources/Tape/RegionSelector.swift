import AppKit

/// Full-screen overlay on one display: drag to pick the area to record.
/// Calls back with the area in global screen coordinates, or nil on Esc.
@MainActor
final class RegionSelector {
    private var window: NSWindow?

    func select(on screen: NSScreen, completion: @escaping @MainActor (CGRect?) -> Void) {
        let window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.setFrame(screen.frame, display: false)

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] local in
            self?.window?.orderOut(nil)
            self?.window = nil
            completion(local.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) })
        }
        window.contentView = view
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var anchor: NSPoint?
    private var selection: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        // Ignore stray clicks and tiny drags; keep waiting for a real selection.
        guard let selection, selection.width >= 80, selection.height >= 80 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onFinish?(selection.integral)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
            label("\(Int(selection.width)) × \(Int(selection.height))",
                  at: NSPoint(x: selection.minX, y: selection.maxY + 6))
        } else {
            let text = "Drag to select the area to record  ·  Esc to cancel"
            let size = (text as NSString).size(withAttributes: Self.attributes)
            label(text, at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY))
        }
    }

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private func label(_ text: String, at point: NSPoint) {
        (text as NSString).draw(at: point, withAttributes: Self.attributes)
    }
}

/// Thin outline drawn just outside the recorded area, plus a 3-2-1 countdown
/// in the middle. It's excluded from the capture, and clicks pass through it
/// so the camera bubble can still be dragged.
@MainActor
final class RecordingFrame {
    private var window: NSWindow?
    private var view: FrameView?

    var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

    func show(around area: CGRect) {
        let frame = area.insetBy(dx: -4, dy: -4)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = FrameView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        self.view = view
    }

    func countdown(from seconds: Int) async {
        for n in stride(from: seconds, through: 1, by: -1) {
            view?.count = n
            try? await Task.sleep(for: .seconds(1))
        }
        view?.count = nil
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        view = nil
    }
}

private final class FrameView: NSView {
    var count: Int? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()

        guard let count else { return }
        let circle = NSRect(x: bounds.midX - 60, y: bounds.midY - 60, width: 120, height: 120)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let text = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                  withAttributes: attributes)
    }
}
