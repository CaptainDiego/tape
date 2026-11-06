import Foundation

/// One spoken word with its position in the recording, in seconds.
struct Word: Codable, Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// A recording's transcript, saved next to the video as
/// "<name>.transcript.json" so reopening it is instant.
struct Transcript: Codable, Sendable {
    var model: String
    var words: [Word]

    static func sidecarURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    static func load(for video: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: sidecarURL(for: video)) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    func save(for video: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(self).write(to: Self.sidecarURL(for: video), options: .atomic)
    }

    /// Parakeet returns SentencePiece pieces; a piece starting with a space
    /// begins a new word, anything else continues the current one.
    static func words(fromTokens tokens: [(text: String, start: TimeInterval, end: TimeInterval)],
                      offset: TimeInterval) -> [Word] {
        var words: [Word] = []
        for token in tokens {
            let text = token.text.replacingOccurrences(of: "▁", with: " ")
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if text.hasPrefix(" ") || words.isEmpty {
                words.append(Word(text: trimmed, start: token.start + offset, end: token.end + offset))
            } else {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = token.end + offset
            }
        }
        return words
    }

    /// Groups words into caption-sized lines: a new line after a pause, after
    /// a sentence ends, or when the line gets long.
    var segments: [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        for i in words.indices {
            let count = i - start + 1
            let last = i == words.count - 1
            let pause = last ? 0 : words[i + 1].start - words[i].end
            let sentenceEnd = words[i].text.last.map { ".?!".contains($0) } ?? false
            if last || pause > 0.7 || count >= 12 || (sentenceEnd && count >= 3) {
                result.append(start..<(i + 1))
                start = i + 1
            }
        }
        return result
    }

    /// Index of the word being spoken at `time`, or the last one before it.
    func wordIndex(at time: TimeInterval) -> Int? {
        var low = 0, high = words.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }
}
