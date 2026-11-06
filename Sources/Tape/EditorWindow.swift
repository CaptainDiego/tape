@preconcurrency import AVFoundation
import AVKit
import AppKit

/// The window a recording opens in: the video with captions and a trim bar
/// on the left, and the editable transcript on the right.
///
/// Editing is non-destructive. Deleting words or dragging the trim handles
/// only changes the saved `Edits`; playback and export skip the cut parts.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    private static var openEditors: [EditorWindow] = []

    private let file: URL
    private let asset: AVURLAsset
    private let window: NSWindow
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let captionView = CaptionLabel()
    private let trimBar = TrimBar()
    private let transcriptView = TranscriptTextView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let captionsToggle = NSButton(checkboxWithTitle: "Captions", target: nil, action: nil)
    private let fillersButton = NSButton(title: "Remove Fillers", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore All", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let cutButton = NSButton(title: "Cut Section", target: nil, action: nil)
    private var editPopover: NSPopover?
    private var editingWords: [Int] = []

    private var transcript: Transcript?
    private var segments: [Range<Int>] = []
    /// Where each visible word sits in the transcript text.
    private var wordRanges: [Int: NSRange] = [:]
    private var edits: Edits
    private var undoStack: [Edits] = []
    private var sourceDuration: TimeInterval?
    private var timeline: Timeline?
    private var captions: [Caption] = []
    private var itemGeneration = 0
    private var highlighted: Int?
    private var timeObserver: Any?
    private var onAction: (() -> Void)?
    private var exporting = false

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
        editor.window.makeFirstResponder(editor.transcriptView)
        editor.load()
    }

    private init(file: URL) {
        self.file = file
        asset = AVURLAsset(url: file)
        edits = Edits.load(for: file)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = file.deletingPathExtension().lastPathComponent
        window.representedURL = file
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 800, height: 460)
        buildLayout()
        window.center()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playheadMoved(to: time.seconds) }
        }
    }

    // MARK: Layout

    private func buildLayout() {
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        if let overlay = playerView.contentOverlayView {
            captionView.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(captionView)
            NSLayoutConstraint.activate([
                captionView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                captionView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -72),
                captionView.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.85),
            ])
        }

        trimBar.onScrub = { [weak self] source in self?.seek(toSource: source) }
        trimBar.onTrim = { [weak self] start, end in
            guard let self, let duration = self.sourceDuration else { return }
            var new = self.edits
            new.trimStart = start > 0.01 ? start : nil
            new.trimEnd = end < duration - 0.01 ? end : nil
            self.apply(new)
        }
        trimBar.onClick = { [weak self] source in self?.selectCut(at: source) }
        trimBar.onSelectionChange = { [weak self] _ in self?.updateButtons() }
        trimBar.onDelete = { [weak self] in self?.cutOrRestoreSelection() }
        trimBar.onPlayPause = { [weak self] in self?.playPause() }
        let trimHint = Self.hint("Drag the yellow handles to trim the ends. Drag across the strip to select a section "
                                 + "and press Delete to cut it. Click a red section to select it and restore it.")
        trimHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trimRow = NSStackView(views: [trimHint, cutButton])
        trimRow.alignment = .top
        let left = NSStackView(views: [playerView, trimBar, trimRow])
        left.orientation = .vertical
        left.spacing = 6
        left.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        trimBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.widthAnchor.constraint(equalTo: left.widthAnchor),
            trimBar.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            trimBar.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            trimBar.heightAnchor.constraint(equalToConstant: 52),
            trimRow.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            trimRow.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
        ])
        playerView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Transcript sidebar.
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 14, height: 12)
        transcriptView.onClickWord = { [weak self] i in self?.seek(toWord: i) }
        transcriptView.onDelete = { [weak self] words in self?.toggleDeleted(words) }
        transcriptView.onUndo = { [weak self] in self?.undo() }
        transcriptView.onRestore = { [weak self] words in self?.restore(words) }
        transcriptView.onEdit = { [weak self] words in self?.editWords(words) }
        transcriptView.onPlayPause = { [weak self] in self?.playPause() }
        let scroll = NSScrollView()
        scroll.documentView = transcriptView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        transcriptView.minSize = .zero
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.isVerticallyResizable = true
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.frame = NSRect(origin: .zero, size: scroll.contentSize)

        let title = NSTextField(labelWithString: "Transcript")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        captionsToggle.state = .on
        for (button, action) in [(captionsToggle, #selector(toggleCaptions)), (fillersButton, #selector(removeFillers)),
                                 (undoButton, #selector(undoClicked)), (restoreButton, #selector(restoreAll)),
                                 (exportButton, #selector(exportClicked)), (actionButton, #selector(actionClicked)),
                                 (cutButton, #selector(cutOrRestoreSelection))] {
            button.target = self
            button.action = action
        }
        for button in [fillersButton, undoButton, restoreButton, exportButton, actionButton, cutButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        exportButton.keyEquivalent = "e"
        exportButton.keyEquivalentModifierMask = .command
        actionButton.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 5
        status.preferredMaxLayoutWidth = 300

        let header = NSStackView(views: [title, NSView(), captionsToggle, exportButton])
        let tools = NSStackView(views: [fillersButton, undoButton, restoreButton])
        let editHint = Self.hint("Click a word to jump to it. Select words (double-click selects one) and press Delete to "
                                + "cut them; click ✂︎ to bring them back. Press Return or right-click to fix a caption. "
                                + "Space plays and pauses.")
        let statusRow = NSStackView(views: [spinner, status, actionButton])
        statusRow.alignment = .centerY
        let sidebar = NSStackView(views: [header, tools, editHint, statusRow, scroll])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 0, right: 12)
        header.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -24).isActive = true
        scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(sidebar)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        window.contentView = split
        split.setPosition(window.frame.width - 380, ofDividerAt: 0)
        updateButtons()
    }

    private static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    // MARK: Loading

    private func load() {
        trimBar.loadThumbnails(from: asset)
        Task {
            sourceDuration = (try? await asset.load(.duration).seconds) ?? 0
            rebuild()
        }
        if let saved = Transcript.load(for: file) {
            show(saved)
        } else {
            transcribe(allowDownload: false)
        }
    }

    private func transcribe(allowDownload: Bool) {
        setStatus(allowDownload ? "Downloading the Parakeet model (about 480 MB, one time)…"
                                : "Transcribing with Parakeet…", busy: true)
        let file = self.file
        Task {
            do {
                let transcript = try await Transcriber.shared.transcribe(file, allowDownload: allowDownload)
                try? transcript.save(for: file)
                show(transcript)
            } catch TranscriberError.modelMissing {
                setStatus(TranscriberError.modelMissing.localizedDescription, busy: false,
                          action: ("Download Model", { [weak self] in self?.transcribe(allowDownload: true) }))
            } catch {
                setStatus("Couldn't transcribe: \(error.localizedDescription)", busy: false,
                          action: ("Try Again", { [weak self] in self?.transcribe(allowDownload: false) }))
            }
        }
    }

    private func setStatus(_ text: String?, busy: Bool, action: (String, () -> Void)? = nil) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !busy
        actionButton.title = action?.0 ?? ""
        actionButton.isHidden = action == nil
        onAction = action?.1
    }

    @objc private func actionClicked() { onAction?() }

    // MARK: Transcript

    private func show(_ transcript: Transcript) {
        self.transcript = transcript
        segments = transcript.segments
        highlighted = nil
        setStatus(transcript.words.isEmpty ? "No speech found in this recording." : nil, busy: false)
        rebuild()
    }

    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 10
        p.lineHeightMultiple = 1.15
        return p
    }()

    /// One paragraph per caption line, starting with its time in the edited
    /// video. Removed words disappear, leaving a ✂︎ you can click to bring
    /// them back; trimmed-off words are faded and fillers are orange.
    private func renderTranscript() {
        guard let transcript, let timeline, let storage = transcriptView.textStorage else { return }
        let words = transcript.words
        let trimStart = edits.trimStart ?? 0, trimEnd = edits.trimEnd ?? .infinity
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: Self.paragraph]
        let stamp: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Self.paragraph,
        ]
        let text = NSMutableAttributedString()
        wordRanges = [:]
        for segment in segments {
            let firstKept = segment.first { !edits.isRemoved($0, in: words) }
            let time = firstKept.map { Self.timestamp(timeline.playbackTime(atSource: words[$0].start)) } ?? "  –  "
            text.append(NSAttributedString(string: time + "   ", attributes: stamp))
            var i = segment.lowerBound
            var needsSpace = false
            while i < segment.upperBound {
                if edits.isRemoved(i, in: words) {
                    var j = i
                    while j + 1 < segment.upperBound, edits.isRemoved(j + 1, in: words) { j += 1 }
                    if needsSpace { text.append(NSAttributedString(string: " ", attributes: base)) }
                    var marker = base
                    marker[.cutWords] = Array(i...j)
                    marker[.foregroundColor] = NSColor.systemRed.withAlphaComponent(0.6)
                    marker[.font] = NSFont.systemFont(ofSize: 11)
                    marker[.toolTip] = "Cut: " + (i...j).map { edits.text(of: $0, in: words) }.joined(separator: " ")
                        + "\nClick to bring it back."
                    text.append(NSAttributedString(string: "✂︎", attributes: marker))
                    needsSpace = true
                    i = j + 1
                    continue
                }
                let shown = edits.text(of: i, in: words)
                if !shown.isEmpty {
                    if needsSpace { text.append(NSAttributedString(string: " ", attributes: base)) }
                    var attributes = base
                    attributes[.wordIndex] = i
                    if words[i].start < trimStart || words[i].start >= trimEnd {
                        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                    } else if edits.corrections[i] == nil, Fillers.isFiller(shown) {
                        attributes[.foregroundColor] = NSColor.systemOrange
                    } else {
                        attributes[.foregroundColor] = NSColor.labelColor
                    }
                    wordRanges[i] = NSRange(location: text.length, length: (shown as NSString).length)
                    text.append(NSAttributedString(string: shown, attributes: attributes))
                    needsSpace = true
                }
                i += 1
            }
            text.append(NSAttributedString(string: "\n", attributes: base))
        }
        let selection = transcriptView.selectedRange()
        storage.setAttributedString(text)
        if NSMaxRange(selection) <= text.length { transcriptView.setSelectedRange(selection) }
        highlighted = nil
        playheadMoved(to: player.currentTime().seconds)
    }

    // MARK: Editing

    private func apply(_ new: Edits) {
        guard new != edits else { return }
        undoStack.append(edits)
        edits = new
        edits.save(for: file)
        rebuild()
    }

    /// Deletes the selected words, or restores them if they were all deleted.
    private func toggleDeleted(_ words: [Int]) {
        guard !words.isEmpty else { return }
        var new = edits
        if words.allSatisfy({ edits.deletedWords.contains($0) }) {
            new.deletedWords.subtract(words)
        } else {
            new.deletedWords.formUnion(words)
        }
        apply(new)
    }

    @objc private func removeFillers() {
        var new = edits
        new.deletedWords.formUnion(remainingFillers())
        apply(new)
    }

    private func remainingFillers() -> [Int] {
        guard let words = transcript?.words else { return [] }
        return words.indices.filter {
            edits.corrections[$0] == nil && Fillers.isFiller(words[$0].text) && !edits.isRemoved($0, in: words)
        }
    }

    /// Brings back removed words (clicked ✂︎ in the transcript).
    private func restore(_ indices: [Int]) {
        guard let words = transcript?.words else { return }
        var new = edits
        new.deletedWords.subtract(indices)
        new.cuts.removeAll { cut in
            indices.contains { i in (cut.start...cut.end).contains((words[i].start + words[i].end) / 2) }
        }
        apply(new)
    }

    // MARK: Sections

    /// A click on a cut section of the trim bar selects it, ready to restore.
    private func selectCut(at source: TimeInterval) {
        if let cut = timeline?.middleCuts.first(where: { $0.contains(source) }) {
            trimBar.selection = cut
        }
    }

    private var selectionIsCut: Bool {
        guard let selection = trimBar.selection, let timeline else { return false }
        return timeline.middleCuts.contains {
            abs($0.lowerBound - selection.lowerBound) < 0.01 && abs($0.upperBound - selection.upperBound) < 0.01
        }
    }

    /// Cuts the selected section of the trim bar, or restores it if it's
    /// already a cut.
    @objc private func cutOrRestoreSelection() {
        guard let selection = trimBar.selection else { return }
        var new = edits
        if selectionIsCut {
            new.cuts.removeAll { $0.end > selection.lowerBound && $0.start < selection.upperBound }
            if let words = transcript?.words {
                new.deletedWords = new.deletedWords.filter { !selection.contains(words[$0].start) }
            }
        } else {
            new.cuts.append(Edits.Cut(start: selection.lowerBound, end: selection.upperBound))
        }
        trimBar.selection = nil
        apply(new)
        window.makeFirstResponder(trimBar)
    }

    // MARK: Fixing captions

    /// Opens a small field over the words to retype them. The new text
    /// replaces the first word; the others are folded into it, so the
    /// timing stays and the video isn't cut. Clearing the field cuts them.
    private func editWords(_ indices: [Int]) {
        guard let words = transcript?.words, let first = indices.min(), let last = indices.max() else { return }
        let visible = (first...last).filter { wordRanges[$0] != nil }
        guard let firstVisible = visible.first, let lastVisible = visible.last,
              let layout = transcriptView.layoutManager, let container = transcriptView.textContainer
        else { return }
        editPopover?.close()
        editingWords = visible

        let field = NSTextField(string: visible.map { edits.text(of: $0, in: words) }.joined(separator: " "))
        field.frame = NSRect(x: 10, y: 10, width: 320, height: 24)
        field.target = self
        field.action = #selector(commitWordEdit(_:))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 44))
        content.addSubview(field)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        editPopover = popover

        let range = NSUnionRange(wordRanges[firstVisible]!, wordRanges[lastVisible]!)
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                       in: container)
        rect.origin.x += transcriptView.textContainerOrigin.x
        rect.origin.y += transcriptView.textContainerOrigin.y
        popover.show(relativeTo: rect, of: transcriptView, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(field)
    }

    @objc private func commitWordEdit(_ sender: NSTextField) {
        guard let words = transcript?.words, let first = editingWords.first else { return }
        let indices = editingWords
        editingWords = []
        editPopover?.close()
        editPopover = nil
        let text = sender.stringValue.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var new = edits
        if text.isEmpty {
            new.deletedWords.formUnion(indices)
        } else {
            new.corrections[first] = text == words[first].text ? nil : text
            for i in indices.dropFirst() { new.corrections[i] = "" }
            // Typing back exactly the original words undoes the fix.
            if text == indices.map({ words[$0].text }).joined(separator: " ") {
                for i in indices { new.corrections[i] = nil }
            }
        }
        apply(new)
        window.makeFirstResponder(transcriptView)
    }

    @objc func undoClicked() { undo() }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        edits = previous
        edits.save(for: file)
        rebuild()
    }

    /// Undoes every cut and trim. Caption fixes are kept.
    @objc private func restoreAll() {
        var new = Edits()
        new.corrections = edits.corrections
        apply(new)
    }

    /// Recomputes the timeline after any change and swaps in the edited
    /// video, keeping the playhead on the same moment of the recording.
    private func rebuild() {
        guard let duration = sourceDuration else { return }
        let words = transcript?.words ?? []
        let sourceNow = timeline?.sourceTime(atPlayback: player.currentTime().seconds) ?? (edits.trimStart ?? 0)
        let timeline = Timeline(edits: edits, words: words, sourceDuration: duration)
        self.timeline = timeline
        captions = timeline.captions(words, edits: edits)

        trimBar.duration = duration
        trimBar.trimStart = edits.trimStart ?? 0
        trimBar.trimEnd = edits.trimEnd ?? duration
        trimBar.cuts = timeline.middleCuts
        renderTranscript()
        updateButtons()

        itemGeneration += 1
        let generation = itemGeneration
        let asset = self.asset
        Task {
            guard let edited = try? await timeline.editedAsset(from: asset), generation == itemGeneration else { return }
            let wasPlaying = player.rate != 0
            player.replaceCurrentItem(with: AVPlayerItem(asset: edited))
            await player.seek(to: CMTime(seconds: timeline.playbackTime(atSource: sourceNow), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            playheadMoved(to: player.currentTime().seconds)
        }
    }

    private func updateButtons() {
        let fillers = remainingFillers().count
        fillersButton.title = fillers > 0 ? "Remove \(fillers) Filler\(fillers == 1 ? "" : "s")" : "No Fillers"
        fillersButton.isEnabled = fillers > 0
        undoButton.isEnabled = !undoStack.isEmpty
        restoreButton.isEnabled = edits.deletedWords.count + edits.cuts.count > 0
            || edits.trimStart != nil || edits.trimEnd != nil
        cutButton.title = selectionIsCut ? "Restore Section" : "Cut Section"
        cutButton.isEnabled = trimBar.selection != nil
        exportButton.isEnabled = timeline != nil && !exporting
    }

    // MARK: Playback

    private func seek(toWord index: Int) {
        guard let word = transcript?.words[index] else { return }
        seek(toSource: word.start)
    }

    private func seek(toSource source: TimeInterval) {
        guard let timeline else { return }
        player.seek(to: CMTime(seconds: timeline.playbackTime(atSource: source), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func playPause() {
        player.rate == 0 ? player.play() : player.pause()
    }

    private func playheadMoved(to time: TimeInterval) {
        guard let timeline, time.isFinite else { return }
        let source = timeline.sourceTime(atPlayback: time)
        trimBar.playhead = source

        if let transcript, !transcript.words.isEmpty {
            var current = transcript.wordIndex(at: source)
            if let i = current, source > transcript.words[i].end + 0.6 { current = nil }
            if current != highlighted, let storage = transcriptView.textStorage, storage.length > 0 {
                storage.beginEditing()
                if let old = highlighted, let range = wordRanges[old] {
                    storage.removeAttribute(.backgroundColor, range: range)
                }
                if let new = current, let range = wordRanges[new] {
                    storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.3),
                                         range: range)
                    if player.rate != 0 { transcriptView.scrollRangeToVisible(range) }
                }
                storage.endEditing()
                highlighted = current
            }
        }

        let line = captionsToggle.state == .on ? captions.first { time >= $0.start && time < $0.end } : nil
        captionView.text = line?.text
    }

    @objc private func toggleCaptions() {
        playheadMoved(to: player.currentTime().seconds)
    }

    // MARK: Export

    @objc func exportClicked() {
        guard let timeline, !exporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + " (edited).mp4"
        panel.directoryURL = file.deletingLastPathComponent()
        let burn = NSButton(checkboxWithTitle: "Burn captions into the video", target: nil, action: nil)
        let sidecars = NSButton(checkboxWithTitle: "Also save the transcript (.srt and .txt)", target: nil, action: nil)
        burn.state = captionsToggle.state
        sidecars.state = .on
        let accessory = NSStackView(views: [burn, sidecars])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.export(timeline: timeline, to: url, burnCaptions: burn.state == .on,
                             saveTranscript: sidecars.state == .on)
            }
        }
    }

    private func export(timeline: Timeline, to url: URL, burnCaptions: Bool, saveTranscript: Bool) {
        exporting = true
        updateButtons()
        player.pause()
        setStatus("Exporting…", busy: true)
        let captions = self.captions
        Task {
            do {
                try await Exporter.export(source: asset, timeline: timeline, captions: captions,
                                          burnCaptions: burnCaptions, to: url) { [weak self] fraction in
                    self?.setStatus("Exporting \(Int(fraction * 100))%…", busy: true)
                }
                if saveTranscript, !captions.isEmpty {
                    let base = url.deletingPathExtension()
                    try Caption.srt(captions).write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                    try Caption.plainText(captions).write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                }
                setStatus("Exported \(url.lastPathComponent)", busy: false,
                          action: ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
            } catch {
                setStatus("Export failed: \(error.localizedDescription)", busy: false)
            }
            exporting = false
            updateButtons()
        }
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
    static let cutWords = NSAttributedString.Key("TapeCutWords")
}

/// Transcript text: click a word to jump to it, Return (or right-click) to
/// fix its caption, select words and press Delete to cut them, click ✂︎ to bring cut
/// words back, Space to play or pause, ⌘Z to undo.
private final class TranscriptTextView: NSTextView {
    var onClickWord: ((Int) -> Void)?
    var onDelete: (([Int]) -> Void)?
    var onRestore: (([Int]) -> Void)?
    var onEdit: (([Int]) -> Void)?
    var onUndo: (() -> Void)?
    var onPlayPause: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cut = attribute(.cutWords, at: point) as? [Int] {
            onRestore?(cut)
            return
        }
        // Let the text view track a drag-selection; a plain click seeks.
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let word = attribute(.wordIndex, at: point) as? Int else { return }
        onClickWord?(word)
    }

    /// Right-click: cut or fix the selected words (or the word clicked).
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let word = attribute(.wordIndex, at: point) as? Int, !selectedWords().contains(word) {
            selectWord(word)
        }
        let words = selectedWords()
        guard !words.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(words.count == 1 ? "Cut This Word" : "Cut These Words") { [weak self] in
            self?.onDelete?(words)
        })
        menu.addItem(ClosureMenuItem("Fix Caption Text…") { [weak self] in self?.onEdit?(words) })
        return menu
    }

    private func selectWord(_ index: Int) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.wordIndex, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? Int == index {
                setSelectedRange(range)
                stop.pointee = true
            }
        }
    }

    /// The attribute of the character under the point (or just before it).
    private func attribute(_ key: NSAttributedString.Key, at point: NSPoint) -> Any? {
        guard let storage = textStorage, storage.length > 0, let layout = layoutManager, let container = textContainer
        else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -3, dy: -2).contains(local) else { return nil }
        let i = layout.characterIndexForGlyph(at: glyph)
        guard i < storage.length else { return nil }
        return storage.attribute(key, at: i, effectiveRange: nil)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, flags) {
        case (51, []), (117, []):  // Delete, Forward Delete
            onDelete?(selectedWords())
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        case (49, []):  // Space
            onPlayPause?()
        case (36, []), (76, []):  // Return, Enter
            onEdit?(selectedWords())
        case (6, .command):  // ⌘Z
            onUndo?()
        default:
            super.keyDown(with: event)
        }
    }

    func selectedWords() -> [Int] {
        guard let storage = textStorage else { return [] }
        var words: [Int] = []
        for value in selectedRanges {
            storage.enumerateAttribute(.wordIndex, in: value.rangeValue) { index, _, _ in
                if let index = index as? Int { words.append(index) }
            }
        }
        return words
    }
}

/// White text on a dark rounded backdrop, like TV captions.
private final class CaptionLabel: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    var text: String? {
        didSet {
            guard text != oldValue else { return }
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

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
