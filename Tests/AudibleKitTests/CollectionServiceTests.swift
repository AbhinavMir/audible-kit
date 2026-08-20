import Foundation
import Testing
@testable import AudibleKit

@Suite("Collections")
struct CollectionServiceTests {

    private func makeClient(_ transport: StubTransport) throws -> AudibleClient {
        try AudibleClient(
            store: InMemoryCredentialStore(identity: .testIdentity()),
            transport: transport)
    }

    static let listing = Data("""
    {
      "collections": [
        {"collection_id": "abc-123", "name": "Reading", "description": "Now",
         "visibility_type": "Private"},
        {"collection_id": "def-456", "name": "Favourites", "description": null}
      ],
      "total_count": 2
    }
    """.utf8)

    static let items = Data("""
    {
      "items": [{"asin": "B0TEST0001"}, {"asin": "B0TEST0002"}],
      "state_token": "abc"
    }
    """.utf8)

    @Test("Collections come back with their names and identifiers")
    func listsCollections() async throws {
        let service = CollectionService(client: try makeClient(StubTransport(body: Self.listing)))
        let collections = try await service.collections()
        #expect(collections.count == 2)
        #expect(collections[0].name == "Reading")
        #expect(collections[0].id == "abc-123")
        #expect(collections[1].description == nil)
    }

    @Test("A collection's titles come back as ASINs")
    func listsItems() async throws {
        let service = CollectionService(client: try makeClient(StubTransport(body: Self.items)))
        #expect(try await service.items(in: "abc-123") == ["B0TEST0001", "B0TEST0002"])
    }

    @Test("Creating a collection sends the name and returns the identifier")
    func createsCollection() async throws {
        let transport = StubTransport(body: Data(
            #"{"collection_id":"new-1","visibility_type":"Private"}"#.utf8))
        let created = try await CollectionService(client: makeClient(transport))
            .create(name: "Reading", description: "Now")

        #expect(created.id == "new-1")
        #expect(created.name == "Reading")

        let request = try #require(transport.lastRequest)
        let body = try #require(request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(request.httpMethod == "POST")
        #expect(body["name"] as? String == "Reading")
    }

    @Test("Adding titles reports how many the server took")
    func addsItems() async throws {
        let transport = StubTransport(body: Data(#"{"num_items_added":3}"#.utf8))
        let added = try await CollectionService(client: makeClient(transport))
            .add(["A", "B", "C"], to: "abc-123")
        #expect(added == 3)

        let body = try #require(transport.lastRequest?.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(body["asins"] as? [String] == ["A", "B", "C"])
        #expect(body["collection_id"] as? String == "abc-123")
    }

    @Test("Adding nothing asks the server nothing")
    func addingNothingIsFree() async throws {
        let transport = StubTransport(body: Data("{}".utf8))
        let added = try await CollectionService(client: makeClient(transport)).add([], to: "abc")
        #expect(added == 0)
        #expect(transport.requestCount == 0)
    }

    @Test("Removing a title puts the ASIN in the query, not the path")
    func removesItem() async throws {
        // The same call with the ASIN in the path is refused, and with the
        // ASIN in a body it fails inside the gateway.
        let transport = StubTransport(body: Data("{}".utf8))
        try await CollectionService(client: makeClient(transport))
            .remove("B0TEST0001", from: "abc-123")

        let request = try #require(transport.lastRequest)
        let url = try #require(request.url?.absoluteString)
        #expect(request.httpMethod == "DELETE")
        #expect(url.contains("collections/abc-123/items"))
        #expect(url.contains("asins=B0TEST0001"))
        #expect(!url.contains("items/B0TEST0001"))
        #expect(request.httpBody == nil)
    }

    @Test("Removing several titles sends one request each")
    func removesManyItems() async throws {
        let transport = StubTransport(replies: (0..<3).map { _ in
            .init(body: Data("{}".utf8))
        })
        try await CollectionService(client: makeClient(transport))
            .remove(["A", "B", "C"], from: "abc-123")
        #expect(transport.requestCount == 3)
    }

    @Test("Renaming sends the new name")
    func renamesCollection() async throws {
        let transport = StubTransport(body: Data(#"{"name":"Later"}"#.utf8))
        try await CollectionService(client: makeClient(transport))
            .rename("abc-123", to: "Later")

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "PUT")
        let body = try #require(request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(body["name"] as? String == "Later")
    }

    @Test("Deleting a collection addresses the collection alone")
    func deletesCollection() async throws {
        let transport = StubTransport(body: Data("".utf8))
        try await CollectionService(client: makeClient(transport)).delete("abc-123")

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString.hasSuffix("collections/abc-123") == true)
    }

    @Test("A response without collections is an error, not an empty shelf")
    func rejectsMalformedListing() async throws {
        let service = CollectionService(
            client: try makeClient(StubTransport(body: Data(#"{"unexpected":1}"#.utf8))))
        await #expect(throws: AudibleError.self) {
            _ = try await service.collections()
        }
    }
}
