import Foundation
import Testing
@testable import AudibleKit

/// Exercises sign-in and registration, which happen once and must not be
/// possible to wedge.
@Suite("Fuzzing sign-in and registration")
struct AuthFuzzTests {

    @Test("A sign-in address is well formed for every storefront")
    func signInURLsAreWellFormed() throws {
        for marketplace in AudibleMarketplace.all {
            let attempt = DeviceRegistration(marketplace: marketplace).signInAttempt()
            let components = try #require(
                URLComponents(url: attempt.url, resolvingAgainstBaseURL: false))

            #expect(components.scheme == "https")
            #expect(components.host == marketplace.amazonSignInHost)

            let items = components.queryItems ?? []
            // Every parameter must carry a value. An empty one is how a
            // sign-in silently returns no code.
            for item in items {
                #expect(item.value?.isEmpty == false, "\(item.name) is empty")
            }
            let names = Set(items.map(\.name))
            for required in ["openid.oa2.code_challenge", "openid.oa2.client_id",
                             "openid.return_to", "marketPlaceId",
                             "openid.oa2.code_challenge_method"] {
                #expect(names.contains(required), "missing \(required)")
            }
        }
    }

    @Test("Every attempt differs from every other")
    func attemptsAreUnique() {
        let registration = DeviceRegistration(marketplace: .us)
        var serials = Set<String>()
        var verifiers = Set<String>()
        for _ in 0..<200 {
            let attempt = registration.signInAttempt()
            serials.insert(attempt.serial)
            verifiers.insert(attempt.codeVerifier)
            #expect(attempt.serial.count == 40)
            #expect(attempt.codeVerifier.count >= 43)
        }
        #expect(serials.count == 200)
        #expect(verifiers.count == 200)
    }

    @Test("The challenge always matches the verifier the server will hash")
    func challengeAlwaysMatches() throws {
        // Getting this wrong fails with a message that names nothing.
        for _ in 0..<100 {
            let attempt = DeviceRegistration(marketplace: .us).signInAttempt()
            let items = try #require(
                URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems)
            let challenge = try #require(
                items.first { $0.name == "openid.oa2.code_challenge" }?.value)
            #expect(challenge == Data(attempt.codeVerifier.utf8).sha256.base64URLEncodedString())
        }
    }

    @Test("A landing address yields a code only when it carries one")
    func codeReadingIsExact() {
        let carries = [
            "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=ABC123",
            "https://www.amazon.co.uk/ap/maplanding?a=1&openid.oa2.authorization_code=X&b=2"
        ]
        for text in carries {
            let url = URL(string: text)!
            #expect(DeviceRegistration.authorizationCode(in: url) != nil)
        }

        let carriesNot = [
            "https://www.amazon.com/ap/maplanding",
            "https://www.amazon.com/ap/maplanding?",
            "https://www.amazon.com/ap/signin?openid.oa2.authorization_code=ABC",
            "https://www.amazon.com/?openid.oa2.authorization_code=ABC",
            "https://evil.invalid/ap/maplanding?openid.oa2.authorization_code=ABC"
        ]
        for text in carriesNot {
            guard let url = URL(string: text) else { continue }
            let code = DeviceRegistration.authorizationCode(in: url)
            if text.contains("evil.invalid") {
                // A code is only meaningful from Amazon. Reading one from
                // anywhere else would take a code an attacker chose.
                #expect(code == nil, "took a code from \(text)")
            } else if !text.contains("maplanding") {
                #expect(code == nil, "took a code from \(text)")
            }
        }
    }

    @Test("A registration response missing any part is refused whole")
    func partialRegistrationsRefused() {
        let parts = ["adp_token", "device_private_key", "access_token",
                     "refresh_token", "user_id"]
        for missing in parts {
            var body = """
            {"response":{"success":{"tokens":{"mac_dms":{
             "adp_token":"{enc:t}","device_private_key":"KEY"},
             "bearer":{"access_token":"A","refresh_token":"R","expires_in":"3600"}},
             "extensions":{"customer_info":{"user_id":"C"}}}}}
            """
            body = body.replacingOccurrences(of: "\"\(missing)\"", with: "\"removed\"")
            #expect(throws: AudibleError.self, "without \(missing)") {
                _ = try DeviceRegistration.identity(
                    fromRegistrationResponse: Data(body.utf8),
                    serial: "S", marketplace: .us)
            }
        }
    }
}

@Suite("Where a code may come from")
struct CodeOriginTests {

    static func url(_ text: String) -> URL { URL(string: text)! }

    @Test("A code is taken from Amazon's landing page")
    func takesFromAmazon() {
        for host in ["www.amazon.com", "amazon.com", "www.amazon.co.uk",
                     "www.amazon.de", "www.amazon.co.jp"] {
            let url = Self.url(
                "https://\(host)/ap/maplanding?openid.oa2.authorization_code=ABC")
            #expect(DeviceRegistration.authorizationCode(in: url) == "ABC")
        }
    }

    @Test("A code is refused from anywhere else")
    func refusesElsewhere() {
        // A code identifies whoever holds it. Taking one from a page that is
        // not Amazon's would register this Mac to whoever issued that code.
        let elsewhere = [
            "https://evil.invalid/ap/maplanding?openid.oa2.authorization_code=ABC",
            "https://notamazon.com/ap/maplanding?openid.oa2.authorization_code=ABC",
            "https://amazon.com.evil.invalid/ap/maplanding?openid.oa2.authorization_code=ABC",
            "https://www.amazon.com.evil.invalid/ap/maplanding?openid.oa2.authorization_code=ABC",
            "http://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=ABC",
            "https://evil.invalid/?x=https://www.amazon.com/ap/maplanding&openid.oa2.authorization_code=ABC"
        ]
        for text in elsewhere {
            guard let url = URL(string: text) else { continue }
            #expect(DeviceRegistration.authorizationCode(in: url) == nil,
                    "took a code from \(text)")
        }
    }

    @Test("An empty code is no code")
    func emptyCodeIsRefused() {
        let url = Self.url(
            "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=")
        #expect(DeviceRegistration.authorizationCode(in: url) == nil)
    }
}
