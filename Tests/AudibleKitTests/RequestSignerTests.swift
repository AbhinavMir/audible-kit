import Foundation
import Testing
@testable import AudibleKit

@Suite("Request signing")
struct RequestSignerTests {

    /// A throwaway 2048-bit RSA key. It signs nothing real.
    static let testKeyPEM = TestKeys.rsa2048PKCS1
    static let adpToken = "{enc:testtoken}"

    @Test("Signed payload joins the five elements with newlines, in order")
    func payloadLayout() {
        let payload = RequestSigner.signingPayload(
            method: "GET",
            path: "/1.0/library",
            timestamp: "2026-08-19T12:00:00.000Z",
            body: "",
            adpToken: "TOKEN"
        )
        #expect(payload == "GET\n/1.0/library\n2026-08-19T12:00:00.000Z\n\nTOKEN")
    }

    @Test("The signed path keeps the query and drops the host")
    func signedPathKeepsQuery() {
        let url = URL(string: "https://api.audible.com/1.0/library?num_results=50&page=2")!
        #expect(RequestSigner.signedPath(of: url) == "/1.0/library?num_results=50&page=2")
    }

    @Test("A URL with no path signs as a single slash")
    func signedPathOfBareHost() {
        let url = URL(string: "https://api.audible.com")!
        #expect(RequestSigner.signedPath(of: url) == "/")
    }

    @Test("Timestamps are UTC with millisecond precision")
    func timestampFormat() {
        let date = Date(timeIntervalSince1970: 1_776_000_000)
        let stamped = RequestSigner.timestampFormatter.string(from: date)
        #expect(stamped.hasSuffix("Z"))
        #expect(stamped.count == 24)
    }

    @Test("Signing adds all three headers")
    func signingAddsHeaders() throws {
        let signer = try RequestSigner(
            adpToken: Self.adpToken, privateKeyPEM: Self.testKeyPEM)
        var request = URLRequest(url: URL(string: "https://api.audible.com/1.0/library")!)
        try signer.sign(&request, at: Date(timeIntervalSince1970: 1_776_000_000))

        #expect(request.value(forHTTPHeaderField: "x-adp-token") == Self.adpToken)
        #expect(request.value(forHTTPHeaderField: "x-adp-alg") == "SHA256withRSA:1.0")

        // The timestamp contains colons, so only the first colon separates
        // the signature from it.
        let header = try #require(request.value(forHTTPHeaderField: "x-adp-signature"))
        let parts = header.split(separator: ":", maxSplits: 1)
        #expect(parts.count == 2)
        #expect(Data(base64Encoded: String(parts[0]))?.count == 256)
        #expect(parts[1] == RequestSigner.timestampFormatter.string(
            from: Date(timeIntervalSince1970: 1_776_000_000)))
    }

    @Test("The same request and timestamp always sign identically")
    func signingIsDeterministic() throws {
        let signer = try RequestSigner(
            adpToken: Self.adpToken, privateKeyPEM: Self.testKeyPEM)
        let date = Date(timeIntervalSince1970: 1_776_000_000)
        let url = URL(string: "https://api.audible.com/1.0/library")!

        var first = URLRequest(url: url)
        var second = URLRequest(url: url)
        try signer.sign(&first, at: date)
        try signer.sign(&second, at: date)

        #expect(first.value(forHTTPHeaderField: "x-adp-signature")
                == second.value(forHTTPHeaderField: "x-adp-signature"))
    }

    @Test("A different body produces a different signature")
    func bodyChangesSignature() throws {
        let signer = try RequestSigner(
            adpToken: Self.adpToken, privateKeyPEM: Self.testKeyPEM)
        let date = Date(timeIntervalSince1970: 1_776_000_000)
        let url = URL(string: "https://api.audible.com/1.0/content/B0123/licenserequest")!

        var empty = URLRequest(url: url)
        empty.httpMethod = "POST"
        var filled = URLRequest(url: url)
        filled.httpMethod = "POST"
        filled.httpBody = Data(#"{"quality":"High"}"#.utf8)

        try signer.sign(&empty, at: date)
        try signer.sign(&filled, at: date)

        #expect(empty.value(forHTTPHeaderField: "x-adp-signature")
                != filled.value(forHTTPHeaderField: "x-adp-signature"))
    }

    @Test("A key that is not valid base64 is rejected")
    func rejectsGarbageKey() {
        #expect(throws: AudibleError.self) {
            _ = try RequestSigner(adpToken: "t", privateKeyPEM: "not a key")
        }
    }
}
