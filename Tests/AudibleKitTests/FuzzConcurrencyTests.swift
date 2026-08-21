import Foundation
import Testing
@testable import AudibleKit

/// Runs the shared pieces from many places at once.
@Suite("Fuzzing things used from several places at once")
struct ConcurrencyFuzzTests {

    @Test("A credential store read from everywhere at once stays consistent")
    func credentialStoreUnderLoad() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        try store.save(.testIdentity(marketplace: .uk))

        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<60 {
                group.addTask {
                    if index % 8 == 0 {
                        try? store.save(.testIdentity(marketplace: .germany))
                        return true
                    }
                    // Whatever a reader gets, it must be a whole identity.
                    guard let identity = (try? store.load()) ?? nil else { return true }
                    return !identity.adpToken.isEmpty
                        && !identity.devicePrivateKey.isEmpty
                        && !identity.customerID.isEmpty
                }
            }
            for await whole in group { #expect(whole) }
        }
    }

    @Test("One signer used from many places at once produces valid signatures")
    func signerUnderLoad() async throws {
        let signer = try RequestSigner(
            adpToken: "{enc:t}", privateKeyPEM: TestKeys.rsa2048PKCS1)

        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<50 {
                group.addTask {
                    var request = URLRequest(
                        url: URL(string: "https://api.audible.com/1.0/library?p=\(index)")!)
                    request.httpMethod = "GET"
                    do {
                        try signer.sign(&request)
                    } catch {
                        return false
                    }
                    guard let header = request.value(
                        forHTTPHeaderField: RequestSigner.signatureHeader) else { return false }
                    let parts = header.split(separator: ":", maxSplits: 1)
                    // A 2048 bit key signs to exactly 256 bytes. Anything else
                    // means two signings interfered with each other.
                    return parts.count == 2
                        && Data(base64Encoded: String(parts[0]))?.count == 256
                }
            }
            for await valid in group { #expect(valid) }
        }
    }

    @Test("A token refresh asked for from everywhere at once stores one identity")
    func refreshUnderLoad() async throws {
        let store = InMemoryCredentialStore(identity: .testIdentity())
        let transport = HostileTransport(
            Array(repeating: HostileTransport.Behaviour.body(
                Data(#"{"access_token":"Atna|new","expires_in":3600}"#.utf8)), count: 80))
        let client = try AudibleClient(store: store, transport: transport)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask { try? await client.refreshAccessToken() }
            }
        }
        let identity = try #require(try store.load())
        #expect(identity.accessToken == "Atna|new")
        #expect(identity.accessTokenExpiry > Date())
    }

    @Test("An identifier with characters a URL treats specially still addresses one title")
    func awkwardIdentifiers() async throws {
        let awkward = ["B0 TEST", "B0/TEST", "B0?TEST", "B0#TEST", "B0%2F", "B0&a=b", ""]
        for asin in awkward {
            let transport = StubTransport(body: Data(#"{"items":[]}"#.utf8))
            let client = try AudibleClient(
                store: InMemoryCredentialStore(identity: .testIdentity()),
                transport: transport)
            _ = try? await CollectionService(client: client).remove(asin, from: "abc")

            guard let request = transport.lastRequest, let url = request.url else { continue }
            // The identifier belongs in the query, and must not become part of
            // the path or start another parameter.
            #expect(url.path == "/1.0/collections/abc/items", "asin: \(asin)")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.count == 1, "asin: \(asin) produced \(items.count) parameters")
            #expect(items.first?.value == asin)
        }
    }
}
