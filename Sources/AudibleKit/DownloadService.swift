import Foundation

/// Fetches the encrypted audio file a license points at.
public actor DownloadService {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// How far a download has progressed.
    public struct Progress: Sendable {
        public let bytesReceived: Int64
        /// Total size, when the server reported one.
        public let bytesExpected: Int64?

        /// Completed share, from 0 to 1. Nil while the total is unknown.
        public var fraction: Double? {
            guard let bytesExpected, bytesExpected > 0 else { return nil }
            return Double(bytesReceived) / Double(bytesExpected)
        }
    }

    /// Downloads the licensed file to `destination`.
    ///
    /// The file is written as it arrives, so a large title never sits in memory.
    /// A partial file left by an earlier attempt is resumed by range request.
    ///
    /// - Parameter onProgress: Called as bytes arrive. Runs off the main actor.
    public func download(
        _ license: ContentLicense,
        to destination: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        // A complete file from an earlier attempt is reused. A large title
        // costs too much to fetch twice because a later step failed.
        if let existing = FileManager.default.fileSize(at: destination),
           let remote = try? await size(of: license.downloadURL),
           existing == remote {
            Log.write("Reusing the \(existing / 1_048_576) MB file already on disk.")
            onProgress?(Progress(bytesReceived: existing, bytesExpected: existing))
            return
        }

        let partial = destination.appendingPathExtension("part")
        let alreadyHave = FileManager.default.fileSize(at: partial) ?? 0

        var request = URLRequest(url: license.downloadURL)
        request.timeoutInterval = 60
        // Without this the delivery network answers 403 and says only
        // "request blocked", whatever the signed URL says.
        request.setValue(URLSessionTransport.userAgent, forHTTPHeaderField: "User-Agent")
        if alreadyHave > 0 {
            request.setValue("bytes=\(alreadyHave)-", forHTTPHeaderField: "Range")
        }

        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudibleError.downloadFailed("The response was not HTTP.")
        }

        // A server that ignores the range restarts the file, so the partial
        // file must be discarded rather than appended to.
        let resuming = http.statusCode == 206
        guard http.statusCode == 200 || resuming else {
            throw AudibleError.downloadFailed("The server returned HTTP \(http.statusCode).")
        }
        if !resuming, alreadyHave > 0 {
            try? FileManager.default.removeItem(at: partial)
        }

        let expected = http.expectedContentLength > 0
            ? http.expectedContentLength + (resuming ? alreadyHave : 0)
            : nil

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var received = resuming ? alreadyHave : 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        for try await byte in stream {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress?(Progress(bytesReceived: received, bytesExpected: expected))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()
        onProgress?(Progress(bytesReceived: received, bytesExpected: expected))

        // The byte count is the only exact test of a whole file.
        //
        // A container's own idea of its length survives truncation: a file cut
        // in half still says how long the whole book was, so a check on
        // duration passes a download that stopped early. The partial file is
        // kept, so the next attempt continues rather than starting again.
        if let expected, received != expected {
            throw AudibleError.downloadFailed(
                "The file stopped early: \(received) bytes of \(expected).")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}

extension DownloadService {
    /// Asks the server how large the file is, without fetching it.
    func size(of url: URL) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue(URLSessionTransport.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let length = http.value(forHTTPHeaderField: "Content-Length")
        else { return nil }
        return Int64(length)
    }
}

extension FileManager {
    /// Size of the file at `url`, or nil when there is no file there.
    public func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}
