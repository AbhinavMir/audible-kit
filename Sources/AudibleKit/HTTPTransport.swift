import Foundation
import CryptoKit

/// Sends one request and returns its response.
///
/// Every network call in AudibleKit goes through this protocol, so a test can
/// replace the network with recorded responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport, backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(URLSessionTransport.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudibleError.malformedResponse("The response was not HTTP.")
        }
        return (data, http)
    }

    /// Matches the Audible application the registration payload claims to be.
    static let userAgent = "Audible/671 CFNetwork/1240.0.4 Darwin/20.6.0"
}

extension Data {
    /// SHA-256 digest of these bytes.
    var sha256: Data {
        Data(SHA256.hash(data: self))
    }

    /// Base64 with the URL alphabet and no padding, as bytes.
    var base64URLEncoded: Data {
        Data(base64URLEncodedString().utf8)
    }

    /// Base64 with the URL alphabet and no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
