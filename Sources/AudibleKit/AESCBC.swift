import Foundation
import CommonCrypto

extension AES {
    /// Decrypts AES-CBC.
    ///
    /// CryptoKit offers GCM only, and the Audible voucher is CBC, so this uses
    /// CommonCrypto directly.
    ///
    /// - Parameter padded: Whether the plaintext carries PKCS#7 padding. A
    ///   voucher does not, and asking for padding on unpadded data fails.
    static func cbcDecrypt(
        _ ciphertext: Data,
        key: Data,
        iv: Data,
        padded: Bool = true
    ) throws -> Data {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw AudibleError.decryptFailed("The voucher key is \(key.count) bytes.")
        }
        guard iv.count == kCCBlockSizeAES128 else {
            throw AudibleError.decryptFailed("The voucher vector is \(iv.count) bytes.")
        }

        let capacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var written = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(padded ? kCCOptionPKCS7Padding : 0),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, ciphertext.count,
                            outputBytes.baseAddress, capacity,
                            &written)
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw AudibleError.decryptFailed("AES returned status \(status).")
        }
        return output.prefix(written)
    }
}

/// Namespace for the CBC helper. CryptoKit already declares `AES`, and this
/// extension hangs off that name.
public enum AES {}

extension Data {
    /// Lowercase hexadecimal, as ffmpeg expects for a key or vector.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Reads bytes from a hexadecimal string. Returns nil when the string is
    /// not an even run of hexadecimal digits.
    init?(hexString: String) {
        let characters = Array(hexString)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        self = Data(bytes)
    }
}
