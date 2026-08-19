import Foundation

/// An Audible storefront. Determines which hosts and marketplace identifier
/// every request uses.
public struct AudibleMarketplace: Sendable, Hashable, Codable {
    /// Two-letter country code, lowercased. For example `us`, `uk`, `de`.
    public let countryCode: String
    /// Top-level domain of the Audible and Amazon hosts. For example `com`.
    public let domain: String
    /// Amazon marketplace identifier sent during device registration.
    public let marketplaceID: String

    public init(countryCode: String, domain: String, marketplaceID: String) {
        self.countryCode = countryCode
        self.domain = domain
        self.marketplaceID = marketplaceID
    }

    /// Host that serves the Audible content API.
    public var apiHost: String { "api.audible.\(domain)" }
    /// Host that serves Amazon authentication and device registration.
    public var amazonAPIHost: String { "api.amazon.\(domain)" }
    /// Host that serves the Amazon sign-in page.
    public var amazonSignInHost: String { "www.amazon.\(domain)" }

    /// Base URL of version 1.0 of the Audible content API.
    public var apiBaseURL: URL {
        URL(string: "https://\(apiHost)/1.0/")!
    }
}

extension AudibleMarketplace {
    public static let us = AudibleMarketplace(
        countryCode: "us", domain: "com", marketplaceID: "AF2M0KC94RCEA")
    public static let uk = AudibleMarketplace(
        countryCode: "uk", domain: "co.uk", marketplaceID: "A2I9A3Q2GNFNGQ")
    public static let germany = AudibleMarketplace(
        countryCode: "de", domain: "de", marketplaceID: "AN7V1F1VY261K")
    public static let france = AudibleMarketplace(
        countryCode: "fr", domain: "fr", marketplaceID: "A2728XDNODOQ8T")
    public static let canada = AudibleMarketplace(
        countryCode: "ca", domain: "ca", marketplaceID: "A2CQZ5RBY40XE")
    public static let australia = AudibleMarketplace(
        countryCode: "au", domain: "com.au", marketplaceID: "AN7EY7DTAW63G")
    public static let india = AudibleMarketplace(
        countryCode: "in", domain: "in", marketplaceID: "AJO3FBRUE6J4S")
    public static let japan = AudibleMarketplace(
        countryCode: "jp", domain: "co.jp", marketplaceID: "A1QAP3MOU4173J")
    public static let italy = AudibleMarketplace(
        countryCode: "it", domain: "it", marketplaceID: "A2N7FU2W2BU2ZC")
    public static let spain = AudibleMarketplace(
        countryCode: "es", domain: "es", marketplaceID: "ALMIKO4SZCSAR")
    public static let brazil = AudibleMarketplace(
        countryCode: "br", domain: "com.br", marketplaceID: "A10J1VAYUDTYRN")

    public static let all: [AudibleMarketplace] = [
        .us, .uk, .germany, .france, .canada, .australia,
        .india, .japan, .italy, .spain, .brazil
    ]

    /// Looks up a marketplace by two-letter country code.
    public static func named(_ countryCode: String) -> AudibleMarketplace? {
        let wanted = countryCode.lowercased()
        return all.first { $0.countryCode == wanted }
    }
}
