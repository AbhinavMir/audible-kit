import Foundation
import Security

extension RequestSigner {
    /// Builds a `SecKey` from the PEM that Audible returns at registration.
    ///
    /// Audible has returned both PKCS#1 (`BEGIN RSA PRIVATE KEY`) and PKCS#8
    /// (`BEGIN PRIVATE KEY`) at different times, so both are accepted. The
    /// Security framework takes PKCS#1 only, so a PKCS#8 key has its wrapper
    /// removed first.
    static func parsePrivateKey(pem: String) throws -> SecKey {
        let der = try derBytes(fromPEM: pem)
        let pkcs1 = try stripPKCS8Wrapper(der)

        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        guard let key = SecKeyCreateWithData(
            pkcs1 as CFData, attributes as CFDictionary, &error)
        else {
            let detail = (error?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "unknown reason"
            throw AudibleError.registrationFailed("Private key is unusable: \(detail)")
        }
        return key
    }

    /// Strips the PEM armour and decodes the base64 body.
    private static func derBytes(fromPEM pem: String) throws -> Data {
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            throw AudibleError.registrationFailed("Private key is not valid base64.")
        }
        return der
    }

    /// Returns the PKCS#1 key inside a PKCS#8 container, or the input unchanged
    /// when it is already PKCS#1.
    ///
    /// A PKCS#8 RSA key is `SEQUENCE { INTEGER 0, SEQUENCE { OID rsaEncryption,
    /// NULL }, OCTET STRING { pkcs1 } }`. This walks that structure rather than
    /// matching a fixed prefix, so a key with a different length encoding still
    /// parses.
    private static func stripPKCS8Wrapper(_ der: Data) throws -> Data {
        var reader = DERReader(der)
        guard let outer = try? reader.readSequence() else { return der }

        var inner = DERReader(outer)
        // A PKCS#1 key starts with the modulus, a large INTEGER. A PKCS#8 key
        // starts with the version, which is always zero.
        // `Data` slices keep the parent's indices, so read the first byte
        // through `first` rather than through subscript zero.
        guard let version = try? inner.readInteger(),
              version.count == 1, version.first == 0
        else { return der }
        guard (try? inner.readSequence()) != nil else { return der }
        guard let octets = try? inner.readOctetString() else { return der }
        return octets
    }
}

/// Minimal DER walker. Reads only the three tags a PKCS#8 RSA key uses.
private struct DERReader {
    private let bytes: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.bytes = data
        self.index = data.startIndex
    }

    mutating func readSequence() throws -> Data { try read(tag: 0x30) }
    mutating func readInteger() throws -> Data { try read(tag: 0x02) }
    mutating func readOctetString() throws -> Data { try read(tag: 0x04) }

    private mutating func read(tag: UInt8) throws -> Data {
        guard index < bytes.endIndex, bytes[index] == tag else {
            throw AudibleError.registrationFailed("Unexpected DER tag.")
        }
        index = bytes.index(after: index)
        let length = try readLength()
        guard let end = bytes.index(index, offsetBy: length, limitedBy: bytes.endIndex) else {
            throw AudibleError.registrationFailed("DER length runs past the end.")
        }
        defer { index = end }
        return bytes[index..<end]
    }

    private mutating func readLength() throws -> Int {
        guard index < bytes.endIndex else {
            throw AudibleError.registrationFailed("DER ended before a length.")
        }
        let first = bytes[index]
        index = bytes.index(after: index)
        if first & 0x80 == 0 { return Int(first) }

        let count = Int(first & 0x7F)
        guard count > 0, count <= 8 else {
            throw AudibleError.registrationFailed("Unsupported DER length.")
        }
        var length = 0
        for _ in 0..<count {
            guard index < bytes.endIndex else {
                throw AudibleError.registrationFailed("DER length is truncated.")
            }
            length = (length << 8) | Int(bytes[index])
            index = bytes.index(after: index)
        }
        return length
    }
}
