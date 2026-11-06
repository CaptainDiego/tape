@preconcurrency import AVFoundation
import Foundation

/// What the user cut from a recording. The video file itself is never
/// changed; these edits are saved next to it as "<name>.edits.json" and
/// applied at playback time (and, later, at export).
struct Edits: Codable, Equatable {
    var deletedWords: Set<Int> = []
    var trimStart: TimeInterval?
    var trimEnd: TimeInterval?

    static func sidecarURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("edits.json")
    }

    static func load(for video: URL) -> Edits {
        guard let data = try? Data(contentsOf: sidecarURL(for: video)),
              let edits = try? JSONDecoder().decode(Edits.self, from: data)
        else { return Edits() }
        return edits
    }

    func save(for video: URL) {
        let url = Self.sidecarURL(for: video)
        if self == Edits() {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }
}

/// Hesitation sounds Parakeet writes out ("um", "uh", French "euh"…).
/// Words like "like" or "so" are left alone: they're often real words.
enum Fillers {
    private static let words: Set<String> = [
        "um", "umm", "uhm", "uh", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "mhm",
        "euh", "heu", "bah",
    ]

    static func isFiller(_ text: String) -> Bool {
        words.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }
}

/// Maps between time in the original file ("source") and time in the
/// edited playback, which skips every cut.
struct Timeline {
    struct Piece {
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
        let playbackStart: TimeInterval
        var length: TimeInterval { sourceEnd - sourceStart }
    }

    let pieces: [Piece]
    let sourceDuration: TimeInterval
    /// Stretches removed by deleting words (not counting the trimmed ends).
    let wordCuts: [ClosedRange<TimeInterval>]
    var duration: TimeInterval { pieces.last.map { $0.playbackStart + $0.length } ?? 0 }
    var isUncut: Bool { pieces.count == 1 && pieces[0].sourceStart <= 0.001 && pieces[0].sourceEnd >= sourceDuration - 0.001 }

    init(edits: Edits, words: [Word], sourceDuration: TimeInterval) {
        self.sourceDuration = sourceDuration
        var cuts: [(TimeInterval, TimeInterval)] = []
        if let start = edits.trimStart, start > 0 { cuts.append((0, start)) }
        if let end = edits.trimEnd, end < sourceDuration { cuts.append((end, sourceDuration)) }
        let trimCount = cuts.count

        // Each run of deleted words becomes one cut, running up to just before
        // the next kept word so the gap after them goes too.
        let deleted = edits.deletedWords.filter { words.indices.contains($0) }.sorted()
        var i = 0
        while i < deleted.count {
            var j = i
            while j + 1 < deleted.count, deleted[j + 1] == deleted[j] + 1 { j += 1 }
            let first = deleted[i], last = deleted[j]
            let end = last + 1 < words.count
                ? max(words[last].end, words[last + 1].start - 0.05)
                : words[last].end + 0.1
            cuts.append((words[first].start, min(end, sourceDuration)))
            i = j + 1
        }

        wordCuts = cuts.dropFirst(trimCount).map { $0.0...max($0.0, $0.1) }

        // Keep whatever the cuts leave, skipping slivers too short to matter.
        var pieces: [Piece] = []
        var cursor: TimeInterval = 0
        var playback: TimeInterval = 0
        for (start, end) in cuts.sorted(by: { $0.0 < $1.0 }) + [(sourceDuration, sourceDuration)] {
            if start - cursor > 0.04 {
                pieces.append(Piece(sourceStart: cursor, sourceEnd: start, playbackStart: playback))
                playback += start - cursor
            }
            cursor = max(cursor, end)
        }
        self.pieces = pieces
    }

    func sourceTime(atPlayback t: TimeInterval) -> TimeInterval {
        guard let piece = pieces.last(where: { $0.playbackStart <= t }) ?? pieces.first else { return t }
        return piece.sourceStart + min(max(t - piece.playbackStart, 0), piece.length)
    }

    /// For a source time inside a cut, returns where playback resumes.
    func playbackTime(atSource t: TimeInterval) -> TimeInterval {
        for piece in pieces where t < piece.sourceEnd {
            return piece.playbackStart + max(t - piece.sourceStart, 0)
        }
        return duration
    }

    /// The edited video: the kept pieces of the original, back to back.
    func editedAsset(from asset: AVURLAsset) async throws -> AVAsset {
        if isUncut { return asset }
        let composition = AVMutableComposition()
        for piece in pieces {
            let range = CMTimeRange(start: CMTime(seconds: piece.sourceStart, preferredTimescale: 600),
                                    end: CMTime(seconds: piece.sourceEnd, preferredTimescale: 600))
            try await composition.insertTimeRange(range, of: asset, at: composition.duration)
        }
        return composition
    }

    private func isKept(_ t: TimeInterval) -> Bool {
        pieces.contains { t >= $0.sourceStart - 0.02 && t < $0.sourceEnd }
    }

    /// The words that survive the edits, re-timed to edited playback.
    func keptWords(_ words: [Word], edits: Edits) -> [Word] {
        words.indices.compactMap { i in
            let word = words[i]
            guard !edits.deletedWords.contains(i), isKept(word.start) else { return nil }
            let start = playbackTime(atSource: word.start)
            return Word(text: word.text, start: start, end: max(start, playbackTime(atSource: word.end)))
        }
    }

    /// Caption lines in edited playback time. Each stays up briefly after
    /// its last word, but never overlaps the next one.
    func captions(_ words: [Word], edits: Edits) -> [Caption] {
        let kept = Transcript(model: "", words: keptWords(words, edits: edits))
        let lines = kept.segments.map { segment in
            Caption(text: kept.words[segment].map(\.text).joined(separator: " "),
                    start: kept.words[segment.lowerBound].start,
                    end: kept.words[segment.upperBound - 1].end)
        }
        return lines.indices.map { i in
            var line = lines[i]
            let limit = i + 1 < lines.count ? lines[i + 1].start : duration
            line.end = min(max(line.end + 0.6, line.start + 0.8), limit)
            return line
        }
    }
}

struct Caption: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    static func srt(_ captions: [Caption]) -> String {
        func stamp(_ t: TimeInterval) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return captions.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func plainText(_ captions: [Caption]) -> String {
        captions.map(\.text).joined(separator: "\n") + "\n"
    }
}
