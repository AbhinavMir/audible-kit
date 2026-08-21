import Foundation
import Testing
@testable import AudibleKit

/// Exercises the calls that change something on the account.
///
/// A read that goes wrong shows the wrong thing. A write that goes wrong
/// changes the wrong thing, so these matter more.
@Suite("Fuzzing the calls that change something")
struct WriteFuzzTests {

    private func client(_ transport: StubTransport) throws -> AudibleClient {
        try AudibleClient(
            store: InMemoryCredentialStore(identity: .testIdentity()),
            transport: transport)
    }

    @Test("A position is sent as a whole number of milliseconds, always")
    func positionsAreWholeMilliseconds() async throws {
        let places: [TimeInterval] = [
            0, 0.0004, 0.5, 1, 1.9999, 59.999, 3600, 372.4,
            116_769.811655, 500_000
        ]
        for place in places {
            let transport = StubTransport(body: Data("{}".utf8))
            let service = PositionService(client: try client(transport))
            try await service.record(
                ListeningPosition(asin: "A", position: place, recordedAt: Date()))

            let body = try #require(transport.lastRequest?.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })
            let value = try #require(body["value"] as? String)
            // A server that is sent "372.4" or "3.7e5" stores nothing useful.
            #expect(Int(value) != nil, "sent \(value) for \(place)")
            #expect(!value.contains("."))
            #expect(!value.contains("e"))
            #expect((Int(value) ?? -1) >= 0)
        }
    }

    @Test("A position that is not a real place is not sent as one")
    func absurdPositionsDoNotBecomeRubbish() async throws {
        for place in [TimeInterval.nan, .infinity, -.infinity, -1, -1e9] {
            let transport = StubTransport(body: Data("{}".utf8))
            let service = PositionService(client: try client(transport))
            _ = try? await service.record(
                ListeningPosition(asin: "A", position: place, recordedAt: Date()))

            // Nothing may be sent at all for a place that is not one.
            guard let body = transport.lastRequest?.httpBody.flatMap({
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }), let value = body["value"] as? String else { continue }

            // Whatever is sent must be a number a server can store.
            #expect(Int(value) != nil, "sent \(value) for \(place)")
            #expect((Int(value) ?? -1) >= 0, "sent \(value) for \(place)")
        }
    }

    @Test("Adding to a collection sends every title once")
    func addSendsEachTitleOnce() async throws {
        let transport = StubTransport(body: Data(#"{"num_items_added":3}"#.utf8))
        let service = CollectionService(client: try client(transport))
        _ = try await service.add(["A", "A", "B", "", "C"], to: "abc")

        let body = try #require(transport.lastRequest?.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        let asins = try #require(body["asins"] as? [String])
        #expect(!asins.contains(""), "an empty identifier was sent")
        #expect(Set(asins).count == asins.count, "a title was sent twice")
    }

    @Test("Removing one title never addresses a whole collection")
    func removeNeverTargetsTheCollection() async throws {
        // A request that drops the identifier would address the collection
        // itself, and the method is DELETE.
        for asin in ["", " ", "A"] {
            let transport = StubTransport(body: Data("{}".utf8))
            let service = CollectionService(client: try client(transport))
            _ = try? await service.remove(asin, from: "abc")

            // A removal with no identifier is refused before it is sent.
            guard let url = transport.lastRequest?.url else {
                #expect(asin.trimmingCharacters(in: .whitespaces).isEmpty)
                continue
            }
            #expect(url.path.hasSuffix("/items"), "addressed \(url.path)")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(items?.first?.name == "asins")
            #expect(items?.first?.value?.isEmpty == false,
                    "a removal with no identifier was sent")
        }
    }

    @Test("A collection is renamed with a name a server will take")
    func renameSendsAName() async throws {
        for name in ["", " ", String(repeating: "n", count: 5_000), "🎧", "a\nb"] {
            let transport = StubTransport(body: Data("{}".utf8))
            let service = CollectionService(client: try client(transport))
            _ = try? await service.rename("abc", to: name)

            guard let body = transport.lastRequest?.httpBody.flatMap({
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }) else { continue }
            #expect(body["name"] as? String != nil)
        }
    }
}
