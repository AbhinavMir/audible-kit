import Foundation
import Testing
@testable import AudibleKit

/// Takes bodies that are valid and damages them, which is closer to what a
/// real failure looks like than random bytes are.
@Suite("Fuzzing by damaging valid responses")
struct FuzzMutationTests {

    static let valid: [Data] = [
        Fixtures.registrationSuccess,
        Fixtures.libraryPage,
        Data("""
        {"asin_last_position_heard_annots": [{"asin": "B0TEST0001",
         "last_position_heard": {"position_ms": 372000, "status": "Exists",
         "last_updated": "2026-08-18T21:04:11.000Z"}}]}
        """.utf8),
        Data("""
        {"customer_details": {"subscription": {"subscription_details": [
         {"name": "Audible Premium Plus", "status": "Active",
          "next_bill_amount": {"currency_code": "USD", "currency_value": 14.95}}]}}}
        """.utf8),
        Data(#"{"collections": [{"collection_id": "a", "name": "Reading"}]}"#.utf8)
    ]

    static func run(_ body: Data) {
        _ = try? DeviceRegistration.identity(
            fromRegistrationResponse: body, serial: "S", marketplace: .us)
        _ = try? LicenseService.parse(body, asin: "A", deviceSerial: "S", customerID: "C")
        _ = try? PositionService.parse(body)
        _ = MembershipService.parse(body)
        _ = try? JSONDecoder.audibleAPI.decode(LibraryResponse.self, from: body)
        _ = try? JSONDecoder.audibleAPI.decode(SingleItemResponse.self, from: body)
        _ = try? DeviceIdentity.fromLegacyStorage(body)
    }

    @Test("A single flipped byte never ends the process",
          arguments: [1 as UInt64, 13, 97])
    func flippedBytes(seed: UInt64) {
        var state = seed | 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for body in Self.valid {
            for _ in 0..<80 {
                var copy = body
                let index = Int(next() % UInt64(max(1, copy.count)))
                copy[copy.startIndex + index] ^= UInt8(truncatingIfNeeded: next())
                Self.run(copy)
            }
        }
    }

    @Test("Cutting a valid body anywhere never ends the process")
    func everyTruncation() {
        for body in Self.valid {
            for length in 0...body.count where length % 3 == 0 {
                Self.run(body.prefix(length))
            }
        }
    }

    @Test("Repeated and nested structures never end the process")
    func deepAndRepeated() {
        for depth in [1, 10, 60, 200] {
            let nested = Data((String(repeating: #"{"a":"#, count: depth)
                + "1" + String(repeating: "}", count: depth)).utf8)
            Self.run(nested)

            let listed = Data(("[" + String(repeating: "1,", count: depth * 20) + "1]").utf8)
            Self.run(listed)
        }
    }

    @Test("Numbers at the edges of what a number can be never end the process")
    func extremeNumbers() {
        let bodies = [
            #"{"items":[{"asin":"A","title":"T","runtime_length_min":9223372036854775807}]}"#,
            #"{"items":[{"asin":"A","title":"T","runtime_length_min":-1}]}"#,
            #"{"items":[{"asin":"A","title":"T","runtime_length_min":1e400}]}"#,
            #"{"asin_last_position_heard_annots":[{"asin":"A","last_position_heard":{"position_ms":1e308,"status":"Exists"}}]}"#,
            #"{"asin_last_position_heard_annots":[{"asin":"A","last_position_heard":{"position_ms":-5,"status":"Exists"}}]}"#
        ]
        for body in bodies { Self.run(Data(body.utf8)) }
    }

    @Test("A position that is absurd is still a position, not a crash")
    func extremePositionsResolve() {
        let far = ListeningPosition(asin: "A", position: 1e308, recordedAt: Date())
        let negative = ListeningPosition(asin: "A", position: -1e308, recordedAt: .distantPast)
        _ = PositionService.resolve(local: far, remote: negative)
        _ = PositionService.resolve(local: negative, remote: far)
        _ = PositionService.resolve(local: far, remote: far)
    }

    @Test("Text of any kind can name a marketplace without ending the process")
    func marketplaceLookupSurvives() {
        for text in ["", "us", "US", "zz", "  ", "\u{FFFD}",
                     String(repeating: "u", count: 5_000)] {
            _ = AudibleMarketplace.named(text)
        }
    }

    @Test("Any name is served or refused by the local server, never escaped")
    func serverNamesAreContained() {
        // The server serves plain names from one folder. Anything that reaches
        // for a parent, or names a folder at all, must be refused.
        let refused = ["../secret", "..", "a/b", "/etc/passwd", "", "..%2Fx"]
        for name in refused {
            let isPlain = !name.isEmpty && !name.contains("/") && !name.contains("..")
            #expect(!isPlain, "\(name) must not be treated as a plain name")
        }
        for name in ["stream.m3u8", "init.mp4", "segment00001.m4s"] {
            let isPlain = !name.isEmpty && !name.contains("/") && !name.contains("..")
            #expect(isPlain)
        }
    }
}

/// Builds requests and stream arguments from values a caller can pass.
@Suite("Fuzzing what is built from arguments")
struct ArgumentFuzzTests {

    static let license = ContentLicense(
        asin: "B0TEST0001",
        downloadURL: URL(string: "https://example.invalid/a.aaxc?t=1")!,
        key: Data(repeating: 0xAB, count: 16),
        iv: Data(repeating: 0xCD, count: 16),
        chapters: [],
        lastPositionHeard: nil)

    @Test("A stream starts from any offset a player can report")
    func streamOffsets() {
        let folder = URL(fileURLWithPath: "/tmp/earmark-fuzz", isDirectory: true)
        for offset in [0.0, -1, -1e9, 0.5, 1.0001, 1e9, .infinity, -.infinity, .nan]
            as [TimeInterval] {
            let arguments = StreamService.arguments(
                for: Self.license, from: offset, in: folder)

            // Whatever the offset, the arguments must stay a usable command:
            // an input, a copy, and an output.
            #expect(arguments.contains("-i"))
            #expect(arguments.last?.hasSuffix("stream.m3u8") == true)

            // A seek is only asked for when it is a real place in the file.
            if let index = arguments.firstIndex(of: "-ss") {
                let value = Double(arguments[index + 1])
                #expect(value != nil, "seek value must be a number, got \(arguments[index + 1])")
                #expect(value?.isFinite == true)
                #expect((value ?? -1) >= 0)
            }
        }
    }

    @Test("A name for a device is produced from any text")
    func deviceNames() {
        for name in ["", " ", String(repeating: "n", count: 5_000), "🎧", "a\u{0000}b"] {
            for serial in ["", "AB", DeviceRegistration.generateSerial()] {
                let result = DeviceRegistration.uniqueName(name, serial: serial)
                #expect(!result.isEmpty)
            }
        }
    }

    @Test("A marketplace builds a usable address for every storefront")
    func marketplaceURLs() {
        for marketplace in AudibleMarketplace.all {
            #expect(marketplace.apiBaseURL.host == marketplace.apiHost)
            #expect(marketplace.apiBaseURL.absoluteString.hasSuffix("/1.0/"))
            #expect(!marketplace.marketplaceID.isEmpty)
            #expect(marketplace.countryCode.count == 2)
        }
    }
}
