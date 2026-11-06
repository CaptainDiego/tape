import AppKit
import AVFoundation

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

// `Tape --export <video> <out.mp4>` renders a recording with its saved edits
// and burned-in captions, the same as the Export button.
if let flag = CommandLine.arguments.firstIndex(of: "--export"), flag + 2 < CommandLine.arguments.count {
    let source = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let output = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let asset = AVURLAsset(url: source)
            let words = Transcript.load(for: source)?.words ?? []
            let edits = Edits.load(for: source)
            let timeline = Timeline(edits: edits, words: words, sourceDuration: try await asset.load(.duration).seconds)
            let captions = timeline.captions(words, edits: edits)
            try await Exporter.export(source: asset, timeline: timeline, captions: captions,
                                      burnCaptions: true, to: output) { _ in }
            print(String(format: "exported %.1fs (from %.1fs), %d captions", timeline.duration,
                         timeline.sourceDuration, captions.count))
            print(Caption.srt(captions))
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
