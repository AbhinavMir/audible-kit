import Foundation
import CommonCrypto
@testable import AudibleKit

extension AES {
    /// Encrypts AES-CBC with PKCS#7 padding. Tests only: the package never
    /// encrypts anything in normal use, it only opens what the server sent.
    static func cbcEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        let capacity = plaintext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var written = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, plaintext.count,
                            outputBytes.baseAddress, capacity,
                            &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw AudibleError.decryptFailed("Test encryption returned \(status).")
        }
        return output.prefix(written)
    }
}
