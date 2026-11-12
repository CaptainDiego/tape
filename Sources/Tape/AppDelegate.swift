import AppKit
@preconcurrency import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State {
        case idle, starting, recording(since: Date), saving
    }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = Settings()
    private let recorder = Recorder()
    private let bubble = CameraBubble()
    private let selector = RegionSelector()
    private let frame = RecordingFrame()
    private var ticker: Timer?
    private var state: State = .idle { didSet { refreshStatusItem() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Settings.recordingsDir, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        menu.autoenablesItems = false
        menu.delegate = self

        recorder.onUnexpectedStop = { [weak self] _ in
            guard let self, case .recording = self.state else { return }
            self.stopRecording()
        }
        refreshStatusItem()
        NSApp.mainMenu = Self.mainMenu()
        Task { await askForPermissions() }
    }

    /// Asks for camera, microphone and screen recording access right at
    /// launch, one after the other, so the first recording just starts.
    /// Each prompt only appears if the user hasn't answered it yet.
    private func askForPermissions() async {
        if settings.cameraID != nil, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if settings.micID != nil, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        // Shows the system's screen recording prompt, which offers to open
        // System Settings. macOS asks to reopen the app once it's allowed.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Don't quit halfway through a recording: stop it from the menu bar first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .idle = state { return .terminateNow }
        NSSound.beep()
        return .terminateCancel
    }

    /// The menu bar shown while an editor window is open: Quit, the usual
    /// editing keys, full screen and window commands.
    private static func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = NSMenu(title: title)
            items.forEach { top.submenu!.addItem($0) }
            return top
        }
        let main = NSMenu()
        main.addItem(menu("Tape", [
            item("About Tape", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Tape", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Tape", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("Share…", #selector(EditorWindow.shareClicked), "s", [.command, .shift]),
            item("Export…", #selector(EditorWindow.exportClicked), "e"),
            .separator(),
            item("Move to Trash…", #selector(EditorWindow.trashClicked), "\u{8}"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(menu("Edit", [
            item("Undo", #selector(EditorWindow.undoClicked), "z"),
            .separator(),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(menu("View", [
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        return main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `open -a Tape <video>` (or dropping a video on the app) opens it in the editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            EditorWindow.open(url)
        }
    }

    // MARK: Status item

    /// While recording, one click on the menu bar icon stops (like Loom).
    /// Otherwise the click opens the menu.
    @objc private func statusItemClicked() {
        if case .recording = state { stopRecording() }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        var symbol = "record.circle"
        var title = ""
        var tint: NSColor?
        switch state {
        case .idle: break
        case .starting: title = "Starting…"
        case .recording(let since):
            symbol = "stop.circle.fill"
            tint = .systemRed
            title = Self.elapsed(Date().timeIntervalSince(since))
        case .saving: title = "Saving…"
        }
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if case .recording = state {
            // A red pill with white text reads on any menu bar, light or dark.
            button.image = Self.recordingPill(title)
            button.title = ""
            button.contentTintColor = nil
        } else {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tape")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = title.isEmpty ? "" : " " + title
            button.contentTintColor = tint
        }

        if case .recording = state { statusItem.menu = nil } else { statusItem.menu = menu }
    }

    /// "■ 1:23" in white on a red rounded pill. Clicking it stops.
    private static func recordingPill(_ time: String) -> NSImage {
        let text = NSAttributedString(string: time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let square: CGFloat = 7
        let size = NSSize(width: ceil(8 + square + 5 + textSize.width + 9), height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: (rect.height - square) / 2, width: square, height: square),
                         xRadius: 1.5, yRadius: 1.5).fill()
            text.draw(at: NSPoint(x: 8 + square + 5, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording \(time). Click to stop."
        return image
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let idle: Bool = { if case .idle = state { return true } else { return false } }()

        switch state {
        case .idle:
            menu.addItem(ActionItem("Record Full Screen") { [weak self] in self?.beginRecording(selectArea: false) })
            menu.addItem(ActionItem("Record Area…") { [weak self] in self?.beginRecording(selectArea: true) })
            // One click to leave yourself out (or back in); the Camera submenu picks which one.
            menu.addItem(ActionItem("Record Camera", checked: settings.cameraID != nil) { [weak self] in
                guard let settings = self?.settings else { return }
                if settings.cameraID != nil {
                    settings.lastCameraID = settings.cameraID
                    settings.cameraID = nil
                } else {
                    settings.cameraID = settings.lastCameraID.flatMap { AVCaptureDevice(uniqueID: $0)?.uniqueID }
                        ?? AVCaptureDevice.default(for: .video)?.uniqueID
                }
            })
        case .starting: menu.addItem(ActionItem("Starting…", enabled: false) {})
        case .saving: menu.addItem(ActionItem("Saving…", enabled: false) {})
        case .recording: break
        }
        menu.addItem(.separator())

        let displays = Devices.displays()
        let displayID = settings.displayID
        menu.addItem(submenu("Screen", current: displays.first { $0.id == displayID }?.name, enabled: idle,
            displays.map { display in
                ActionItem(display.name, checked: display.id == displayID) { [weak self] in
                    self?.settings.displayID = display.id
                }
            }))

        let cameras = Devices.cameras()
        let cameraID = settings.cameraID
        menu.addItem(submenu("Camera", current: cameras.first { $0.uniqueID == cameraID }?.localizedName ?? "None",
                             enabled: idle,
            [ActionItem("No Camera", checked: cameraID == nil) { [weak self] in self?.settings.cameraID = nil }]
            + cameras.map { camera in
                ActionItem(camera.localizedName, checked: camera.uniqueID == cameraID) { [weak self] in
                    self?.settings.cameraID = camera.uniqueID
                }
            }))

        let shape = settings.bubbleShape
        menu.addItem(submenu("Camera Shape", current: shape.title, enabled: idle && cameraID != nil,
            BubbleShape.allCases.map { option in
                ActionItem(option.title, checked: option == shape) { [weak self] in self?.settings.bubbleShape = option }
            }))

        let mics = Devices.microphones()
        let micID = settings.micID
        menu.addItem(submenu("Microphone", current: mics.first { $0.uniqueID == micID }?.localizedName ?? "None",
                             enabled: idle,
            [ActionItem("No Microphone", checked: micID == nil) { [weak self] in self?.settings.micID = nil }]
            + mics.map { mic in
                ActionItem(mic.localizedName, checked: mic.uniqueID == micID) { [weak self] in
                    self?.settings.micID = mic.uniqueID
                }
            }))

        let quality = settings.quality
        menu.addItem(submenu("Quality", current: quality.title, enabled: idle, Quality.allCases.map { option in
            ActionItem(option.title, checked: option == quality) { [weak self] in self?.settings.quality = option }
        }))

        menu.addItem(.separator())
        menu.addItem(ActionItem("Open Recording…") { [weak self] in self?.openRecording() })
        menu.addItem(ActionItem("Show Recordings in Finder") { NSWorkspace.shared.open(Settings.recordingsDir) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Tape", key: "q") { NSApp.terminate(nil) })
    }

    private func submenu(_ title: String, current: String?, enabled: Bool, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: current.map { "\(title): \($0)" } ?? title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach { sub.addItem($0) }
        item.submenu = sub
        item.isEnabled = enabled
        return item
    }

    // MARK: Recording

    private func beginRecording(selectArea: Bool) {
        guard case .idle = state else { return }
        let displayID = settings.displayID
        guard let screen = Devices.screen(for: displayID) ?? NSScreen.main else { return }

        if selectArea {
            selector.select(on: screen) { [weak self] area in
                guard let area else { return }
                self?.startRecording(screen: screen, displayID: displayID, area: area)
            }
        } else {
            startRecording(screen: screen, displayID: displayID, area: nil)
        }
    }

    /// `area` is in global screen coordinates; nil records the whole screen.
    private func startRecording(screen: NSScreen, displayID: CGDirectDisplayID, area: CGRect?) {
        state = .starting
        let cameraID = settings.cameraID
        let micID = settings.micID
        let quality = settings.quality
        let visibleArea = area ?? screen.frame

        // ScreenCaptureKit wants the region in the display's own points with
        // the origin at the top-left; AppKit's origin is bottom-left.
        let region = area.map { a in
            CGRect(x: a.minX - screen.frame.minX, y: screen.frame.maxY - a.maxY, width: a.width, height: a.height)
        }

        Task {
            do {
                if cameraID != nil, !(await AVCaptureDevice.requestAccess(for: .video)) {
                    throw AppError("Tape doesn't have camera access. Allow it in System Settings → Privacy & Security → Camera, or pick No Camera.")
                }
                if micID != nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    throw AppError("Tape doesn't have microphone access. Allow it in System Settings → Privacy & Security → Microphone, or pick No Microphone.")
                }
                if let cameraID {
                    try bubble.show(cameraID: cameraID, shape: settings.bubbleShape, inside: visibleArea)
                }
                // The countdown also gives the camera time to warm up and
                // gives you a moment to drag the bubble where you want it.
                frame.show(around: visibleArea)
                await frame.countdown(from: 3)

                do {
                    try await recorder.start(displayID: displayID, region: region, micID: micID, quality: quality,
                                             excluding: [frame.windowID].compactMap { $0 },
                                             to: Settings.newRecordingURL())
                } catch {
                    throw AppError("""
                        \(error.localizedDescription)

                        If this is about permission, allow Tape in System Settings → Privacy & Security → \
                        Screen & System Audio Recording, then quit and reopen Tape.
                        """)
                }
                state = .recording(since: Date())
                ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated { self.refreshStatusItem() }
                }
            } catch {
                bubble.hide()
                frame.hide()
                state = .idle
                showAlert("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        guard case .recording = state else { return }
        ticker?.invalidate()
        ticker = nil
        state = .saving

        Task {
            let result: Result<URL, Error>
            do { result = .success(try await recorder.stop()) } catch { result = .failure(error) }
            // Put the screen back to normal before showing anything.
            bubble.hide()
            frame.hide()
            state = .idle
            switch result {
            case .success(let file): EditorWindow.open(file)
            case .failure(let error): showAlert("Couldn't save the recording", error.localizedDescription)
            }
        }
    }

    private func openRecording() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.directoryURL = Settings.recordingsDir
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        EditorWindow.open(file)
    }

    // MARK: Alerts

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A menu item that runs a closure.
@MainActor
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, key: String = "",
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
