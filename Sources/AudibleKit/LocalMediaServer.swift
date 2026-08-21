import Foundation
import Network

/// Serves one directory over HTTP on the loopback interface.
///
/// AVPlayer plays an HLS playlist only over HTTP, so the segments that
/// `StreamService` writes need a server. It listens on 127.0.0.1 alone, so
/// nothing outside this machine can reach it.
public final class LocalMediaServer: @unchecked Sendable {
    private let directory: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.earmarky.mediaserver")

    /// The port the server listens on. Chosen by the system.
    public private(set) var port: UInt16 = 0

    public init(directory: URL) throws {
        self.directory = directory
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        do {
            self.listener = try NWListener(using: parameters)
        } catch {
            throw AudibleError.downloadFailed("The local server could not start: \(error).")
        }
    }

    /// Starts listening and returns once the port is known.
    public func start() async throws {
        // The listener reports its state on its own queue, and reports more
        // than once, so the continuation is guarded against a second resume.
        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    self.port = self.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: AudibleError.downloadFailed(
                        "The local server failed: \(error)."))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    /// The address of a file inside the served directory.
    public func url(for name: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(name)")!
    }

    // MARK: Serving

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        guard let line = request.split(separator: "\r\n").first else {
            return send(status: "400 Bad Request", body: Data(), on: connection)
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(status: "405 Method Not Allowed", body: Data(), on: connection)
        }

        let name = String(parts[1].dropFirst())
        // Only plain names are served. A name with a path separator or a parent
        // reference could otherwise reach outside the directory.
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            return send(status: "403 Forbidden", body: Data(), on: connection)
        }

        let file = directory.appendingPathComponent(name)
        guard let body = try? Data(contentsOf: file) else {
            return send(status: "404 Not Found", body: Data(), on: connection)
        }
        send(
            status: "200 OK",
            body: parts[0] == "HEAD" ? Data() : body,
            length: body.count,
            type: LocalMediaServer.contentType(for: name),
            on: connection)
    }

    private func send(
        status: String,
        body: Data,
        length: Int? = nil,
        type: String = "text/plain",
        on connection: NWConnection
    ) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(length ?? body.count)\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func contentType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".aac") { return "audio/aac" }
        if name.hasSuffix(".ts") { return "video/mp2t" }
        if name.hasSuffix(".m4s") || name.hasSuffix(".mp4") { return "audio/mp4" }
        return "application/octet-stream"
    }
}


/// Lets exactly one caller proceed. Used to resume a continuation once when
/// the source of the events can fire more than once.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
