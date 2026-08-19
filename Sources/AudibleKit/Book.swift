import Foundation

/// One owned title.
public struct Book: Sendable, Identifiable, Hashable, Codable {
    /// Amazon Standard Identification Number. Identifies the title everywhere.
    public let asin: String
    public let title: String
    /// Subtitle, when the title has one.
    public let subtitle: String?
    public let authors: [String]
    public let narrators: [String]
    /// Series name and this title's place in it.
    public let series: SeriesEntry?
    public let publisher: String?
    /// Total length. Absent when the server did not report it.
    public let duration: TimeInterval?
    public let releaseDate: Date?
    public let coverURL: URL?
    public let purchaseDate: Date?
    /// True when Audible marks the title as finished.
    public let isFinished: Bool

    public var id: String { asin }

    /// Authors joined for display. Empty when the server listed none.
    public var authorLine: String { authors.joined(separator: ", ") }
    /// Narrators joined for display.
    public var narratorLine: String { narrators.joined(separator: ", ") }

    public init(
        asin: String,
        title: String,
        subtitle: String? = nil,
        authors: [String] = [],
        narrators: [String] = [],
        series: SeriesEntry? = nil,
        publisher: String? = nil,
        duration: TimeInterval? = nil,
        releaseDate: Date? = nil,
        coverURL: URL? = nil,
        purchaseDate: Date? = nil,
        isFinished: Bool = false
    ) {
        self.asin = asin
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.publisher = publisher
        self.duration = duration
        self.releaseDate = releaseDate
        self.coverURL = coverURL
        self.purchaseDate = purchaseDate
        self.isFinished = isFinished
    }
}

/// A title's membership in a series.
public struct SeriesEntry: Sendable, Hashable, Codable {
    public let asin: String
    public let name: String
    /// Position as the publisher states it. Often a number, sometimes not.
    public let position: String?

    public init(asin: String, name: String, position: String?) {
        self.asin = asin
        self.name = name
        self.position = position
    }

    /// Position as a number, for sorting. `nil` when it does not parse.
    public var sortIndex: Double? {
        position.flatMap(Double.init)
    }
}

/// One chapter of a title.
public struct Chapter: Sendable, Hashable, Codable {
    public let title: String
    /// Offset from the start of the title.
    public let start: TimeInterval
    public let duration: TimeInterval

    public init(title: String, start: TimeInterval, duration: TimeInterval) {
        self.title = title
        self.start = start
        self.duration = duration
    }

    public var end: TimeInterval { start + duration }
}
