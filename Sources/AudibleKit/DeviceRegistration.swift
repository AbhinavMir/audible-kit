import Foundation

/// Turns an Amazon authorization code into a registered device.
///
/// Audible has no password API. The consumer application shows the Amazon
/// sign-in page, catches the redirect, and hands the code here. This type
/// builds that sign-in URL and reads the code back out of the redirect, but
/// displays nothing itself.
public struct DeviceRegistration: Sendable {
    private let marketplace: AudibleMarketplace
    private let transport: HTTPTransport

    public init(marketplace: AudibleMarketplace, transport: HTTPTransport = URLSessionTransport()) {
        self.marketplace = marketplace
        self.transport = transport
    }

    // MARK: Sign-in URL

    /// One sign-in attempt. Hold it from `signInURL` until the redirect
    /// arrives: the verifier and serial must match across both halves.
    public struct Attempt: Sendable {
        public let url: URL
        public let codeVerifier: Data
        public let serial: String
    }

    /// Builds the Amazon sign-in URL for a new registration.
    public func signInAttempt() -> Attempt {
        let serial = DeviceRegistration.generateSerial()
        let verifier = DeviceRegistration.randomBytes(32)
        let challenge = verifier.sha256.base64URLEncodedString()

        var components = URLComponents()
        components.scheme = "https"
        components.host = marketplace.amazonSignInHost
        components.path = "/ap/signin"
        components.queryItems = [
            .init(name: "openid.oa2.response_type", value: "code"),
            .init(name: "openid.oa2.code_challenge_method", value: "S256"),
            .init(name: "openid.oa2.code_challenge", value: challenge),
            .init(name: "openid.return_to",
                  value: "https://www.amazon.\(marketplace.domain)/ap/maplanding"),
            .init(name: "openid.assoc_handle", value: "amzn_audible_ios_\(marketplace.countryCode)"),
            .init(name: "openid.identity",
                  value: "http://specs.openid.net/auth/2.0/identifier_select"),
            .init(name: "openid.claimed_id",
                  value: "http://specs.openid.net/auth/2.0/identifier_select"),
            .init(name: "openid.mode", value: "checkid_setup"),
            .init(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
            .init(name: "openid.ns.oa2", value: "http://www.amazon.com/ap/ext/oauth/2"),
            .init(name: "openid.oa2.client_id", value: "device:\(serial.deviceClientID)"),
            .init(name: "openid.ns.pape", value: "http://specs.openid.net/extensions/pape/1.0"),
            .init(name: "openid.oa2.scope", value: "device_auth_access"),
            .init(name: "forceMobileLayout", value: "true"),
            .init(name: "language", value: "en_US"),
            .init(name: "marketPlaceId", value: marketplace.marketplaceID),
            .init(name: "pageId", value: "amzn_audible_ios")
        ]
        return Attempt(url: components.url!, codeVerifier: verifier, serial: serial)
    }

    /// Reads the authorization code out of the redirect the sign-in page ends on.
    ///
    /// - Returns: The code, or `nil` when this URL is not the landing page yet.
    public static func authorizationCode(in url: URL) -> String? {
        guard url.path.contains("/ap/maplanding"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first { $0.name == "openid.oa2.authorization_code" }?.value
    }

    // MARK: Registration

    /// Exchanges an authorization code for a device identity.
    ///
    /// - Parameters:
    ///   - code: The value `authorizationCode(in:)` returned.
    ///   - attempt: The attempt that produced the sign-in URL.
    ///   - deviceName: The name shown in the account's device list.
    public func register(
        code: String,
        attempt: Attempt,
        deviceName: String
    ) async throws -> DeviceIdentity {
        let body: [String: Any] = [
            "requested_token_type": [
                "bearer", "mac_dms", "website_cookies", "store_authentication_cookie"
            ],
            "cookies": ["website_cookies": [], "domain": ".amazon.\(marketplace.domain)"],
            "registration_data": [
                "domain": "Device",
                "app_version": "3.56.2",
                "device_serial": attempt.serial,
                "device_type": "A2CZJZGLK2JJVM",
                "device_name": deviceName,
                "os_version": "16.6",
                "software_version": "35602678",
                "device_model": "Mac",
                "app_name": "Audible"
            ],
            "auth_data": [
                "client_id": attempt.serial.deviceClientID,
                "authorization_code": code,
                "code_verifier": String(data: attempt.codeVerifier.base64URLEncoded, encoding: .utf8) ?? "",
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy"
            ],
            "requested_extensions": ["device_info", "customer_info"]
        ]

        var request = URLRequest(
            url: URL(string: "https://\(marketplace.amazonAPIHost)/auth/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw AudibleError.registrationFailed(
                Self.explain(status: response.statusCode, body: data))
        }
        return try Self.identity(
            fromRegistrationResponse: data,
            serial: attempt.serial,
            marketplace: marketplace)
    }

    // MARK: Response parsing

    static func identity(
        fromRegistrationResponse data: Data,
        serial: String,
        marketplace: AudibleMarketplace
    ) throws -> DeviceIdentity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let success = response["success"] as? [String: Any],
              let tokens = success["tokens"] as? [String: Any]
        else {
            throw AudibleError.registrationFailed("The response held no tokens.")
        }

        let mac = tokens["mac_dms"] as? [String: Any] ?? [:]
        let oauth = tokens["bearer"] as? [String: Any] ?? [:]
        let extensions = success["extensions"] as? [String: Any] ?? [:]
        let customer = extensions["customer_info"] as? [String: Any] ?? [:]

        // Every field below is required. A registration missing any one of them
        // cannot sign a request, so a partial identity is never stored.
        guard let adpToken = mac["adp_token"] as? String,
              let privateKey = mac["device_private_key"] as? String,
              let accessToken = oauth["access_token"] as? String,
              let refreshToken = oauth["refresh_token"] as? String,
              let customerID = customer["user_id"] as? String
        else {
            throw AudibleError.registrationFailed("The response was missing a token.")
        }

        // The server states the lifetime in seconds, as a string. Treat an
        // absent or unreadable value as an immediate refresh rather than
        // inventing a duration.
        let lifetime = (oauth["expires_in"] as? String).flatMap(Double.init)

        return DeviceIdentity(
            adpToken: adpToken,
            devicePrivateKey: privateKey,
            accessToken: accessToken,
            refreshToken: refreshToken,
            deviceSerialNumber: serial,
            customerID: customerID,
            marketplace: marketplace,
            accessTokenExpiry: Date().addingTimeInterval(lifetime ?? 0)
        )
    }

    static func explain(status: Int, body: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let error = response["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return "The server returned HTTP \(status)."
        }
        return message
    }

    // MARK: Device serial

    /// Audible device serials are 40 uppercase hexadecimal characters.
    static func generateSerial() -> String {
        randomBytes(20).map { String(format: "%02X", $0) }.joined()
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }
}

extension String {
    /// The client identifier Amazon expects: the serial in hexadecimal, with a
    /// fixed device-type suffix, hex-encoded again.
    var deviceClientID: String {
        Data((self + "#A2CZJZGLK2JJVM").utf8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
