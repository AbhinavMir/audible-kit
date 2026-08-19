import Foundation
import Testing
import CryptoKit
@testable import AudibleKit

@Suite("Licensing")
struct LicenseServiceTests {

    static let serial = "0123456789ABCDEF0123456789ABCDEF01234567"
    static let asin = "B0TEST0001"
    static let customerID = "amzn1.account.TEST"

    /// Builds a voucher the same way the server does, so the test proves the
    /// decrypt path end to end without a recorded secret.
    static func makeVoucher(key: String, iv: String) throws -> String {
        let plaintext = Data(#"{"key":"\#(key)","iv":"\#(iv)","refresh_date":"2027-01-01"}"#.utf8)
        let material = Data(SHA256.hash(data: Data(
            (DeviceRegistration.deviceType + serial + customerID + asin).utf8)))
        let ciphertext = try AES.cbcEncrypt(
            plaintext, key: material.prefix(16), iv: material.suffix(16))
        return ciphertext.base64EncodedString()
    }

    static func licenseBody(voucher: String, status: String = "Granted") -> Data {
        Data("""
        {
          "content_license": {
            "status_code": "\(status)",
            "license_response": "\(voucher)",
            "content_metadata": {
              "content_url": {
                "offline_url": "https://example.invalid/audio.aaxc?token=abc"
              },
              "chapter_info": {
                "chapters": [
                  {"title": "Opening Credits", "start_offset_ms": 0, "length_ms": 24000},
                  {"title": "Chapter One", "start_offset_ms": 24000, "length_ms": 1800000}
                ]
              },
              "last_position_heard": {"position_ms": 372000, "status": "Exists"}
            }
          }
        }
        """.utf8)
    }

    @Test("A granted license yields the download URL, key, and vector")
    func parsesGrantedLicense() throws {
        let keyHex = String(repeating: "ab", count: 16)
        let ivHex = String(repeating: "cd", count: 16)
        let body = Self.licenseBody(voucher: try Self.makeVoucher(key: keyHex, iv: ivHex))

        let license = try LicenseService.parse(
            body, asin: Self.asin, deviceSerial: Self.serial, customerID: Self.customerID)

        #expect(license.downloadURL.host == "example.invalid")
        #expect(license.keyHex == keyHex)
        #expect(license.ivHex == ivHex)
        #expect(license.key.count == 16)
        #expect(license.iv.count == 16)
    }

    @Test("Chapters come back in seconds")
    func parsesChapters() throws {
        let body = Self.licenseBody(
            voucher: try Self.makeVoucher(
                key: String(repeating: "ab", count: 16),
                iv: String(repeating: "cd", count: 16)))
        let license = try LicenseService.parse(
            body, asin: Self.asin, deviceSerial: Self.serial, customerID: Self.customerID)

        #expect(license.chapters.count == 2)
        #expect(license.chapters[0].title == "Opening Credits")
        #expect(license.chapters[0].duration == 24)
        #expect(license.chapters[1].start == 24)
        #expect(license.chapters[1].end == 1824)
    }

    @Test("The last position heard comes back in seconds")
    func parsesLastPosition() throws {
        let body = Self.licenseBody(
            voucher: try Self.makeVoucher(
                key: String(repeating: "ab", count: 16),
                iv: String(repeating: "cd", count: 16)))
        let license = try LicenseService.parse(
            body, asin: Self.asin, deviceSerial: Self.serial, customerID: Self.customerID)
        #expect(license.lastPositionHeard == 372)
    }

    @Test("A voucher issued to another device does not open")
    func rejectsForeignVoucher() throws {
        let body = Self.licenseBody(
            voucher: try Self.makeVoucher(
                key: String(repeating: "ab", count: 16),
                iv: String(repeating: "cd", count: 16)))
        #expect(throws: AudibleError.self) {
            _ = try LicenseService.parse(
                body, asin: Self.asin, deviceSerial: "SOMEOTHERDEVICESERIAL00000000000000000000",
                customerID: Self.customerID)
        }
    }

    @Test("A refused license reports the server reason")
    func reportsDenial() throws {
        let body = Data("""
        {"content_license": {"status_code": "Denied", "message": "Not entitled"}}
        """.utf8)
        #expect(throws: AudibleError.licenseDenied(asin: Self.asin, reason: "Not entitled")) {
            _ = try LicenseService.parse(body, asin: Self.asin, deviceSerial: Self.serial, customerID: Self.customerID)
        }
    }

    @Test("A license with no download URL fails instead of half-succeeding")
    func requiresDownloadURL() throws {
        let body = Data("""
        {"content_license": {"status_code": "Granted", "license_response": "x"}}
        """.utf8)
        #expect(throws: AudibleError.self) {
            _ = try LicenseService.parse(body, asin: Self.asin, deviceSerial: Self.serial, customerID: Self.customerID)
        }
    }

    @Test("Hexadecimal round-trips through Data")
    func hexRoundTrip() throws {
        let hex = "00ff10abCD"
        let data = try #require(Data(hexString: hex))
        #expect(data.count == 5)
        #expect(data.hexString == "00ff10abcd")
    }

    @Test("An odd-length hexadecimal string is rejected")
    func rejectsOddHex() {
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }

    @Test("A voucher issued to another customer does not open")
    func rejectsForeignCustomer() throws {
        let body = Self.licenseBody(
            voucher: try Self.makeVoucher(
                key: String(repeating: "ab", count: 16),
                iv: String(repeating: "cd", count: 16)))
        #expect(throws: AudibleError.self) {
            _ = try LicenseService.parse(
                body, asin: Self.asin, deviceSerial: Self.serial,
                customerID: "amzn1.account.SOMEONEELSE")
        }
    }

    @Test("A voucher for another title does not open")
    func rejectsForeignASIN() throws {
        let body = Self.licenseBody(
            voucher: try Self.makeVoucher(
                key: String(repeating: "ab", count: 16),
                iv: String(repeating: "cd", count: 16)))
        #expect(throws: AudibleError.self) {
            _ = try LicenseService.parse(
                body, asin: "B0DIFFERENT", deviceSerial: Self.serial,
                customerID: Self.customerID)
        }
    }

    @Test("Trailing bytes after the voucher JSON are ignored")
    func readsJSONWithTrailingBytes() throws {
        var data = Data(#"{"key":"ab","iv":"cd"}"#.utf8)
        data.append(contentsOf: [0x07, 0x07, 0x07, 0x00])
        let root = try #require(LicenseService.readJSON(data))
        #expect(root["key"] as? String == "ab")
    }

    @Test("AES-CBC round-trips")
    func aesRoundTrip() throws {
        let key = Data(repeating: 7, count: 16)
        let iv = Data(repeating: 9, count: 16)
        let plaintext = Data("the quick brown fox jumps over the lazy dog".utf8)
        let ciphertext = try AES.cbcEncrypt(plaintext, key: key, iv: iv)
        #expect(try AES.cbcDecrypt(ciphertext, key: key, iv: iv) == plaintext)
    }
}
