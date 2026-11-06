import AppKit
import AVKit

/// The window a recording opens in: the video with captions on the left and
/// the transcript on the right. Clicking a word jumps there. Editing comes next.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    private static var openEditors: [EditorWindow] = []

    private let file: URL
    private let window: NSWindow
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let caption = CaptionLabel()
    private let transcriptView = TranscriptTextView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let captionsToggle = NSButton(checkboxWithTitle: "Captions", target: nil, action: nil)

    private var transcript: Transcript?
    private var segments: [Range<Int>] = []
    private var segmentOfWord: [Int] = []
    private var wordRanges: [NSRange] = []
    private var highlighted: Int?
    private var timeObserver: Any?

    static func open(_ file: URL) {
        if let existing = openEditors.first(where: { $0.file == file }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let editor = EditorWindow(file: file)
        openEditors.append(editor)
        // Show in the Dock and app switcher while a recording is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        editor.window.makeKeyAndOrderFront(nil)
        editor.loadTranscript()
    }

    private init(file: URL) {
        self.file = file
        player = AVPlayer(url: file)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = file.deletingPathExtension().lastPathComponent
        window.representedURL = file
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 400)
        buildLayout()
        window.center()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playheadMoved(to: time.seconds) }
        }
    }

    // MARK: Layout

    private func buildLayout() {
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true

        // Captions sit on top of the video, above the playback controls.
        if let overlay = playerView.contentOverlayView {
            caption.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(caption)
            NSLayoutConstraint.activate([
                caption.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                caption.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -72),
                caption.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.85),
            ])
        }

        transcriptView.isEditable = false
        transcriptView.isSelectable = false
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 16, height: 12)
        transcriptView.onClickWord = { [weak self] index in self?.seek(toWord: index) }
        let scroll = NSScrollView()
        scroll.documentView = transcriptView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.isVerticallyResizable = true
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.minSize = NSSize(width: 0, height: 0)
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.frame = NSRect(origin: .zero, size: scroll.contentSize)

        let title = NSTextField(labelWithString: "Transcript")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        captionsToggle.state = .on
        captionsToggle.target = self
        captionsToggle.action = #selector(toggleCaptions)
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 4

        let header = NSStackView(views: [title, NSView(), captionsToggle])
        let statusRow = NSStackView(views: [spinner, status, retryButton])
        statusRow.alignment = .centerY
        let sidebar = NSStackView(views: [header, statusRow, scroll])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 0, right: 12)
        header.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -24).isActive = true
        scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: sidebar.widthAnchor, constant: -24).isActive = true
        sidebar.setHuggingPriority(.defaultLow, for: .vertical)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(playerView)
        split.addArrangedSubview(sidebar)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        window.contentView = split
        split.setPosition(window.frame.width - 360, ofDividerAt: 0)
    }

    // MARK: Transcript

    private func loadTranscript() {
        if let saved = Transcript.load(for: file) {
            show(saved)
            return
        }
        setStatus("Transcribing with Parakeet…", busy: true)
        let file = self.file
        Task {
            do {
                let transcript = try await Transcriber.shared.transcribe(file)
                try? transcript.save(for: file)
                show(transcript)
            } catch {
                setStatus("Couldn't transcribe: \(error.localizedDescription)", busy: false, canRetry: true)
            }
        }
    }

    @objc private func retry() {
        try? FileManager.default.removeItem(at: Transcript.sidecarURL(for: file))
        loadTranscript()
    }

    private func setStatus(_ text: String?, busy: Bool, canRetry: Bool = false) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !busy
        retryButton.isHidden = !canRetry
    }

    private func show(_ transcript: Transcript) {
        self.transcript = transcript
        segments = transcript.segments
        highlighted = nil
        if transcript.words.isEmpty {
            setStatus("No speech found in this recording.", busy: false, canRetry: true)
        } else {
            setStatus(nil, busy: false)
        }

        // One paragraph per caption line, each starting with its timestamp.
        let text = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        paragraph.lineHeightMultiple = 1.15
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let stamp: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
        ]

        wordRanges = Array(repeating: NSRange(location: 0, length: 0), count: transcript.words.count)
        segmentOfWord = Array(repeating: 0, count: transcript.words.count)
        for (s, segment) in segments.enumerated() {
            text.append(NSAttributedString(string: Self.timestamp(transcript.words[segment.lowerBound].start) + "   ",
                                           attributes: stamp))
            for i in segment {
                var attributes = body
                attributes[.wordIndex] = i
                wordRanges[i] = NSRange(location: text.length, length: (transcript.words[i].text as NSString).length)
                segmentOfWord[i] = s
                text.append(NSAttributedString(string: transcript.words[i].text, attributes: attributes))
                text.append(NSAttributedString(string: i == segment.upperBound - 1 ? "\n" : " ", attributes: body))
            }
        }
        transcriptView.textStorage?.setAttributedString(text)
        playheadMoved(to: player.currentTime().seconds)
    }

    private func seek(toWord index: Int) {
        guard let word = transcript?.words[index] else { return }
        player.seek(to: CMTime(seconds: word.start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Playback

    private func playheadMoved(to time: TimeInterval) {
        guard let transcript, !transcript.words.isEmpty, time.isFinite else {
            caption.text = nil
            return
        }
        // Treat the word as current until shortly after it ends.
        var current = transcript.wordIndex(at: time)
        if let i = current, time > transcript.words[i].end + 0.6 { current = nil }

        if current != highlighted, let storage = transcriptView.textStorage {
            storage.beginEditing()
            if let old = highlighted { storage.removeAttribute(.backgroundColor, range: wordRanges[old]) }
            if let new = current {
                storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.3),
                                     range: wordRanges[new])
                if player.rate != 0 { transcriptView.scrollRangeToVisible(wordRanges[new]) }
            }
            storage.endEditing()
            highlighted = current
        }

        if let current, captionsToggle.state == .on {
            let segment = segments[segmentOfWord[current]]
            caption.text = transcript.words[segment].map(\.text).joined(separator: " ")
        } else {
            caption.text = nil
        }
    }

    @objc private func toggleCaptions() {
        playheadMoved(to: player.currentTime().seconds)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        Self.openEditors.removeAll { $0 === self }
        if Self.openEditors.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

extension NSAttributedString.Key {
    static let wordIndex = NSAttributedString.Key("TapeWordIndex")
}

/// Transcript text where clicking a word reports its index.
private final class TranscriptTextView: NSTextView {
    var onClickWord: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard let storage = textStorage, storage.length > 0 else { return }
        let i = min(max(index, 0), storage.length - 1)
        if let word = storage.attribute(.wordIndex, at: i, effectiveRange: nil) as? Int {
            onClickWord?(word)
        } else if i > 0, let word = storage.attribute(.wordIndex, at: i - 1, effectiveRange: nil) as? Int {
            onClickWord?(word)
        }
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }
}

/// White text on a dark rounded backdrop, like TV captions.
private final class CaptionLabel: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    var text: String? {
        didSet {
            label.stringValue = text ?? ""
            isHidden = (text ?? "").isEmpty
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
