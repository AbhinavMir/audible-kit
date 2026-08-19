import Foundation
@testable import AudibleKit

/// Answers requests from a queue of recorded responses and remembers what it
/// was asked. Nothing in the test suite touches the network.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int = 200, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply]) {
        self.replies = replies
    }

    convenience init(body: Data, status: Int = 200) {
        self.init(replies: [Reply(status: status, body: body)])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try nextReply(recording: request)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        return (reply.body, response)
    }

    /// Records the request and takes the next reply. Kept synchronous so the
    /// lock is never held across a suspension point.
    private func nextReply(recording request: URLRequest) throws -> Reply {
        try lock.withLock {
            requests.append(request)
            guard !replies.isEmpty else {
                throw AudibleError.downloadFailed("The stub ran out of replies.")
            }
            return replies.removeFirst()
        }
    }

    var lastRequest: URLRequest? {
        lock.withLock { requests.last }
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }
}

extension DeviceIdentity {
    /// An identity backed by the test key. Valid enough to sign with.
    static func testIdentity(marketplace: AudibleMarketplace = .us) -> DeviceIdentity {
        DeviceIdentity(
            adpToken: "{enc:test}",
            devicePrivateKey: TestKeys.rsa2048PKCS1,
            accessToken: "Atna|test",
            refreshToken: "Atnr|test",
            deviceSerialNumber: "0123456789ABCDEF0123456789ABCDEF01234567",
            customerID: "amzn1.account.TEST",
            marketplace: marketplace,
            accessTokenExpiry: Date().addingTimeInterval(3600))
    }
}
