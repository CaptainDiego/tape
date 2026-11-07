@preconcurrency import AVFoundation
import Foundation

/// What the user changed in a recording. The video file itself is never
/// changed; these edits are saved next to it as "<name>.edits.json" and
/// applied at playback and export.
struct Edits: Codable, Equatable {
    var deletedWords: Set<Int> = []
    var trimStart: TimeInterval?
    var trimEnd: TimeInterval?
    /// Sections cut out on the trim bar, in source time.
    var cuts: [Cut] = []
    /// Words whose caption text the user fixed. An empty string means the
    /// word was merged into the one before it (the video isn't cut).
    var corrections: [Int: String] = [:]
    /// Use the Studio Sound version of the audio.
    var studioSound = false

    struct Cut: Codable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
    }

    init() {}

    /// Tolerates sidecars written by older versions, which lack some keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deletedWords = try c.decodeIfPresent(Set<Int>.self, forKey: .deletedWords) ?? []
        trimStart = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart)
        trimEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .trimEnd)
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        corrections = try c.decodeIfPresent([Int: String].self, forKey: .corrections) ?? [:]
        studioSound = try c.decodeIfPresent(Bool.self, forKey: .studioSound) ?? false
    }

    /// True if the word is cut from the video, by deleting it in the
    /// transcript or by cutting a section on the trim bar.
    func isRemoved(_ i: Int, in words: [Word]) -> Bool {
        if deletedWords.contains(i) { return true }
        let middle = (words[i].start + words[i].end) / 2
        return cuts.contains { middle >= $0.start && middle <= $0.end }
    }

    /// The word as it should read in captions, after the user's fixes.
    func text(of i: Int, in words: [Word]) -> String {
        corrections[i] ?? words[i].text
    }

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
    /// Stretches removed from the middle (deleted words and sections cut on
    /// the trim bar), merged and sorted. Not counting the trimmed ends.
    let middleCuts: [ClosedRange<TimeInterval>]
    var duration: TimeInterval { pieces.last.map { $0.playbackStart + $0.length } ?? 0 }
    var isUncut: Bool { pieces.count == 1 && pieces[0].sourceStart <= 0.001 && pieces[0].sourceEnd >= sourceDuration - 0.001 }

    init(edits: Edits, words: [Word], sourceDuration: TimeInterval) {
        self.sourceDuration = sourceDuration
        var middle: [(TimeInterval, TimeInterval)] = []

        // Each run of deleted words becomes one cut that also takes the
        // pause around it: from shortly after the previous kept word up to
        // just before the next one, so no "um"-shaped gap is left behind.
        let deleted = edits.deletedWords.filter { words.indices.contains($0) }.sorted()
        var i = 0
        while i < deleted.count {
            var j = i
            while j + 1 < deleted.count, deleted[j + 1] == deleted[j] + 1 { j += 1 }
            let first = deleted[i], last = deleted[j]
            let leadIn = first > 0 ? words[first - 1].end + 0.08 : 0
            let start = min(words[first].start, max(leadIn, words[first].start - 0.3))
            let end = last + 1 < words.count
                ? max(words[last].end, words[last + 1].start - 0.05)
                : words[last].end + 0.1
            middle.append((max(start, 0), min(end, sourceDuration)))
            i = j + 1
        }
        for cut in edits.cuts {
            middle.append((max(cut.start, 0), min(cut.end, sourceDuration)))
        }

        var merged: [ClosedRange<TimeInterval>] = []
        for (start, end) in middle.sorted(by: { $0.0 < $1.0 }) where end > start {
            if let last = merged.last, start <= last.upperBound + 0.04 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                merged.append(start...end)
            }
        }
        middleCuts = merged

        var cuts = merged.map { ($0.lowerBound, $0.upperBound) }
        if let start = edits.trimStart, start > 0 { cuts.append((0, start)) }
        if let end = edits.trimEnd, end < sourceDuration { cuts.append((end, sourceDuration)) }

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
    /// `audio`, if given, replaces the recording's sound (Studio Sound); it
    /// must line up with the video from time zero.
    func editedAsset(from asset: AVURLAsset, audio: AVURLAsset? = nil) async throws -> AVAsset {
        if isUncut, audio == nil { return asset }
        let composition = AVMutableComposition()
        var tracks: [(AVAssetTrack, AVMutableCompositionTrack)] = []
        for (source, type) in [(asset, AVMediaType.video), (audio ?? asset, .audio)] {
            for track in try await source.loadTracks(withMediaType: type) {
                guard let copy = composition.addMutableTrack(withMediaType: type,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                if type == .video { copy.preferredTransform = try await track.load(.preferredTransform) }
                tracks.append((track, copy))
            }
        }
        var at = CMTime.zero
        for piece in pieces {
            let range = CMTimeRange(start: CMTime(seconds: piece.sourceStart, preferredTimescale: 600),
                                    end: CMTime(seconds: piece.sourceEnd, preferredTimescale: 600))
            for (track, copy) in tracks {
                // A track can be a little shorter than the piece (the mic
                // starts late, say): insert just the part it has.
                let part = range.intersection(try await track.load(.timeRange))
                guard part.duration > .zero else { continue }
                try copy.insertTimeRange(part, of: track, at: at + (part.start - range.start))
            }
            at = at + range.duration
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
            let text = edits.text(of: i, in: words)
            guard !text.isEmpty, !edits.isRemoved(i, in: words), isKept(word.start) else { return nil }
            let start = playbackTime(atSource: word.start)
            return Word(text: text, start: start, end: max(start, playbackTime(atSource: word.end)))
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
