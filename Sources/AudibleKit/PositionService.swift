import Foundation

/// Where a listener stopped in one title.
public struct ListeningPosition: Sendable, Hashable, Codable {
    public let asin: String
    /// Offset from the start of the title.
    public let position: TimeInterval
    /// When this position was recorded. Decides which side wins a conflict.
    public let recordedAt: Date

    public init(asin: String, position: TimeInterval, recordedAt: Date) {
        self.asin = asin
        self.position = position
        self.recordedAt = recordedAt
    }
}

/// Reads and writes the position Audible keeps for each title, which is what
/// the phone application reads when it resumes.
public struct PositionService: Sendable {
    private let client: AudibleClient

    /// How far ahead a remote position must be before it overrides a local one.
    ///
    /// Below this, the two sides are treated as the same place and the local
    /// position stands, so ordinary rounding never causes a jump.
    public static let conflictThreshold: TimeInterval = 60

    public init(client: AudibleClient) {
        self.client = client
    }

    /// Reads the recorded position for a set of titles.
    ///
    /// Titles the server holds no position for are absent from the result
    /// rather than present with a zero position.
    public func positions(for asins: [String]) async throws -> [String: ListeningPosition] {
        guard !asins.isEmpty else { return [:] }

        var result: [String: ListeningPosition] = [:]
        // The endpoint takes a bounded list, so ask in batches.
        for batch in asins.chunked(into: 50) {
            let data = try await client.send(
                method: "GET",
                path: "annotations/lastpositions",
                query: ["asins": batch.joined(separator: ",")],
                body: nil)
            for (asin, position) in try PositionService.parse(data) {
                result[asin] = position
            }
        }
        return result
    }

    /// The furthest into a title a position can be. Beyond this it is not a
    /// place in a book.
    static let longestTitle: TimeInterval = 60 * 60 * 24 * 7

    /// Records a position for one title.
    ///
    /// - Throws: `malformedResponse` when the position is not a real place. A
    ///   player that does not yet know where it is reports a value that is not
    ///   a number, and turning that into an integer ends the process.
    public func record(_ position: ListeningPosition) async throws {
        guard let milliseconds = PositionService.milliseconds(position.position) else {
            throw AudibleError.malformedResponse(
                "\(position.position) is not a place in a title.")
        }
        let body: [String: Any] = [
            "type": "LastHeard",
            "key": position.asin,
            "value": String(milliseconds)
        ]
        _ = try await client.send(
            method: "PUT",
            path: "annotations/lastpositions",
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }

    /// A place in a title as whole milliseconds, or nil when it is not one.
    static func milliseconds(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite, !seconds.isNaN else { return nil }
        guard seconds >= 0, seconds <= longestTitle else { return nil }
        return Int(seconds * 1000)
    }

    /// Decides which of two positions to keep.
    ///
    /// The later recording wins, and only when it is meaningfully further on.
    /// This keeps a stale desktop session from rewinding a phone.
    public static func resolve(
        local: ListeningPosition?,
        remote: ListeningPosition?
    ) -> ListeningPosition? {
        guard let local else { return remote }
        guard let remote else { return local }
        guard remote.recordedAt > local.recordedAt else { return local }
        guard abs(remote.position - local.position) > conflictThreshold else { return local }
        return remote
    }

    static func parse(_ data: Data) throws -> [String: ListeningPosition] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["asin_last_position_heard_annots"] as? [[String: Any]]
        else {
            throw AudibleError.malformedResponse("The response held no positions.")
        }

        var positions: [String: ListeningPosition] = [:]
        for entry in entries {
            guard let asin = entry["asin"] as? String,
                  let annotation = entry["last_position_heard"] as? [String: Any],
                  annotation["status"] as? String == "Exists",
                  let milliseconds = annotation["position_ms"] as? Double
            else { continue }

            let stamp = (annotation["last_updated"] as? String)
                .flatMap { ISO8601DateFormatter.withFraction.date(from: $0)
                    ?? ISO8601DateFormatter.withoutFraction.date(from: $0) }
            // A server can report a figure that is not a place in any book.
            // Keeping it would push a listener somewhere impossible.
            let seconds = milliseconds / 1000
            guard seconds.isFinite, seconds >= 0, seconds <= longestTitle else { continue }

            positions[asin] = ListeningPosition(
                asin: asin,
                position: seconds,
                // A position with no timestamp is treated as very old, so a
                // local position with a real timestamp wins over it.
                recordedAt: stamp ?? .distantPast)
        }
        return positions
    }
}

extension Array {
    /// Splits into runs of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
