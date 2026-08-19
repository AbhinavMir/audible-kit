import Foundation
import Testing
@testable import AudibleKit

@Suite("Device registration")
struct DeviceRegistrationTests {

    @Test("A generated serial is 40 uppercase hexadecimal characters")
    func serialShape() {
        let serial = DeviceRegistration.generateSerial()
        #expect(serial.count == 40)
        #expect(serial.allSatisfy { $0.isHexDigit && !$0.isLowercase })
    }

    @Test("Two serials differ")
    func serialsAreUnique() {
        #expect(DeviceRegistration.generateSerial() != DeviceRegistration.generateSerial())
    }

    @Test("The sign-in URL carries the code challenge and the marketplace")
    func signInURLContents() throws {
        let registration = DeviceRegistration(marketplace: .us)
        let attempt = registration.signInAttempt()
        let items = try #require(
            URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(
            items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first })

        #expect(attempt.url.host == "www.amazon.com")
        #expect(values["openid.oa2.code_challenge_method"] == "S256")
        #expect(values["marketPlaceId"] == AudibleMarketplace.us.marketplaceID)
        #expect(values["openid.oa2.scope"] == "device_auth_access")
        #expect(values["openid.oa2.code_challenge"]?.isEmpty == false)
    }

    @Test("The code challenge is the SHA-256 of the verifier, base64url encoded")
    func codeChallengeMatchesVerifier() throws {
        let attempt = DeviceRegistration(marketplace: .us).signInAttempt()
        let items = try #require(
            URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems)
        let challenge = try #require(
            items.first { $0.name == "openid.oa2.code_challenge" }?.value)
        #expect(challenge == attempt.codeVerifier.sha256.base64URLEncodedString())
    }

    @Test("Base64url output drops padding and swaps the two alphabet characters")
    func base64URLAlphabet() {
        let encoded = Data([251, 255, 190, 1]).base64URLEncodedString()
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test("The authorization code is read from the landing redirect")
    func readsAuthorizationCode() {
        let url = URL(string:
            "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=ANDx7Cq&other=1")!
        #expect(DeviceRegistration.authorizationCode(in: url) == "ANDx7Cq")
    }

    @Test("A page that is not the landing redirect yields no code")
    func ignoresOtherPages() {
        let url = URL(string: "https://www.amazon.com/ap/signin?openid.mode=checkid_setup")!
        #expect(DeviceRegistration.authorizationCode(in: url) == nil)
    }

    @Test("A registration response becomes a device identity")
    func parsesRegistrationResponse() throws {
        let identity = try DeviceRegistration.identity(
            fromRegistrationResponse: Fixtures.registrationSuccess,
            serial: "ABC123",
            marketplace: .uk)

        #expect(identity.adpToken == "{enc:sample-adp-token}")
        #expect(identity.devicePrivateKey.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
        #expect(identity.accessToken == "Atna|sample-access")
        #expect(identity.refreshToken == "Atnr|sample-refresh")
        #expect(identity.customerID == "amzn1.account.SAMPLE")
        #expect(identity.deviceSerialNumber == "ABC123")
        #expect(identity.marketplace == .uk)
        #expect(identity.accessTokenExpiry > Date())
    }

    @Test("A response missing a token is rejected, not half-accepted")
    func rejectsIncompleteResponse() {
        #expect(throws: AudibleError.self) {
            _ = try DeviceRegistration.identity(
                fromRegistrationResponse: Fixtures.registrationMissingKey,
                serial: "ABC123",
                marketplace: .us)
        }
    }

    @Test("A failure response surfaces the server message")
    func explainsServerError() {
        let message = DeviceRegistration.explain(
            status: 400, body: Fixtures.registrationFailure)
        #expect(message == "Invalid authorization code")
    }

    @Test("An identity never prints its secrets")
    func descriptionHidesSecrets() throws {
        let identity = try DeviceRegistration.identity(
            fromRegistrationResponse: Fixtures.registrationSuccess,
            serial: "ABC123",
            marketplace: .us)
        let text = identity.description
        #expect(!text.contains("sample-adp-token"))
        #expect(!text.contains("sample-access"))
        #expect(text.contains("amzn1.account.SAMPLE"))
    }

    @Test("An access token close to expiry asks for a refresh")
    func refreshWindow() throws {
        var identity = try DeviceRegistration.identity(
            fromRegistrationResponse: Fixtures.registrationSuccess,
            serial: "ABC123",
            marketplace: .us)
        #expect(!identity.accessTokenNeedsRefresh)
        identity.accessTokenExpiry = Date().addingTimeInterval(30)
        #expect(identity.accessTokenNeedsRefresh)
    }
}
