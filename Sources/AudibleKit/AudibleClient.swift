import Foundation

/// The one type that talks to the Audible content API.
///
/// It signs every request, refreshes an expired access token once, and turns
/// failure statuses into `AudibleError`. The services above it hold no
/// transport logic, so each can be tested against a stub transport.
public actor AudibleClient {
    private let store: CredentialStore
    private let transport: HTTPTransport
    private var identity: DeviceIdentity
    private var signer: RequestSigner

    /// Creates a client from a stored identity.
    ///
    /// - Throws: `AudibleError.notRegistered` when no identity is stored.
    public init(store: CredentialStore, transport: HTTPTransport = URLSessionTransport()) throws {
        guard let identity = try store.load() else { throw AudibleError.notRegistered }
        self.store = store
        self.transport = transport
        self.identity = identity
        self.signer = try RequestSigner(
            adpToken: identity.adpToken, privateKeyPEM: identity.devicePrivateKey)
    }

    /// The storefront this client speaks to.
    public var marketplace: AudibleMarketplace { identity.marketplace }
    /// The signed-in customer.
    public var customerID: String { identity.customerID }
    /// The serial this device registered with. The voucher key derives from it.
    public var deviceSerialNumber: String { identity.deviceSerialNumber }

    // MARK: Requests

    /// Sends a signed GET and decodes the response.
    public func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        let data = try await send(method: "GET", path: path, query: query, body: nil)
        return try decode(type, from: data)
    }

    /// Sends a signed POST and decodes the response.
    public func post<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any],
        as type: T.Type
    ) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data = try await send(method: "POST", path: path, query: query, body: payload)
        return try decode(type, from: data)
    }

    /// Sends a signed request and returns the raw body.
    public func send(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data?
    ) async throws -> Data {
        do {
            return try await perform(method: method, path: path, query: query, body: body)
        } catch AudibleError.tokenExpired {
            try await refreshAccessToken()
            return try await perform(method: method, path: path, query: query, body: body)
        }
    }

    private func perform(
        method: String,
        path: String,
        query: [String: String],
        body: Data?
    ) async throws -> Data {
        var components = URLComponents(
            url: identity.marketplace.apiBaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try signer.sign(&request)

        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            // The server does not distinguish an expired token from a bad
            // signature. Retry once as an expiry; a second 401 is a signature.
            throw AudibleError.tokenExpired
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw AudibleError.rateLimited(retryAfter: retryAfter)
        default:
            throw AudibleError.httpError(
                status: response.statusCode,
                body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder.audibleAPI.decode(type, from: data)
        } catch {
            throw AudibleError.malformedResponse(String(describing: error))
        }
    }

    // MARK: Token refresh

    /// Buys a new access token with the refresh token.
    func refreshAccessToken() async throws {
        let body: [String: Any] = [
            "app_name": "Audible",
            "app_version": "3.56.2",
            "source_token": identity.refreshToken,
            "requested_token_type": "access_token",
            "source_token_type": "refresh_token"
        ]
        var request = URLRequest(
            url: URL(string: "https://\(identity.marketplace.amazonAPIHost)/auth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String
        else {
            throw AudibleError.tokenExpired
        }

        let lifetime = (root["expires_in"] as? Double)
            ?? (root["expires_in"] as? String).flatMap(Double.init)
            ?? 0
        identity.accessToken = token
        identity.accessTokenExpiry = Date().addingTimeInterval(lifetime)
        try store.save(identity)
    }
}

extension JSONDecoder {
    /// Decoder for content API responses. The API sends snake_case keys and
    /// ISO 8601 dates, some with fractional seconds and some without.
    static let audibleAPI: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFraction.date(from: text) { return date }
            if let date = ISO8601DateFormatter.withoutFraction.date(from: text) { return date }
            if let date = DateFormatter.plainDay.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognised date: \(text)"))
        }
        return decoder
    }()
}

extension ISO8601DateFormatter {
    // Foundation date formatters are safe to share for parsing once configured,
    // and neither of these is mutated after creation.
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let withoutFraction = ISO8601DateFormatter()
}

extension DateFormatter {
    /// Release dates arrive as a plain day.
    nonisolated(unsafe) static let plainDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
