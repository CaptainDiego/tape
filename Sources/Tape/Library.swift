import Foundation

/// The recordings on disk: each video plus the files Tape keeps next to it.
enum Library {
    /// The transcript, edits and share record saved beside a recording.
    static func sidecars(for video: URL) -> [URL] {
        [Transcript.sidecarURL(for: video), Edits.sidecarURL(for: video), ShareRecord.fileURL(for: video)]
            + StudioSound.cacheFiles(for: video)
    }

    /// Moves a recording and its side files to the Trash, so a mistake can
    /// be undone from Finder. Exports saved elsewhere aren't touched.
    static func moveToTrash(_ video: URL) throws {
        let fm = FileManager.default
        try fm.trashItem(at: video, resultingItemURL: nil)
        for url in sidecars(for: video) where fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
