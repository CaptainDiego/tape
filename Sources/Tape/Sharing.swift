import Foundation
import Security

/// Optional sharing to your own Cloudflare Worker (see server/). Off until the
/// user enters a server and token; until then Tape makes no network requests.
/// The token lives in the Keychain, the server address in UserDefaults.
enum SharingConfig {
    private static let serverKey = "sharingServer"
    private static let service = "com.diego.tape.sharing"

    static var server: URL? {
        get { UserDefaults.standard.string(forKey: serverKey).flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: serverKey) }
    }

    static var token: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrLabel as String] = "Tape sharing token"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static var isConfigured: Bool { server != nil && token != nil }

    /// Accepts "tape.example.com" or a full URL; only https (or localhost for testing).
    static func parseServer(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (local && url.scheme == "http") else { return nil }
        return url
    }
}

/// What we remember about a shared recording, in `<name>.share.json`.
struct ShareRecord: Codable {
    var id: String
    var url: URL
    var server: URL
    var title: String
    var uploadedAt: Date

    static func fileURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("share.json")
    }

    static func load(for video: URL) -> ShareRecord? {
        guard let data = try? Data(contentsOf: fileURL(for: video)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ShareRecord.self, from: data)
    }

    func save(for video: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL(for: video), options: .atomic)
    }

    static func remove(for video: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: video))
    }
}

enum SharingError: LocalizedError {
    case notConfigured, unauthorized, notFound, server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Sharing isn't set up."
        case .unauthorized: "The server didn't accept the sharing token. Check it in Sharing Settings."
        case .notFound: "This share no longer exists on the server."
        case .server(let code): "The server answered with an error (\(code))."
        }
    }
}

/// Talks to the share server's owner API.
struct ShareClient {
    let server: URL
    let token: String

    /// Every part but the last is this size. R2 needs at least 5 MiB, and a
    /// Worker accepts up to 100 MB per request.
    static let partSize = 16 * 1024 * 1024

    init(server: URL, token: String) {
        self.server = server
        self.token = token
    }

    init() throws {
        guard let server = SharingConfig.server, let token = SharingConfig.token else { throw SharingError.notConfigured }
        self.server = server
        self.token = token
    }

    /// No cookies, no cache, nothing written to disk.
    private static let session = URLSession(configuration: .ephemeral)

    struct Info: Decodable { let id: String; let url: URL; let views: Int; let ready: Bool }
    private struct Created: Decodable { let id: String; let url: URL }
    private struct Upload: Decodable { let uploadId: String }
    private struct Part: Codable { let partNumber: Int; let etag: String }

    func info(id: String) async throws -> Info {
        try JSONDecoder().decode(Info.self, from: try await send("GET", "api/shares/\(id)"))
    }

    /// Checks the server and token: an unknown id should give 404, not 401.
    func check() async throws {
        do { _ = try await send("GET", "api/shares/000000000000") } catch SharingError.notFound { return }
    }

    func delete(id: String) async throws {
        _ = try await send("DELETE", "api/shares/\(id)")
    }

    /// Uploads a finished MP4 and its captions. Pass `existingID` to replace
    /// the video behind a link that's already out there.
    func share(video: URL, vtt: String, title: String, duration: TimeInterval, existingID: String?,
               progress: @escaping @MainActor (Double) -> Void) async throws -> (id: String, url: URL) {
        let id: String
        if let existingID {
            id = existingID
            _ = try await info(id: id)  // still there?
        } else {
            let body = try JSONSerialization.data(withJSONObject: ["title": title, "duration": duration])
            id = try JSONDecoder().decode(Created.self, from: try await send("POST", "api/shares", body: body)).id
        }
        _ = try await send("PUT", "api/shares/\(id)/captions", body: Data(vtt.utf8), contentType: "text/vtt")

        let upload = try JSONDecoder().decode(Upload.self, from: try await send("POST", "api/shares/\(id)/video"))
        let query = [URLQueryItem(name: "upload", value: upload.uploadId)]
        do {
            let handle = try FileHandle(forReadingFrom: video)
            defer { try? handle.close() }
            let total = Double(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
            var parts: [Part] = []
            var sent = 0.0
            while let chunk = try handle.read(upToCount: Self.partSize), !chunk.isEmpty {
                let number = parts.count + 1
                let base = sent
                let data = try await retrying {
                    try await send("PUT", "api/shares/\(id)/video/\(number)", query: query, body: chunk,
                                   contentType: "application/octet-stream") { bytes in
                        await progress(min((base + Double(bytes)) / total, 1))
                    }
                }
                parts.append(try JSONDecoder().decode(Part.self, from: data))
                sent += Double(chunk.count)
            }
            let body = try JSONEncoder().encode(Complete(parts: parts, title: title, duration: duration))
            let done = try JSONDecoder().decode(Created.self,
                                                from: try await send("POST", "api/shares/\(id)/video/complete",
                                                                     query: query, body: body))
            return (id, done.url)
        } catch {
            _ = try? await send("DELETE", "api/shares/\(id)/video", query: query)
            throw error
        }
    }

    private struct Complete: Encodable { let parts: [Part]; let title: String; let duration: TimeInterval }

    private func retrying(_ attempt: () async throws -> Data) async throws -> Data {
        for delay in [1.0, 3.0] {
            do { return try await attempt() } catch let error as SharingError { throw error } catch {
                try await Task.sleep(for: .seconds(delay))
            }
        }
        return try await attempt()
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      contentType: String = "application/json",
                      sent: (@Sendable (Int64) async -> Void)? = nil) async throws -> Data {
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        let (data, response): (Data, URLResponse)
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            (data, response) = try await Self.session.upload(for: request, from: body,
                                                             delegate: sent.map(UploadProgress.init))
        } else {
            (data, response) = try await Self.session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw SharingError.unauthorized
        case 404: throw SharingError.notFound
        default: throw SharingError.server(status)
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let sent: @Sendable (Int64) async -> Void
    init(_ sent: @escaping @Sendable (Int64) async -> Void) { self.sent = sent }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        Task { await sent(totalBytesSent) }
    }
}
