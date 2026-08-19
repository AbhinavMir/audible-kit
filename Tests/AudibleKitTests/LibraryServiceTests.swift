import Foundation
import Testing
@testable import AudibleKit

@Suite("Library")
struct LibraryServiceTests {

    private func makeClient(_ transport: StubTransport) throws -> AudibleClient {
        try AudibleClient(
            store: InMemoryCredentialStore(identity: .testIdentity()),
            transport: transport)
    }

    @Test("A full library item maps onto the model")
    func mapsFullItem() async throws {
        let transport = StubTransport(body: Fixtures.libraryPage)
        let books = try await LibraryService(client: makeClient(transport)).page(1)
        let book = try #require(books.first)

        #expect(book.asin == "B0TEST0001")
        #expect(book.title == "The Long Walk Home")
        #expect(book.subtitle == "A Novel")
        #expect(book.authors == ["Ada Marsh"])
        #expect(book.narratorLine == "Colin Reeve, Jean Okoro")
        #expect(book.series?.name == "Wayfarer")
        #expect(book.series?.sortIndex == 2)
        #expect(book.publisher == "Harbour Audio")
        #expect(book.isFinished)
    }

    @Test("Runtime in minutes becomes seconds")
    func convertsRuntime() async throws {
        let transport = StubTransport(body: Fixtures.libraryPage)
        let books = try await LibraryService(client: makeClient(transport)).page(1)
        #expect(books[0].duration == TimeInterval(611 * 60))
    }

    @Test("A title with no reported length has no duration, not zero")
    func absentRuntimeStaysAbsent() async throws {
        let transport = StubTransport(body: Fixtures.libraryPage)
        let books = try await LibraryService(client: makeClient(transport)).page(1)
        #expect(books[1].duration == nil)
    }

    @Test("The widest cover image wins")
    func picksLargestCover() async throws {
        let transport = StubTransport(body: Fixtures.libraryPage)
        let books = try await LibraryService(client: makeClient(transport)).page(1)
        #expect(books[0].coverURL?.absoluteString == "https://example.invalid/cover1215.jpg")
    }

    @Test("A sparse item still decodes")
    func decodesSparseItem() async throws {
        let transport = StubTransport(body: Fixtures.libraryPage)
        let books = try await LibraryService(client: makeClient(transport)).page(1)
        let sparse = books[1]
        #expect(sparse.title == "Sparse Record")
        #expect(sparse.authors.isEmpty)
        #expect(sparse.series == nil)
        #expect(sparse.coverURL == nil)
        #expect(!sparse.isFinished)
    }

    @Test("The request is signed and asks for the response groups")
    func requestIsSignedAndScoped() async throws {
        let transport = StubTransport(body: Fixtures.libraryPage)
        _ = try await LibraryService(client: makeClient(transport)).page(2)
        let request = try #require(transport.lastRequest)
        let url = try #require(request.url?.absoluteString)

        #expect(url.contains("api.audible.com/1.0/library"))
        #expect(url.contains("page=2"))
        #expect(url.contains("num_results=250"))
        #expect(url.contains("response_groups=contributors"))
        #expect(request.value(forHTTPHeaderField: "x-adp-signature") != nil)
        #expect(request.value(forHTTPHeaderField: "x-adp-token") == "{enc:test}")
    }

    @Test("Paging stops on a short page")
    func stopsOnShortPage() async throws {
        let transport = StubTransport(body: Fixtures.libraryPage)
        let books = try await LibraryService(client: makeClient(transport)).all()
        #expect(books.count == 2)
        #expect(transport.requestCount == 1)
    }

    @Test("An empty library yields no titles and no error")
    func emptyLibrary() async throws {
        let transport = StubTransport(body: Fixtures.emptyLibraryPage)
        let books = try await LibraryService(client: makeClient(transport)).all()
        #expect(books.isEmpty)
    }

    @Test("A 429 surfaces the retry delay")
    func reportsRateLimit() async throws {
        let transport = StubTransport(replies: [
            .init(status: 429, body: Data(), headers: ["Retry-After": "12"])
        ])
        let service = LibraryService(client: try makeClient(transport))
        await #expect(throws: AudibleError.rateLimited(retryAfter: 12)) {
            _ = try await service.page(1)
        }
    }

    @Test("A 401 refreshes the token once and retries")
    func refreshesOnceThenRetries() async throws {
        let transport = StubTransport(replies: [
            .init(status: 401, body: Data()),
            .init(status: 200, body: Fixtures.refreshedToken),
            .init(status: 200, body: Fixtures.libraryPage)
        ])
        let books = try await LibraryService(client: makeClient(transport)).page(1)
        #expect(books.count == 2)
        #expect(transport.requestCount == 3)
    }

    @Test("A second 401 gives up instead of looping")
    func stopsAfterSecondRejection() async throws {
        let transport = StubTransport(replies: [
            .init(status: 401, body: Data()),
            .init(status: 200, body: Fixtures.refreshedToken),
            .init(status: 401, body: Data())
        ])
        let service = LibraryService(client: try makeClient(transport))
        await #expect(throws: AudibleError.tokenExpired) {
            _ = try await service.page(1)
        }
        #expect(transport.requestCount == 3)
    }

    @Test("A client with no stored identity refuses to start")
    func requiresRegistration() {
        #expect(throws: AudibleError.notRegistered) {
            _ = try AudibleClient(
                store: InMemoryCredentialStore(),
                transport: StubTransport(body: Data()))
        }
    }
}
