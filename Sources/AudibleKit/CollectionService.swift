import Foundation

/// A shelf on the Audible account. The same collections the mobile
/// application shows.
public struct AudibleCollection: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    public let description: String?
    /// How many titles it holds. Nil when the listing did not say.
    public let itemCount: Int?

    public init(id: String, name: String, description: String?, itemCount: Int? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.itemCount = itemCount
    }
}

/// Reads and changes the collections on an account.
///
/// Collections are the only organisation Audible itself stores. A shelf made
/// here appears in the mobile application, and one made there appears here.
///
/// The shapes below were found by trying them against a real account. Two are
/// worth stating, because guessing them wrong wastes a lot of time:
///
/// - Removing a title is `DELETE .../items?asins=<asin>`. The same call with
///   the ASIN in the path is refused, and with the ASIN in a body it fails in
///   the gateway.
/// - Adding a title with an `action` of `remove` adds it again. There is no
///   action field; the method and the query decide what happens.
public struct CollectionService: Sendable {
    private let client: AudibleClient

    public init(client: AudibleClient) {
        self.client = client
    }

    // MARK: Reading

    /// Every collection on the account.
    public func collections() async throws -> [AudibleCollection] {
        let data = try await client.send(method: "GET", path: "collections", body: nil)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listed = root["collections"] as? [[String: Any]]
        else {
            throw AudibleError.malformedResponse("The response held no collections.")
        }
        return listed.compactMap(CollectionService.collection(from:))
    }

    /// The ASINs a collection holds, in the order the server returns them.
    public func items(in collectionID: String) async throws -> [String] {
        let data = try await client.send(
            method: "GET", path: "collections/\(collectionID)/items", body: nil)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else {
            throw AudibleError.malformedResponse("The response held no items.")
        }
        return items.compactMap { $0["asin"] as? String }
    }

    // MARK: Changing

    /// Makes a new collection and returns it.
    public func create(name: String, description: String = "") async throws -> AudibleCollection {
        let data = try await client.send(
            method: "POST",
            path: "collections",
            body: try JSONSerialization.data(
                withJSONObject: ["name": name, "description": description],
                options: [.sortedKeys]))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["collection_id"] as? String
        else {
            throw AudibleError.malformedResponse("The collection was not created.")
        }
        return AudibleCollection(id: id, name: name, description: description, itemCount: 0)
    }

    /// Renames a collection, or changes its description.
    public func rename(
        _ collectionID: String,
        to name: String,
        description: String = ""
    ) async throws {
        _ = try await client.send(
            method: "PUT",
            path: "collections/\(collectionID)",
            body: try JSONSerialization.data(
                withJSONObject: ["name": name, "description": description],
                options: [.sortedKeys]))
    }

    /// Adds titles. Adding one that is already there is not an error.
    ///
    /// - Returns: How many the server says it added.
    @discardableResult
    public func add(_ asins: [String], to collectionID: String) async throws -> Int {
        // An empty identifier names no title, and a repeat asks twice for the
        // same thing. Neither belongs in a request that changes an account.
        var seen = Set<String>()
        let asins = asins
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !asins.isEmpty else { return 0 }
        let data = try await client.send(
            method: "POST",
            path: "collections/\(collectionID)/items",
            body: try JSONSerialization.data(
                withJSONObject: ["collection_id": collectionID, "asins": asins],
                options: [.sortedKeys]))
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (root?["num_items_added"] as? Int) ?? asins.count
    }

    /// Removes one title.
    ///
    /// The ASIN goes in the query. In the path the request is refused, and in
    /// a body it fails inside the gateway.
    public func remove(_ asin: String, from collectionID: String) async throws {
        // Without an identifier the request addresses the collection itself,
        // and the method is DELETE.
        let asin = asin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asin.isEmpty else {
            throw AudibleError.malformedResponse("A title to remove was not named.")
        }
        _ = try await client.send(
            method: "DELETE",
            path: "collections/\(collectionID)/items",
            query: ["asins": asin],
            body: nil)
    }

    /// Removes several titles, one request each.
    public func remove(_ asins: [String], from collectionID: String) async throws {
        for asin in asins {
            try await remove(asin, from: collectionID)
        }
    }

    /// Deletes a collection. The titles in it are untouched: a collection
    /// holds references, never audio.
    public func delete(_ collectionID: String) async throws {
        _ = try await client.send(
            method: "DELETE", path: "collections/\(collectionID)", body: nil)
    }

    // MARK: Parsing

    static func collection(from object: [String: Any]) -> AudibleCollection? {
        guard let id = object["collection_id"] as? String,
              let name = object["name"] as? String
        else { return nil }
        return AudibleCollection(
            id: id,
            name: name,
            description: object["description"] as? String,
            itemCount: object["total_count"] as? Int ?? object["num_items"] as? Int)
    }
}
