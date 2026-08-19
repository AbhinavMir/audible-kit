import Foundation

/// Every failure AudibleKit reports. Each case names a cause and, where the
/// caller can act, the recovery.
public enum AudibleError: Error, Sendable, Equatable {
    /// No device identity is stored. Register before calling the API.
    case notRegistered
    /// Device registration failed. The payload is the server explanation.
    case registrationFailed(String)
    /// The sign-in redirect carried no authorization code.
    case missingAuthorizationCode
    /// The server rejected the request signature. The device key or the
    /// signed payload is wrong.
    case signatureRejected
    /// The access token expired and the refresh attempt also failed.
    case tokenExpired
    /// The server refused a content license for this title.
    case licenseDenied(asin: String, reason: String)
    /// A download did not complete.
    case downloadFailed(String)
    /// The ffmpeg executable was not found.
    case ffmpegMissing
    /// Decryption ran but did not produce a usable file.
    case decryptFailed(String)
    /// The server asked the client to slow down.
    case rateLimited(retryAfter: TimeInterval?)
    /// The response did not match the expected shape.
    case malformedResponse(String)
    /// The server returned an unexpected status.
    case httpError(status: Int, body: String)
}

extension AudibleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "This device is not registered with Audible."
        case .registrationFailed(let detail):
            return "Device registration failed. \(detail)"
        case .missingAuthorizationCode:
            return "Sign-in finished without an authorization code."
        case .signatureRejected:
            return "Audible rejected the request signature."
        case .tokenExpired:
            return "The Audible session expired. Sign in again."
        case .licenseDenied(let asin, let reason):
            return "Audible refused a license for \(asin). \(reason)"
        case .downloadFailed(let detail):
            return "The download failed. \(detail)"
        case .ffmpegMissing:
            return "ffmpeg was not found. Install it with: brew install ffmpeg"
        case .decryptFailed(let detail):
            return "Decryption failed. \(detail)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Audible rate-limited the client. Retry after \(Int(retryAfter)) seconds."
            }
            return "Audible rate-limited the client."
        case .malformedResponse(let detail):
            return "The response could not be read. \(detail)"
        case .httpError(let status, _):
            return "Audible returned HTTP \(status)."
        }
    }
}
