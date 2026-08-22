import Foundation

/// Keeps the device identity in a file that only this user can read.
///
/// The macOS Keychain asks permission on every access until the application's
/// signature is trusted, and asks again whenever that signature changes. This
/// store never asks. The trade is real: the file is plain text, so anything
/// running as this user can read it, and a backup holds it unencrypted.
public final class FileCredentialStore: CredentialStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    /// Read once, then kept, so a launch touches the disk a single time.
    private var cached: DeviceIdentity?
    private var didRead = false

    public init(fileURL: URL = FileCredentialStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Where credentials go when the caller does not say.
    ///
    /// The folder is named after the application that is running, not after
    /// any one product: a package that writes a name of its own into another
    /// application's folder is wrong the moment that application is renamed,
    /// and the credentials are then simply gone.
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? Bundle.main.bundleIdentifier
            ?? "AudibleKit"
        return base
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("credentials.json")
    }

    public func load() throws -> DeviceIdentity? {
        try lock.withLock {
            if didRead { return cached }
            didRead = true
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                cached = nil
                return nil
            }
            let data = try Data(contentsOf: fileURL)
            if let identity = try? JSONDecoder.storage.decode(DeviceIdentity.self, from: data) {
                cached = identity
            } else {
                cached = try DeviceIdentity.fromLegacyStorage(data)
            }
            return cached
        }
    }

    public func save(_ identity: DeviceIdentity) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder.storage.encode(identity)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            // Owner read and write only. Nobody else on the machine can read it.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            cached = identity
            didRead = true
        }
    }

    public func clear() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            cached = nil
            didRead = true
        }
    }
}

/// Reads from the Keychain once, then keeps using the file store.
///
/// This exists so an identity registered before the move keeps working without
/// a fresh sign-in. It touches the Keychain a single time, and never again
/// after the file exists.
public struct MigratingCredentialStore: CredentialStore {
    private let file: FileCredentialStore
    private let keychain: KeychainCredentialStore

    public init(
        file: FileCredentialStore = FileCredentialStore(),
        keychain: KeychainCredentialStore = KeychainCredentialStore()
    ) {
        self.file = file
        self.keychain = keychain
    }

    public func load() throws -> DeviceIdentity? {
        if let identity = try file.load() { return identity }
        // `try?` on a call that already returns an optional gives a nested
        // optional, so flatten it before use.
        guard let identity = (try? keychain.load()) ?? nil else { return nil }
        Log.write("Moving the stored identity out of the Keychain.")
        try file.save(identity)
        // The Keychain copy is left in place. Removing it is the owner's call,
        // not something a migration should do on its own.
        return identity
    }

    public func save(_ identity: DeviceIdentity) throws {
        try file.save(identity)
    }

    public func clear() throws {
        try file.clear()
        try? keychain.clear()
    }
}
