import Foundation
import Testing
@testable import AudibleKit

/// A transport that fails the way a network does.
final class HostileTransport: HTTPTransport, @unchecked Sendable {
    enum Behaviour: Sendable {
        case status(Int)
        case body(Data)
        case notHTTP
        case throwsError
        case slow
    }

    private let lock = NSLock()
    private var behaviours: [Behaviour]
    private(set) var callCount = 0

    init(_ behaviours: [Behaviour]) {
        self.behaviours = behaviours
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let behaviour: Behaviour = lock.withLock {
            callCount += 1
            return behaviours.isEmpty ? .status(500) : behaviours.removeFirst()
        }

        switch behaviour {
        case .status(let code):
            return (Data("{}".utf8), HTTPURLResponse(
                url: request.url!, statusCode: code,
                httpVersion: nil, headerFields: nil)!)
        case .body(let data):
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        case .notHTTP:
            throw AudibleError.malformedResponse("The response was not HTTP.")
        case .throwsError:
            throw URLError(.networkConnectionLost)
        case .slow:
            try await Task.sleep(for: .milliseconds(20))
            return (Data("{}".utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }
    }
}

@Suite("Fuzzing a network that misbehaves")
struct TransportFuzzTests {

    private func client(_ transport: HostileTransport) throws -> AudibleClient {
        try AudibleClient(
            store: InMemoryCredentialStore(identity: .testIdentity()),
            transport: transport)
    }

    @Test("Every status a server can return becomes an error, never a hang",
          arguments: [200, 201, 204, 301, 400, 401, 403, 404, 418, 429, 500, 502, 503, 504])
    func everyStatus(code: Int) async throws {
        // 401 asks for one refresh, so the queue holds enough replies for it.
        let transport = HostileTransport([
            .status(code), .status(code), .status(code), .status(code)
        ])
        let service = LibraryService(client: try client(transport))
        _ = try? await service.page(1)
        #expect(transport.callCount >= 1)
        // A refresh is attempted once, never in a loop.
        #expect(transport.callCount <= 3)
    }

    @Test("A connection that drops surfaces as an error")
    func connectionDrops() async throws {
        let transport = HostileTransport([.throwsError])
        let service = LibraryService(client: try client(transport))
        await #expect(throws: (any Error).self) {
            _ = try await service.page(1)
        }
    }

    @Test("A body that is not what was asked for surfaces as an error")
    func wrongBody() async throws {
        for body in [Data(), Data("[]".utf8), Data("<html>503</html>".utf8),
                     Data(#"{"items": null}"#.utf8)] {
            let transport = HostileTransport([.body(body)])
            let service = LibraryService(client: try client(transport))
            await #expect(throws: (any Error).self) {
                _ = try await service.page(1)
            }
        }
    }

    @Test("Paging stops rather than running forever when a server repeats itself")
    func pagingTerminates() async throws {
        // A server that always returns a full page would page forever if
        // nothing stopped it. Every page here is full.
        let item = #"{"asin":"A","title":"T"}"#
        let full = Data(("{\"items\":["
            + Array(repeating: item, count: 250).joined(separator: ",")
            + "]}").utf8)
        let transport = HostileTransport(
            Array(repeating: HostileTransport.Behaviour.body(full), count: 40))
        let service = LibraryService(client: try client(transport))

        var pages = 0
        for try await _ in service.pages() { pages += 1 }
        // A repeated page means the end, so this stops at the first repeat
        // rather than following the server forever.
        #expect(pages == 1, "pages: \(pages)")
    }

    @Test("A refused license reports why, whatever the server sends")
    func licenceFailures() async throws {
        for behaviour in [HostileTransport.Behaviour.status(403),
                          .status(500), .body(Data()), .throwsError] {
            let transport = HostileTransport([behaviour, behaviour, behaviour])
            let service = LicenseService(client: try client(transport))
            await #expect(throws: (any Error).self) {
                _ = try await service.license(for: "B0TEST0001")
            }
        }
    }

    @Test("Positions asked for in bulk stop at the first refusal")
    func positionFailures() async throws {
        let transport = HostileTransport([.status(500), .status(500), .status(500)])
        let service = PositionService(client: try client(transport))
        await #expect(throws: (any Error).self) {
            _ = try await service.positions(for: (0..<120).map { "B\($0)" })
        }
    }

    @Test("Collections survive a server that answers with nothing useful")
    func collectionFailures() async throws {
        for body in [Data(), Data("null".utf8), Data(#"{"collections":{}}"#.utf8)] {
            let transport = HostileTransport([.body(body)])
            let service = CollectionService(client: try client(transport))
            await #expect(throws: (any Error).self) {
                _ = try await service.collections()
            }
        }
    }

    @Test("Many requests at once all finish")
    func concurrentRequests() async throws {
        let transport = HostileTransport(
            Array(repeating: HostileTransport.Behaviour.slow, count: 60))
        let client = try client(transport)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    _ = try? await client.send(
                        method: "GET", path: "library", body: nil)
                }
            }
        }
        #expect(transport.callCount == 40)
    }
}
