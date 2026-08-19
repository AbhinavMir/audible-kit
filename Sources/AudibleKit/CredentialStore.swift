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
        return try JSONDecoder.audible.decode(DeviceIdentity.self, from: data)
    }

    public func save(_ identity: DeviceIdentity) throws {
        let data = try JSONEncoder.audible.encode(identity)
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

extension JSONDecoder {
    /// Decoder used for every stored and received payload.
    static let audible: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

extension JSONEncoder {
    static let audible: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
