import Foundation
import Testing
@testable import AudibleKit

@Suite("Credential storage")
struct CredentialStoreTests {

    @Test("A stored identity reads back exactly as it was written")
    func roundTrip() throws {
        // Written and read with the same pair the Keychain store uses. A key
        // whose name does not survive case conversion, such as marketplaceID,
        // would fail here rather than at the first library request.
        let identity = DeviceIdentity.testIdentity(marketplace: .uk)
        let data = try JSONEncoder.storage.encode(identity)
        let restored = try JSONDecoder.storage.decode(DeviceIdentity.self, from: data)

        #expect(restored.adpToken == identity.adpToken)
        #expect(restored.devicePrivateKey == identity.devicePrivateKey)
        #expect(restored.accessToken == identity.accessToken)
        #expect(restored.refreshToken == identity.refreshToken)
        #expect(restored.deviceSerialNumber == identity.deviceSerialNumber)
        #expect(restored.customerID == identity.customerID)
        #expect(restored.marketplace == identity.marketplace)
        #expect(restored.marketplace.marketplaceID == AudibleMarketplace.uk.marketplaceID)
    }

    @Test("Every marketplace survives storage")
    func allMarketplacesRoundTrip() throws {
        for marketplace in AudibleMarketplace.all {
            let data = try JSONEncoder.storage.encode(
                DeviceIdentity.testIdentity(marketplace: marketplace))
            let restored = try JSONDecoder.storage.decode(DeviceIdentity.self, from: data)
            #expect(restored.marketplace == marketplace)
        }
    }

    @Test("An in-memory store holds, returns, and clears an identity")
    func inMemoryStore() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.load() == nil)
        try store.save(.testIdentity())
        #expect(try store.load() != nil)
        try store.clear()
        #expect(try store.load() == nil)
    }
}

@Suite("Legacy credential migration")
struct LegacyCredentialTests {

    /// An identity as an earlier version wrote it, with converted key names.
    static let legacy = Data("""
    {
      "adp_token": "{enc:test}",
      "device_private_key": "-----BEGIN RSA PRIVATE KEY-----\\nMIIsample\\n-----END RSA PRIVATE KEY-----",
      "access_token": "Atna|test",
      "refresh_token": "Atnr|test",
      "device_serial_number": "0123456789ABCDEF0123456789ABCDEF01234567",
      "customer_id": "amzn1.account.TEST",
      "access_token_expiry": 800000000,
      "marketplace": {
        "country_code": "uk",
        "domain": "co.uk",
        "marketplace_id": "A2I9A3Q2GNFNGQ"
      }
    }
    """.utf8)

    @Test("An identity written by an earlier version still reads")
    func readsLegacyIdentity() throws {
        let identity = try DeviceIdentity.fromLegacyStorage(Self.legacy)
        #expect(identity.adpToken == "{enc:test}")
        #expect(identity.customerID == "amzn1.account.TEST")
        #expect(identity.marketplace == .uk)
        #expect(identity.marketplace.marketplaceID == "A2I9A3Q2GNFNGQ")
    }

    @Test("A migrated identity is written back in the current form")
    func migratesOnRead() throws {
        let identity = try DeviceIdentity.fromLegacyStorage(Self.legacy)
        let rewritten = try JSONEncoder.storage.encode(identity)
        let reread = try JSONDecoder.storage.decode(DeviceIdentity.self, from: rewritten)
        #expect(reread.marketplace == .uk)
    }
}
