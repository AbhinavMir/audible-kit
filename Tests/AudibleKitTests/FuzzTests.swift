import Foundation
import Testing
@testable import AudibleKit

/// Feeds every parser input it was not designed for.
///
/// A parser reads what a server sends. A server can send anything, including
/// a truncated body from a dropped connection or an error page where JSON was
/// expected. None of that may end the process: a thrown error is a result, a
/// crash is not.
@Suite("Fuzzing the parsers")
struct FuzzTests {

    /// Repeatable pseudo-random bytes, so a failure can be reproduced from the
    /// seed printed in the test name.
    struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed | 1 }

        mutating func next() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }

        mutating func bytes(_ count: Int) -> Data {
            Data((0..<count).map { _ in next() })
        }

        mutating func int(_ range: Range<Int>) -> Int {
            range.lowerBound + Int(next()) % max(1, range.count)
        }
    }

    /// Bodies that a parser can plausibly meet.
    static func corpus(seed: UInt64) -> [Data] {
        var noise = Noise(seed: seed)
        var bodies: [Data] = [
            Data(),
            Data("{}".utf8),
            Data("[]".utf8),
            Data("null".utf8),
            Data("not json at all".utf8),
            Data("<html><body>502 Bad Gateway</body></html>".utf8),
            Data(#"{"content_license": null}"#.utf8),
            Data(#"{"items": "not a list"}"#.utf8),
            Data(#"{"items": [{"asin": 12345}]}"#.utf8),
            Data(#"{"collections": [{}]}"#.utf8),
            Data(#"{"asin_last_position_heard_annots": [{"asin": "A"}]}"#.utf8),
            Data(String(repeating: "{", count: 500).utf8),
            Data(#"{"a":"\#(String(repeating: "x", count: 20_000))"}"#.utf8)
        ]
        for _ in 0..<40 { bodies.append(noise.bytes(noise.int(1..<600))) }
        return bodies
    }

    /// Prefixes of a valid body, as a dropped connection produces.
    static func truncations(of data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: max(1, data.count / 12)).map { data.prefix($0) }
    }

    // MARK: Response parsers

    @Test("No response body ends the process", arguments: [1 as UInt64, 7, 99, 4242])
    func parsersSurviveAnything(seed: UInt64) {
        for body in FuzzTests.corpus(seed: seed) {
            _ = try? DeviceRegistration.identity(
                fromRegistrationResponse: body, serial: "S", marketplace: .us)
            _ = DeviceRegistration.explain(status: 500, body: body)
            _ = try? LicenseService.parse(
                body, asin: "A", deviceSerial: "S", customerID: "C")
            _ = LicenseService.readJSON(body)
            _ = try? PositionService.parse(body)
            _ = MembershipService.parse(body)
            _ = try? JSONDecoder.audibleAPI.decode(LibraryResponse.self, from: body)
            _ = try? DeviceIdentity.fromLegacyStorage(body)
            _ = try? JSONDecoder.storage.decode(DeviceIdentity.self, from: body)
        }
    }

    @Test("A body cut short ends the process no more than a whole one")
    func truncatedBodiesSurvive() {
        let whole = Data("""
        {"content_license": {"status_code": "Granted", "license_response": "abc",
         "content_metadata": {"content_url": {"offline_url": "https://x.invalid/a.aax"},
         "chapter_info": {"chapters": [{"title": "One", "start_offset_ms": 0,
         "length_ms": 100}]}}}}
        """.utf8)
        for body in FuzzTests.truncations(of: whole) {
            _ = try? LicenseService.parse(body, asin: "A", deviceSerial: "S", customerID: "C")
            _ = try? PositionService.parse(body)
            _ = MembershipService.parse(body)
        }
    }

    // MARK: Binary readers

    @Test("Any bytes offered as a private key are refused, not fatal",
          arguments: [3 as UInt64, 11, 500])
    func privateKeyReaderSurvives(seed: UInt64) {
        var noise = Noise(seed: seed)
        for _ in 0..<120 {
            let body = noise.bytes(noise.int(1..<400)).base64EncodedString()
            _ = try? RequestSigner.parsePrivateKey(
                pem: "-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----")
        }
        // The armour itself may be wrong in every way.
        for text in ["", "-----BEGIN", "-----BEGIN PRIVATE KEY-----",
                     "-----BEGIN PRIVATE KEY-----\n\n-----END PRIVATE KEY-----",
                     String(repeating: "A", count: 10_000)] {
            _ = try? RequestSigner.parsePrivateKey(pem: text)
        }
    }

    @Test("A truncated key is refused, not fatal")
    func truncatedKeySurvives() {
        let whole = TestKeys.rsa2048PKCS8
        for cut in FuzzTests.truncations(of: Data(whole.utf8)) {
            _ = try? RequestSigner.parsePrivateKey(
                pem: String(data: cut, encoding: .utf8) ?? "")
        }
    }

    @Test("Any bytes offered as a voucher are refused, not fatal",
          arguments: [5 as UInt64, 55, 555])
    func voucherReaderSurvives(seed: UInt64) {
        var noise = Noise(seed: seed)
        for _ in 0..<120 {
            let voucher = noise.bytes(noise.int(1..<300)).base64EncodedString()
            _ = try? LicenseService.decryptVoucher(
                voucher, asin: "A", deviceSerial: "S", customerID: "C")
        }
        for text in ["", "!!!!", "=", String(repeating: "A", count: 5_000)] {
            _ = try? LicenseService.decryptVoucher(
                text, asin: "A", deviceSerial: "S", customerID: "C")
        }
    }

    @Test("Decryption refuses a wrong key length rather than reading past the end")
    func decryptRejectsBadKeyLengths() {
        for keyLength in [0, 1, 8, 15, 17, 31, 33, 64] {
            #expect(throws: AudibleError.self) {
                _ = try AES.cbcDecrypt(
                    Data(repeating: 1, count: 32),
                    key: Data(repeating: 2, count: keyLength),
                    iv: Data(repeating: 3, count: 16))
            }
        }
        for ivLength in [0, 1, 15, 17, 32] {
            #expect(throws: AudibleError.self) {
                _ = try AES.cbcDecrypt(
                    Data(repeating: 1, count: 32),
                    key: Data(repeating: 2, count: 16),
                    iv: Data(repeating: 3, count: ivLength))
            }
        }
    }

    @Test("Any text offered as hexadecimal is read or refused, never fatal",
          arguments: [2 as UInt64, 22, 222])
    func hexReaderSurvives(seed: UInt64) {
        var noise = Noise(seed: seed)
        for _ in 0..<200 {
            let text = String(decoding: noise.bytes(noise.int(0..<40)), as: UTF8.self)
            _ = Data(hexString: text)
        }
        for text in ["", "0", "zz", "00ff", "0x00", "  ", "\n", "ffff\u{FFFD}"] {
            _ = Data(hexString: text)
        }
    }

    // MARK: URLs and text

    @Test("Any address is read for a code without ending the process",
          arguments: [8 as UInt64, 88])
    func redirectReaderSurvives(seed: UInt64) {
        var noise = Noise(seed: seed)
        for _ in 0..<100 {
            let tail = String(decoding: noise.bytes(noise.int(0..<30)), as: UTF8.self)
                .filter { $0.isLetter || $0.isNumber }
            for text in [
                "https://www.amazon.com/ap/maplanding?\(tail)",
                "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=",
                "https://www.amazon.com/\(tail)",
                "not a url \(tail)"
            ] {
                if let url = URL(string: text) {
                    _ = DeviceRegistration.authorizationCode(in: url)
                }
            }
        }
    }

    @Test("A signature is produced for any request shape")
    func signerSurvivesOddRequests() throws {
        let signer = try RequestSigner(
            adpToken: "{enc:t}", privateKeyPEM: TestKeys.rsa2048PKCS1)
        let urls = [
            "https://api.audible.com",
            "https://api.audible.com/",
            "https://api.audible.com/1.0/library?a=%20&b=%2F",
            "https://api.audible.com/1.0/library?empty=",
            "https://api.audible.com/1.0/" + String(repeating: "p/", count: 200)
        ]
        for text in urls {
            guard let url = URL(string: text) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(String(repeating: "x", count: 5_000).utf8)
            try signer.sign(&request)
            #expect(request.value(forHTTPHeaderField: "x-adp-signature") != nil)
        }
    }

    @Test("A collection listing of any shape is read or refused")
    func collectionParserSurvives() {
        let shapes: [[String: Any]] = [
            [:],
            ["collection_id": "a"],
            ["name": "a"],
            ["collection_id": 1, "name": 2],
            ["collection_id": "a", "name": "b", "total_count": "many"]
        ]
        for shape in shapes {
            _ = CollectionService.collection(from: shape)
        }
    }
}
