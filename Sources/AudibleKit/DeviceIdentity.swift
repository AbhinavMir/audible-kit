import Foundation

/// The credentials Audible issues when a device registers. One value of this
/// type is everything AudibleKit needs to act as that device.
///
/// Treat every field as a secret. `description` deliberately hides them.
public struct DeviceIdentity: Sendable, Codable {
    /// Signed token that identifies the device to the content API.
    public let adpToken: String
    /// PEM-encoded RSA private key that signs every request.
    public let devicePrivateKey: String
    /// Bearer token for endpoints that do not use signing.
    public var accessToken: String
    /// Token that buys a new access token when the current one expires.
    public let refreshToken: String
    /// Serial this client generated at registration. Derives the licence key.
    public let deviceSerialNumber: String
    /// Audible customer identifier.
    public let customerID: String
    /// Storefront this device belongs to.
    public let marketplace: AudibleMarketplace
    /// Moment the current access token stops working.
    public var accessTokenExpiry: Date

    public init(
        adpToken: String,
        devicePrivateKey: String,
        accessToken: String,
        refreshToken: String,
        deviceSerialNumber: String,
        customerID: String,
        marketplace: AudibleMarketplace,
        accessTokenExpiry: Date
    ) {
        self.adpToken = adpToken
        self.devicePrivateKey = devicePrivateKey
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceSerialNumber = deviceSerialNumber
        self.customerID = customerID
        self.marketplace = marketplace
        self.accessTokenExpiry = accessTokenExpiry
    }

    /// True when the access token is expired or expires within one minute.
    public var accessTokenNeedsRefresh: Bool {
        accessTokenExpiry.timeIntervalSinceNow < 60
    }
}

extension DeviceIdentity: CustomStringConvertible {
    /// Names the customer and storefront only. No secret is ever printed.
    public var description: String {
        "DeviceIdentity(customer: \(customerID), marketplace: \(marketplace.countryCode))"
    }
}
