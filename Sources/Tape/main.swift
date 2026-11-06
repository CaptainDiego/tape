import AppKit

// `Tape --transcribe <video>` prints the transcript and exits. It's handy for
// testing Parakeet without clicking through the app.
if let flag = CommandLine.arguments.firstIndex(of: "--transcribe"), flag + 1 < CommandLine.arguments.count {
    let file = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let start = Date()
            let transcript = try await Transcriber.shared.transcribe(file)
            for segment in transcript.segments {
                let words = transcript.words[segment]
                print(String(format: "[%6.2f–%6.2f] ", words.first!.start, words.last!.end)
                      + words.map(\.text).joined(separator: " "))
            }
            print(String(format: "%d words in %.1fs", transcript.words.count, Date().timeIntervalSince(start)))
        } catch {
            print("error: \(error.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
