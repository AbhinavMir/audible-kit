import Foundation
import Testing
@testable import AudibleKit

@Suite("Positions")
struct PositionServiceTests {

    static let response = Data("""
    {
      "asin_last_position_heard_annots": [
        {
          "asin": "B0TEST0001",
          "last_position_heard": {
            "position_ms": 372000,
            "status": "Exists",
            "last_updated": "2026-08-18T21:04:11.000Z"
          }
        },
        {
          "asin": "B0TEST0002",
          "last_position_heard": {"status": "DoesNotExist"}
        },
        {
          "asin": "B0TEST0003",
          "last_position_heard": {"position_ms": 1000, "status": "Exists"}
        }
      ]
    }
    """.utf8)

    private func makeClient(_ transport: StubTransport) throws -> AudibleClient {
        try AudibleClient(
            store: InMemoryCredentialStore(identity: .testIdentity()),
            transport: transport)
    }

    @Test("A recorded position comes back in seconds with its timestamp")
    func parsesPosition() async throws {
        let service = PositionService(client: try makeClient(StubTransport(body: Self.response)))
        let positions = try await service.positions(for: ["B0TEST0001"])
        let position = try #require(positions["B0TEST0001"])
        #expect(position.position == 372)
        #expect(position.recordedAt > Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test("A title with no recorded position is absent, not zero")
    func skipsMissingPositions() async throws {
        let service = PositionService(client: try makeClient(StubTransport(body: Self.response)))
        let positions = try await service.positions(for: ["B0TEST0002"])
        #expect(positions["B0TEST0002"] == nil)
    }

    @Test("A position with no timestamp is treated as very old")
    func undatedPositionIsOld() async throws {
        let service = PositionService(client: try makeClient(StubTransport(body: Self.response)))
        let positions = try await service.positions(for: ["B0TEST0003"])
        #expect(positions["B0TEST0003"]?.recordedAt == .distantPast)
    }

    @Test("An empty request asks the server nothing")
    func skipsEmptyRequest() async throws {
        let transport = StubTransport(body: Self.response)
        let positions = try await PositionService(client: makeClient(transport)).positions(for: [])
        #expect(positions.isEmpty)
        #expect(transport.requestCount == 0)
    }

    @Test("Large sets are asked for in batches")
    func batchesLargeRequests() async throws {
        let transport = StubTransport(replies: [
            .init(body: Self.response), .init(body: Self.response), .init(body: Self.response)
        ])
        let asins = (1...120).map { String(format: "B0TEST%04d", $0) }
        _ = try await PositionService(client: makeClient(transport)).positions(for: asins)
        #expect(transport.requestCount == 3)
    }

    @Test("Recording sends milliseconds")
    func recordSendsMilliseconds() async throws {
        let transport = StubTransport(body: Data("{}".utf8))
        let service = PositionService(client: try makeClient(transport))
        try await service.record(
            ListeningPosition(asin: "B0TEST0001", position: 372.4, recordedAt: Date()))

        let request = try #require(transport.lastRequest)
        let body = try #require(request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(request.httpMethod == "PUT")
        #expect(body["value"] as? String == "372400")
        #expect(body["key"] as? String == "B0TEST0001")
    }

    // MARK: Conflict resolution

    @Test("A later remote position further on wins")
    func laterRemoteWins() {
        let local = ListeningPosition(asin: "A", position: 100, recordedAt: .distantPast)
        let remote = ListeningPosition(asin: "A", position: 900, recordedAt: Date())
        #expect(PositionService.resolve(local: local, remote: remote)?.position == 900)
    }

    @Test("An older remote position never rewinds a newer local one")
    func olderRemoteLoses() {
        let local = ListeningPosition(asin: "A", position: 900, recordedAt: Date())
        let remote = ListeningPosition(asin: "A", position: 100, recordedAt: .distantPast)
        #expect(PositionService.resolve(local: local, remote: remote)?.position == 900)
    }

    @Test("A remote position within the threshold leaves the local one alone")
    func smallDifferenceKeepsLocal() {
        let local = ListeningPosition(asin: "A", position: 900, recordedAt: Date())
        let remote = ListeningPosition(
            asin: "A", position: 930, recordedAt: Date().addingTimeInterval(5))
        #expect(PositionService.resolve(local: local, remote: remote)?.position == 900)
    }

    @Test("With one side missing, the other is used")
    func handlesMissingSides() {
        let position = ListeningPosition(asin: "A", position: 42, recordedAt: Date())
        #expect(PositionService.resolve(local: nil, remote: position)?.position == 42)
        #expect(PositionService.resolve(local: position, remote: nil)?.position == 42)
        #expect(PositionService.resolve(local: nil, remote: nil) == nil)
    }
}
