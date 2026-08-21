import Foundation

/// Lists the titles the account owns.
public struct LibraryService: Sendable {
    private let client: AudibleClient

    /// Titles per request. The API caps this at 1000.
    public static let pageSize = 250
    /// The most pages one listing will ask for.
    ///
    /// Paging stops when a page comes back short. A server that answers every
    /// page with a full one would otherwise be followed forever, so there is
    /// an end to it. This allows a library far larger than any real one.
    public static let pageLimit = 100

    /// Fields the API includes only when asked.
    static let responseGroups = [
        "contributors", "product_desc", "product_attrs", "product_extended_attrs",
        "media", "series", "is_finished", "product_details"
    ].joined(separator: ",")

    public init(client: AudibleClient) {
        self.client = client
    }

    /// Fetches every owned title, one page at a time.
    ///
    /// The sequence yields each page as it arrives, so a caller can show the
    /// first titles without waiting for a large library to finish.
    public func pages() -> AsyncThrowingStream<[Book], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var page = 1
                    var seen = Set<String>()
                    while !Task.isCancelled, page <= LibraryService.pageLimit {
                        let books = try await self.page(page)
                        if books.isEmpty { break }

                        // A server that repeats a page rather than advancing
                        // would be followed forever. Titles already seen mean
                        // the end has been reached.
                        let fresh = books.filter { seen.insert($0.asin).inserted }
                        if fresh.isEmpty { break }
                        continuation.yield(fresh)

                        if books.count < LibraryService.pageSize { break }
                        page += 1
                    }
                    if page > LibraryService.pageLimit {
                        Log.write("Stopped listing at \(LibraryService.pageLimit) pages.")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetches every owned title and returns them together.
    public func all() async throws -> [Book] {
        var books: [Book] = []
        for try await page in pages() { books.append(contentsOf: page) }
        return books
    }

    /// Fetches one page, numbered from 1.
    public func page(_ number: Int) async throws -> [Book] {
        let response = try await client.get(
            "library",
            query: [
                "num_results": String(LibraryService.pageSize),
                "page": String(number),
                "response_groups": LibraryService.responseGroups,
                "sort_by": "-PurchaseDate"
            ],
            as: LibraryResponse.self)
        return response.items.map(\.book)
    }

    /// Fetches one title by ASIN.
    public func book(asin: String) async throws -> Book {
        let response = try await client.get(
            "library/\(asin)",
            query: ["response_groups": LibraryService.responseGroups],
            as: SingleItemResponse.self)
        return response.item.book
    }
}

// MARK: - Wire shapes

/// The library endpoint's response. These types exist only to decode the wire
/// format; `Book` is what the rest of the package uses.
struct LibraryResponse: Decodable {
    let items: [LibraryItem]
}

struct SingleItemResponse: Decodable {
    let item: LibraryItem
}

struct LibraryItem: Decodable {
    let asin: String
    let title: String
    let subtitle: String?
    let authors: [Contributor]?
    let narrators: [Contributor]?
    let seriesPrimary: SeriesMembership?
    let series: [SeriesMembership]?
    let publisherName: String?
    let runtimeLengthMin: Int?
    let releaseDate: Date?
    let purchaseDate: Date?
    let productImages: [String: String]?
    let isFinished: Bool?

    struct Contributor: Decodable {
        let name: String
    }

    struct SeriesMembership: Decodable {
        let asin: String
        let title: String
        let sequence: String?
    }

    /// Maps the wire shape onto the model.
    var book: Book {
        Book(
            asin: asin,
            title: title,
            subtitle: subtitle,
            authors: authors?.map(\.name) ?? [],
            narrators: narrators?.map(\.name) ?? [],
            series: (seriesPrimary ?? series?.first).map {
                SeriesEntry(asin: $0.asin, name: $0.title, position: $0.sequence)
            },
            publisher: publisherName,
            // The API reports whole minutes. A title with no reported length
            // stays nil rather than claiming zero.
            duration: runtimeLengthMin.map { TimeInterval($0 * 60) },
            releaseDate: releaseDate,
            coverURL: LibraryItem.largestImage(in: productImages),
            purchaseDate: purchaseDate,
            isFinished: isFinished ?? false
        )
    }

    /// Product images arrive keyed by pixel width. Pick the widest.
    static func largestImage(in images: [String: String]?) -> URL? {
        guard let images, !images.isEmpty else { return nil }
        let widest = images
            .compactMap { key, value in Int(key).map { ($0, value) } }
            .max { $0.0 < $1.0 }
        return (widest?.1).flatMap(URL.init(string:))
    }
}
