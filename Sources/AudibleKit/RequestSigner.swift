import Foundation
import Security

/// Signs requests to the Audible content API with the device private key.
///
/// The server rejects a wrong signature with a bare 401, so the payload layout
/// below is the part of AudibleKit most worth testing directly.
public struct RequestSigner: Sendable {
    private let adpToken: String
    private let key: PrivateKeyBox

    /// Header name carrying the device ADP token.
    public static let adpTokenHeader = "x-adp-token"
    /// Header name carrying the signature algorithm.
    public static let algorithmHeader = "x-adp-alg"
    /// Header name carrying the signature and its timestamp.
    public static let signatureHeader = "x-adp-signature"
    /// The only algorithm the content API accepts.
    public static let algorithm = "SHA256withRSA:1.0"

    public init(adpToken: String, privateKeyPEM: String) throws {
        self.adpToken = adpToken
        self.key = PrivateKeyBox(try RequestSigner.parsePrivateKey(pem: privateKeyPEM))
    }

    /// Adds the three signing headers to `request`.
    ///
    /// - Parameters:
    ///   - request: The request to sign. Its URL, method, and body must be final.
    ///   - date: Timestamp to sign with. Injectable so tests are deterministic.
    public func sign(_ request: inout URLRequest, at date: Date = Date()) throws {
        guard let url = request.url else {
            throw AudibleError.malformedResponse("Request has no URL.")
        }
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let timestamp = RequestSigner.timestampFormatter.string(from: date)
        let payload = RequestSigner.signingPayload(
            method: method,
            path: RequestSigner.signedPath(of: url),
            timestamp: timestamp,
            body: body,
            adpToken: adpToken
        )
        let signature = try signature(over: Data(payload.utf8))

        request.setValue(adpToken, forHTTPHeaderField: RequestSigner.adpTokenHeader)
        request.setValue(RequestSigner.algorithm, forHTTPHeaderField: RequestSigner.algorithmHeader)
        request.setValue(
            "\(signature.base64EncodedString()):\(timestamp)",
            forHTTPHeaderField: RequestSigner.signatureHeader)
    }

    /// Joins the signed elements in the order the server expects.
    ///
    /// Exposed so a test can assert the layout without a key.
    public static func signingPayload(
        method: String,
        path: String,
        timestamp: String,
        body: String,
        adpToken: String
    ) -> String {
        [method, path, timestamp, body, adpToken].joined(separator: "\n")
    }

    /// The path and query the signature covers. The host is not signed.
    public static func signedPath(of url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path
        }
        let path = parts.path.isEmpty ? "/" : parts.path
        if let query = parts.percentEncodedQuery, !query.isEmpty {
            return "\(path)?\(query)"
        }
        return path
    }

    private func signature(over data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key.secKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error)
        else {
            let detail = (error?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "unknown reason"
            throw AudibleError.decryptFailed("Signing failed: \(detail)")
        }
        return signature as Data
    }

    /// Timestamps are UTC, millisecond precision, ISO 8601 with a trailing Z.
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}


/// Holds a `SecKey` across concurrency domains.
///
/// `SecKey` carries no Swift `Sendable` annotation, but signing with one is
/// thread-safe and the key is never mutated after it is created.
struct PrivateKeyBox: @unchecked Sendable {
    let secKey: SecKey
    init(_ secKey: SecKey) { self.secKey = secKey }
}
