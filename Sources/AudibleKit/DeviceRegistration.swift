import Foundation

/// Turns an Amazon authorization code into a registered device.
///
/// Audible has no password API. The consumer application shows the Amazon
/// sign-in page, catches the redirect, and hands the code here. This type
/// builds that sign-in URL and reads the code back out of the redirect, but
/// displays nothing itself.
public struct DeviceRegistration: Sendable {
    /// The device type this client registers as. It takes part in the voucher
    /// key, so the same value must be used at registration and at decryption.
    public static let deviceType = "A2CZJZGLK2JJVM"

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
        /// The PKCE verifier, as the string that is both sent to the server and
        /// hashed to make the challenge. It must be the same text in both
        /// places, or the server rejects the registration.
        public let codeVerifier: String
        public let serial: String
    }

    /// Builds the Amazon sign-in URL for a new registration.
    public func signInAttempt() -> Attempt {
        let serial = DeviceRegistration.generateSerial()
        // PKCE: the challenge is the hash of the verifier *text*, not of the
        // bytes the text was made from. The server repeats this calculation
        // over the verifier it receives, so both sides must hash the same
        // thing.
        let verifier = DeviceRegistration.randomBytes(32).base64URLEncodedString()
        let challenge = Data(verifier.utf8).sha256.base64URLEncodedString()

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
    /// The address must be Amazon's own landing page. A code is a bearer of
    /// identity: taking one from any page that happens to use the same path
    /// would let a page inside the sign-in view hand over a code of its
    /// choosing, and this Mac would be registered to whoever issued it.
    ///
    /// - Returns: The code, or `nil` when this is not Amazon's landing page.
    public static func authorizationCode(in url: URL) -> String? {
        guard isAmazonLandingPage(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "openid.oa2.authorization_code" })?.value,
              !code.isEmpty
        else { return nil }
        return code
    }

    /// True when this address is Amazon's own sign-in landing page.
    static func isAmazonLandingPage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.path.hasSuffix("/ap/maplanding") else { return false }
        guard let host = url.host?.lowercased() else { return false }

        // Every storefront Amazon runs, and nothing else. A suffix match alone
        // would accept "notamazon.com", so the label before the domain has to
        // end at a dot.
        return AudibleMarketplace.all.contains { marketplace in
            let domain = "amazon.\(marketplace.domain)"
            return host == domain || host.hasSuffix(".\(domain)")
        }
    }

    // MARK: Registration

    /// Exchanges an authorization code for a device identity.
    ///
    /// - Parameters:
    ///   - code: The value `authorizationCode(in:)` returned.
    ///   - attempt: The attempt that produced the sign-in URL.
    ///   - deviceName: The name shown in the account's device list. A short
    ///     part of the serial is added to it, because Amazon refuses a name
    ///     that an existing device already has, and a failed attempt can leave
    ///     the name taken.
    public func register(
        code: String,
        attempt: Attempt,
        deviceName: String
    ) async throws -> DeviceIdentity {
        let uniqueName = DeviceRegistration.uniqueName(deviceName, serial: attempt.serial)
        let body: [String: Any] = [
            "requested_token_type": [
                "bearer", "mac_dms", "website_cookies", "store_authentication_cookie"
            ],
            "cookies": ["website_cookies": [], "domain": ".amazon.\(marketplace.domain)"],
            "registration_data": [
                "domain": "Device",
                "app_version": "3.56.2",
                "device_serial": attempt.serial,
                "device_type": DeviceRegistration.deviceType,
                "device_name": uniqueName,
                "os_version": "16.6",
                "software_version": "35602678",
                "device_model": "Mac",
                "app_name": "Audible"
            ],
            "auth_data": [
                "client_id": attempt.serial.deviceClientID,
                "authorization_code": code,
                "code_verifier": attempt.codeVerifier,
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

        Log.write("Registering '\(uniqueName)' "
                  + "with serial \(attempt.serial.prefix(8))… "
                  + "on \(marketplace.countryCode), "
                  + "code \(Log.redacted(code)), "
                  + "verifier \(Log.redacted(attempt.codeVerifier))")

        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            let reason = Self.explain(status: response.statusCode, body: data)
            Log.write("Registration refused with HTTP \(response.statusCode): \(reason)")
            Log.write("Full response: \(String(data: data, encoding: .utf8) ?? "unreadable")")
            throw AudibleError.registrationFailed(reason)
        }
        Log.write("Registration accepted.")
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

    /// Adds a short part of the serial to a device name.
    ///
    /// Amazon rejects a registration whose device name matches one already on
    /// the account, and a name is taken as soon as one attempt succeeds. The
    /// serial is unique per attempt, so the name is too.
    static func uniqueName(_ name: String, serial: String) -> String {
        "\(name) (\(serial.prefix(6)))"
    }

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
        Data((self + "#" + DeviceRegistration.deviceType).utf8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
