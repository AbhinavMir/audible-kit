import Foundation
import Security

/// Where a `DeviceIdentity` is kept between launches.
///
/// The protocol exists so tests can substitute an in-memory store and never
/// touch the real Keychain.
public protocol CredentialStore: Sendable {
    func load() throws -> DeviceIdentity?
    func save(_ identity: DeviceIdentity) throws
    func clear() throws
}

/// Stores the device identity as one generic password item in the macOS
/// Keychain. The whole identity is one JSON blob, so a partial write cannot
/// leave a key without its matching token.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.earmark.audiblekit", account: String = "device-identity") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func load() throws -> DeviceIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AudibleError.registrationFailed(
                "The Keychain refused to read the device identity (status \(status)).")
        }
        if let identity = try? JSONDecoder.storage.decode(DeviceIdentity.self, from: data) {
            return identity
        }
        // An identity written by an earlier version used converted key names.
        // Read it, then write it back in the current form, so this happens
        // once rather than on every launch.
        let identity = try DeviceIdentity.fromLegacyStorage(data)
        try save(identity)
        return identity
    }

    public func save(_ identity: DeviceIdentity) throws {
        let data = try JSONEncoder.storage.encode(identity)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AudibleError.registrationFailed(
                "The Keychain refused to update the device identity (status \(status)).")
        }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw AudibleError.registrationFailed(
                "The Keychain refused to store the device identity (status \(added)).")
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AudibleError.registrationFailed(
                "The Keychain refused to delete the device identity (status \(status)).")
        }
    }
}

/// Keeps an identity in memory only. For tests and for a throwaway session.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: DeviceIdentity?

    public init(identity: DeviceIdentity? = nil) {
        self.identity = identity
    }

    public func load() throws -> DeviceIdentity? {
        lock.withLock { identity }
    }

    public func save(_ identity: DeviceIdentity) throws {
        lock.withLock { self.identity = identity }
    }

    public func clear() throws {
        lock.withLock { identity = nil }
    }
}

// Stored credentials use the property names exactly as written, with no case
// conversion. Converting is not reversible for a name such as `marketplaceID`,
// which encodes to `marketplace_id` and decodes back to `marketplaceId`, so a
// converted identity could be written but never read again.

extension JSONDecoder {
    static let storage = JSONDecoder()
}

extension JSONEncoder {
    static let storage = JSONEncoder()
}


extension DeviceIdentity {
    /// Reads an identity stored with snake_case key names.
    ///
    /// The conversion that produced those names is not reversible: encoding
    /// turned `marketplaceID` into `marketplace_id`, and decoding turned that
    /// back into `marketplaceId`. This maps the names explicitly instead.
    static func fromLegacyStorage(_ data: Data) throws -> DeviceIdentity {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudibleError.registrationFailed("The stored identity could not be read.")
        }
        if var marketplace = root["marketplace"] as? [String: Any] {
            marketplace = DeviceIdentity.renamed(marketplace)
            root["marketplace"] = marketplace
        }
        root = DeviceIdentity.renamed(root)

        let repaired = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder.storage.decode(DeviceIdentity.self, from: repaired)
    }

    /// Turns snake_case names back into the property names of this type.
    private static func renamed(_ object: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in object {
            result[legacyNames[key] ?? key] = value
        }
        return result
    }

    private static let legacyNames = [
        "adp_token": "adpToken",
        "device_private_key": "devicePrivateKey",
        "access_token": "accessToken",
        "refresh_token": "refreshToken",
        "device_serial_number": "deviceSerialNumber",
        "customer_id": "customerID",
        "access_token_expiry": "accessTokenExpiry",
        "country_code": "countryCode",
        "marketplace_id": "marketplaceID"
    ]
}
