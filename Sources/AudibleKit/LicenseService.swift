import Foundation
import CryptoKit

/// Permission to download one title, with the key that decrypts it.
public struct ContentLicense: Sendable {
    public let asin: String
    /// Where the AAXC file is fetched from.
    public let downloadURL: URL
    /// AES key for the audio, as raw bytes.
    public let key: Data
    /// AES initialisation vector for the audio.
    public let iv: Data
    /// Chapters, when the license response carried them.
    public let chapters: [Chapter]
    /// Position Audible last recorded, in seconds.
    public let lastPositionHeard: TimeInterval?

    /// The key as ffmpeg wants it: lowercase hexadecimal.
    public var keyHex: String { key.hexString }
    /// The initialisation vector as ffmpeg wants it.
    public var ivHex: String { iv.hexString }
}

/// Asks Audible for permission to download a title.
public struct LicenseService: Sendable {
    private let client: AudibleClient

    public init(client: AudibleClient) {
        self.client = client
    }

    /// Requests a download license for one title.
    ///
    /// - Parameter quality: `High` or `Normal`. High is the source quality.
    public func license(for asin: String, quality: String = "High") async throws -> ContentLicense {
        let body: [String: Any] = [
            "supported_drm_types": ["Mpeg", "Adrm"],
            "quality": quality,
            "consumption_type": "Download",
            "response_groups": "last_position_heard,content_reference,chapter_info"
        ]

        let data: Data
        do {
            data = try await client.send(
                method: "POST",
                path: "content/\(asin)/licenserequest",
                body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        } catch AudibleError.httpError(let status, let responseBody) {
            throw AudibleError.licenseDenied(
                asin: asin, reason: LicenseService.explain(status: status, body: responseBody))
        }

        return try LicenseService.parse(
            data, asin: asin, deviceSerial: await client.deviceSerialNumber)
    }

    // MARK: Parsing

    static func parse(_ data: Data, asin: String, deviceSerial: String) throws -> ContentLicense {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let license = root["content_license"] as? [String: Any]
        else {
            throw AudibleError.licenseDenied(asin: asin, reason: "The response held no license.")
        }

        if let status = license["status_code"] as? String, status != "Granted" {
            let message = license["message"] as? String ?? status
            throw AudibleError.licenseDenied(asin: asin, reason: message)
        }

        guard let metadata = license["content_metadata"] as? [String: Any],
              let reference = metadata["content_url"] as? [String: Any],
              let offlineURL = reference["offline_url"] as? String,
              let downloadURL = URL(string: offlineURL)
        else {
            throw AudibleError.licenseDenied(asin: asin, reason: "The license held no download URL.")
        }

        guard let voucher = license["license_response"] as? String else {
            throw AudibleError.licenseDenied(asin: asin, reason: "The license held no voucher.")
        }

        let (key, iv) = try decryptVoucher(voucher, asin: asin, deviceSerial: deviceSerial)

        return ContentLicense(
            asin: asin,
            downloadURL: downloadURL,
            key: key,
            iv: iv,
            chapters: chapters(in: metadata),
            lastPositionHeard: lastPosition(in: metadata))
    }

    /// Unwraps the voucher and returns the audio key and initialisation vector.
    ///
    /// The voucher is AES-256-CBC. Its key and vector come from a SHA-256 over
    /// the device serial, the customer identifier the server echoed, and the
    /// ASIN, so a voucher issued to one device cannot open another's audio.
    static func decryptVoucher(
        _ voucher: String,
        asin: String,
        deviceSerial: String
    ) throws -> (key: Data, iv: Data) {
        guard let ciphertext = Data(base64Encoded: voucher) else {
            throw AudibleError.licenseDenied(asin: asin, reason: "The voucher is not base64.")
        }

        let material = Data(SHA256.hash(data: Data((deviceSerial + asin).utf8)))
        let aesKey = material.prefix(16)
        let aesIV = material.suffix(16)

        let plaintext = try AES.cbcDecrypt(ciphertext, key: aesKey, iv: aesIV)
        guard let root = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let keyHex = root["key"] as? String,
              let ivHex = root["iv"] as? String,
              let key = Data(hexString: keyHex),
              let iv = Data(hexString: ivHex)
        else {
            throw AudibleError.licenseDenied(
                asin: asin, reason: "The voucher did not open. The device key may be wrong.")
        }
        return (key, iv)
    }

    static func chapters(in metadata: [String: Any]) -> [Chapter] {
        guard let info = metadata["chapter_info"] as? [String: Any],
              let entries = info["chapters"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let title = entry["title"] as? String,
                  let start = entry["start_offset_ms"] as? Double,
                  let length = entry["length_ms"] as? Double
            else { return nil }
            return Chapter(title: title, start: start / 1000, duration: length / 1000)
        }
    }

    static func lastPosition(in metadata: [String: Any]) -> TimeInterval? {
        guard let info = metadata["last_position_heard"] as? [String: Any],
              let milliseconds = info["position_ms"] as? Double
        else { return nil }
        return milliseconds / 1000
    }

    static func explain(status: Int, body: String) -> String {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? String
        else {
            return "The server returned HTTP \(status)."
        }
        return message
    }
}
