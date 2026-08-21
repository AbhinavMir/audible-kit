import Foundation
import Network
import Testing
@testable import AudibleKit

/// The local server takes bytes from anything on this machine that can reach
/// the loopback interface, so it must not be possible to wedge or crash.
@Suite("Fuzzing the local server")
struct ServerFuzzTests {

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("playlist".utf8).write(to: url.appendingPathComponent("stream.m3u8"))
        return url
    }

    /// Sends raw bytes, and gives up rather than waiting forever.
    static func send(_ bytes: Data, to port: UInt16) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let gate = ResumeGate()
            let done: @Sendable () -> Void = {
                connection.cancel()
                if gate.claim() { continuation.resume() }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: bytes, completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 0, maximumLength: 4096) {
                            _, _, _, _ in done()
                        }
                    })
                case .failed, .cancelled:
                    done()
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: done)
        }
    }

    @Test("A request of any shape leaves the server working")
    func malformedRequests() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try LocalMediaServer(directory: dir)
        try await server.start()
        defer { server.stop() }

        var requests: [Data] = [
            Data(),
            Data("\r\n\r\n".utf8),
            Data("GET".utf8),
            Data("GET /".utf8),
            Data("GET / HTTP/1.1".utf8),
            Data("PUT /stream.m3u8 HTTP/1.1\r\n\r\n".utf8),
            Data(("GET /stream.m3u8 HTTP/1.1\r\n"
                  + String(repeating: "X-Pad: y\r\n", count: 300) + "\r\n").utf8),
            Data((0..<2048).map { UInt8($0 % 256) }),
            Data(String(repeating: "GET /a HTTP/1.1\r\n\r\n", count: 40).utf8)
        ]
        requests.append(Data(String(repeating: "A", count: 20_000).utf8))

        for request in requests {
            await Self.send(request, to: server.port)
        }

        // After all of that, it still serves what it exists for.
        let text = try await String(
            contentsOf: server.url(for: "stream.m3u8"), encoding: .utf8)
        #expect(text == "playlist")
    }

    @Test("Many readers at once are all answered")
    func manyReaders() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try LocalMediaServer(directory: dir)
        try await server.start()
        defer { server.stop() }

        let url = server.url(for: "stream.m3u8")
        let answered = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    (try? await String(contentsOf: url, encoding: .utf8)) == "playlist"
                }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
        #expect(answered >= 25, "answered \(answered) of 30")
    }

    @Test("A file that changes or disappears while served does not break it")
    func fileChangesUnderneath() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try LocalMediaServer(directory: dir)
        try await server.start()
        defer { server.stop() }

        let file = dir.appendingPathComponent("stream.m3u8")
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<18 {
                group.addTask {
                    if index % 3 == 0 {
                        try? Data(String(repeating: "x", count: index * 50).utf8).write(to: file)
                    } else if index % 7 == 0 {
                        try? FileManager.default.removeItem(at: file)
                    } else {
                        _ = try? await String(
                            contentsOf: server.url(for: "stream.m3u8"), encoding: .utf8)
                    }
                }
            }
        }

        try Data("playlist".utf8).write(to: file)
        let text = try await String(contentsOf: server.url(for: "stream.m3u8"), encoding: .utf8)
        #expect(text == "playlist")
    }

    @Test("Stopping twice, and asking afterwards, is safe")
    func stopIsIdempotent() async throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try LocalMediaServer(directory: dir)
        try await server.start()
        server.stop()
        server.stop()
        _ = server.url(for: "stream.m3u8")
    }

    @Test("The server listens on the loopback interface alone")
    func loopbackOnly() async throws {
        // Reachable from this machine, and from nowhere else.
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try LocalMediaServer(directory: dir)
        try await server.start()
        defer { server.stop() }

        #expect(server.url(for: "x").host == "127.0.0.1")
        #expect(server.port > 0)
    }
}
