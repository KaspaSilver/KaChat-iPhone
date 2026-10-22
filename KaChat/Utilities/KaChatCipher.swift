import Foundation
import CryptoKit
import P256K

/// Kasia encryption/decryption utilities
/// Uses ECDH (secp256k1) + HKDF-SHA256 + ChaCha20-Poly1305
struct KasiaCipher {

    // MARK: - Encrypted Message Format

    struct EncryptedMessage {
        let nonce: Data          // 12 bytes
        let ephemeralPublicKey: Data  // 33 bytes (SEC1 compressed)
        let ciphertext: Data     // includes 16-byte auth tag at end

        init(nonce: Data, ephemeralPublicKey: Data, ciphertext: Data) {
            self.nonce = nonce
            self.ephemeralPublicKey = ephemeralPublicKey
            self.ciphertext = ciphertext
        }

        init?(fromBytes bytes: Data) {
            guard bytes.count > 45 else { return nil }  // 12 + 33 minimum

            // Nonce is always 12 bytes
            let nonce = bytes.prefix(12)

            // Check if SEC1 compressed (starts with 02 or 03)
            // Offsets are relative to startIndex: a Data slice keeps its parent's indices, so
            // absolute `bytes[12]` would read the wrong byte (or trap) when handed a slice.
            let keyStart = bytes.startIndex + 12
            let isSec1Compressed = bytes[keyStart] == 0x02 || bytes[keyStart] == 0x03
            let keySize = isSec1Compressed ? 33 : 32
            let keyEnd = keyStart + keySize

            guard bytes.endIndex >= keyEnd else { return nil }

            let ephemeralPublicKey = bytes[keyStart..<keyEnd]
            let ciphertext = bytes[keyEnd...]

            self.nonce = Data(nonce)
            self.ephemeralPublicKey = Data(ephemeralPublicKey)
            self.ciphertext = Data(ciphertext)
        }

        init?(fromHex hex: String) {
            guard let bytes = Data(hexString: hex) else { return nil }
            self.init(fromBytes: bytes)
        }

        /// Convert to raw bytes (nonce + ephemeralPublicKey + ciphertext)
        func toBytes() -> Data {
            var result = Data()
            result.append(nonce)
            result.append(ephemeralPublicKey)
            result.append(ciphertext)
            return result
        }

        /// Convert to hex string
        func toHex() -> String {
            return toBytes().hexString
        }
    }

    // MARK: - Encryption

    /// Encrypt a message for a recipient using their public key
    static func encrypt(_ plaintext: String, recipientPublicKey: Data) throws -> EncryptedMessage {
        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw CipherError.invalidPlaintext
        }
        return try encrypt(data: plaintextData, recipientPublicKey: recipientPublicKey)
    }

    /// Encrypt raw bytes - the binary media frame (`ContextualMediaFrame`) of a photo or voice
    /// note travels this way, without a base64 layer inside the encryption.
    static func encrypt(data plaintextData: Data, recipientPublicKey: Data) throws -> EncryptedMessage {

        // 1. Generate ephemeral key pair
        let ephemeralPrivateKey: P256K.KeyAgreement.PrivateKey
        do {
            ephemeralPrivateKey = try P256K.KeyAgreement.PrivateKey()
        } catch {
            throw error
        }
        let ephemeralPublicKeyData = ephemeralPrivateKey.publicKey.dataRepresentation

         // 3. Derive shared secret using ECDH

         // Use COMPRESSED public key (33 bytes with 0x02/0x03 prefix)
         // This is required for Schnorr P256K keys
         var pubKeyData = recipientPublicKey
         if recipientPublicKey.count == 32 {
             // X-only key - add 0x02 prefix for even y-coordinate (Schnorr convention)
             var compressed = Data([0x02])
             compressed.append(recipientPublicKey)
             pubKeyData = compressed
         }

         let recipientPubKey = try P256K.KeyAgreement.PublicKey(
             dataRepresentation: pubKeyData,
             format: pubKeyData.count == 33 ? .compressed : .uncompressed
         )

         let sharedSecretBytes = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(
             with: recipientPubKey,
             format: pubKeyData.count == 33 ? .compressed : .uncompressed
         )

         // 4. Extract x-coordinate for key derivation
         var xCoordinate = Data()
         sharedSecretBytes.withUnsafeBytes { bytes in
             if bytes.count >= 33 {
                 xCoordinate = Data(bytes[1..<33])
             } else if bytes.count == 32 {
                 xCoordinate = Data(bytes)
             }
         }

         guard xCoordinate.count == 32 else {
             throw CipherError.decryptionFailed
         }

         // 5. Derive symmetric key using HKDF-SHA256 (same as Kasia's cipher)
         let derivedKey = deriveKey(sharedSecret: xCoordinate)
         xCoordinate.zeroOut()

        // 4. Generate random nonce
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            throw CipherError.encryptionFailed
        }
        let nonce = Data(nonceBytes)

        // 5. Encrypt with ChaCha20-Poly1305
        let symmetricKey = SymmetricKey(data: derivedKey)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonce)
        let sealedBox = try ChaChaPoly.seal(plaintextData, using: symmetricKey, nonce: chachaNonce)

        // 6. Combine ciphertext and tag
        var ciphertextWithTag = Data(sealedBox.ciphertext)
        ciphertextWithTag.append(sealedBox.tag)

        return EncryptedMessage(
            nonce: nonce,
            ephemeralPublicKey: ephemeralPublicKeyData,
            ciphertext: ciphertextWithTag
        )
    }

    // MARK: - Decryption

    /// Decrypt a message using the receiver's private key
    static func decrypt(_ encryptedMessage: EncryptedMessage, privateKey: Data) throws -> String {
        // 1. Validate ephemeral public key
        guard encryptedMessage.ephemeralPublicKey.count == 33 else {
            throw CipherError.invalidPublicKey
        }

        // 2. Perform ECDH to get shared secret
        var sharedSecret = try performECDH(
            privateKey: privateKey,
            ephemeralPublicKey: encryptedMessage.ephemeralPublicKey
        )

        // 3. Derive key using HKDF-SHA256 (same as Kasia's cipher)
        let derivedKey = deriveKey(sharedSecret: sharedSecret)
        sharedSecret.zeroOut()

        // 4. Decrypt with ChaCha20-Poly1305
        guard encryptedMessage.ciphertext.count >= 16 else {
            throw CipherError.invalidEncryptedMessage
        }

        let tagLength = 16
        let actualCiphertext = encryptedMessage.ciphertext.dropLast(tagLength)
        let tag = encryptedMessage.ciphertext.suffix(tagLength)

        do {
            let nonce = try ChaChaPoly.Nonce(data: encryptedMessage.nonce)
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: actualCiphertext,
                tag: tag
            )

            let symmetricKey = SymmetricKey(data: derivedKey)
            let plaintext = try ChaChaPoly.open(sealedBox, using: symmetricKey)

            // A binary media frame comes back as the same media-file JSON a text-encoded one
            // always was, so everything after decryption is unchanged.
            if let media = ContextualMediaFrame.envelopeText(from: plaintext) {
                return media
            }
            guard let result = String(data: plaintext, encoding: .utf8) else {
                throw CipherError.invalidPlaintext
            }

            return result
        } catch {
            throw CipherError.decryptionFailed
        }
    }

    /// Decrypt a hex-encoded message
    static func decryptHex(_ hexMessage: String, privateKey: Data) throws -> String {
        guard let encrypted = EncryptedMessage(fromHex: hexMessage) else {
            throw CipherError.invalidEncryptedMessage
        }

        return try decrypt(encrypted, privateKey: privateKey)
    }

    // MARK: - ECDH

    /// Perform ECDH key exchange using secp256k1
    /// Returns the raw x-coordinate (32 bytes) for HKDF derivation
    private static func performECDH(privateKey: Data, ephemeralPublicKey: Data) throws -> Data {
        // Create P256K private key
        let privKey: P256K.KeyAgreement.PrivateKey
        do {
            privKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        } catch {
            throw CipherError.invalidPrivateKey
        }

        // Create P256K public key from SEC1 compressed format
        let pubKey: P256K.KeyAgreement.PublicKey
        do {
            pubKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: ephemeralPublicKey, format: .compressed)
        } catch {
            throw CipherError.invalidPublicKey
        }

        // Perform ECDH - get shared secret
        let sharedSecretBytes: ContiguousBytes
        do {
            sharedSecretBytes = try privKey.sharedSecretFromKeyAgreement(with: pubKey, format: .compressed)
        } catch {
            throw CipherError.decryptionFailed
        }

        // Extract just the x-coordinate (skip the 02/03 prefix byte)
        var xCoordinate = Data()
        sharedSecretBytes.withUnsafeBytes { bytes in
            // Skip first byte (parity prefix), take next 32 bytes (x-coordinate)
            if bytes.count >= 33 {
                xCoordinate = Data(bytes[1..<33])
            } else if bytes.count == 32 {
                // Some implementations return just the x-coordinate
                xCoordinate = Data(bytes)
            }
        }

        guard xCoordinate.count == 32 else {
            AppLog.log("%@", "[KasiaCipher] Invalid x-coordinate length: \(xCoordinate.count)")
            throw CipherError.decryptionFailed
        }

        return xCoordinate
    }

    // MARK: - Key Derivation

    /// Derive ChaCha20 key from shared secret using HKDF-SHA256
    /// Matches Kasia's: extract with None salt, expand with empty info
    private static func deriveKey(sharedSecret: Data) -> Data {
        let inputKey = SymmetricKey(data: sharedSecret)

        // HKDF with no salt (defaults to zeros) and empty info
        // Use CryptoKit.SHA256 explicitly to avoid ambiguity with P256K.SHA256
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(),
            info: Data(),
            outputByteCount: 32
        )

        return derivedKey.withUnsafeBytes { bytes in
            Data(Array(bytes))
        }
    }

    // MARK: - Errors

    enum CipherError: LocalizedError {
        case invalidEncryptedMessage
        case invalidPublicKey
        case invalidPrivateKey
        case encryptionFailed
        case decryptionFailed
        case invalidPlaintext

        var errorDescription: String? {
            switch self {
            case .invalidEncryptedMessage: return "Invalid encrypted message format"
            case .invalidPublicKey: return "Invalid public key"
            case .invalidPrivateKey: return "Invalid private key"
            case .encryptionFailed: return "Encryption failed"
            case .decryptionFailed: return "Decryption failed"
            case .invalidPlaintext: return "Invalid plaintext encoding"
            }
        }
    }
}

// MARK: - Data Extension for Hex

extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex

        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

/// The binary media frame (MESSAGING.md "Photos and voice notes: the binary media frame"): a
/// 1:1 photo or voice note travels as its RAW bytes inside the encryption, not as base64 text
/// inside JSON - the media-file JSON was base64'd twice (once into its data URL, then the whole
/// ciphertext into the payload), so about 40% of what went on chain was encoding. Now only the
/// payload's own base64 remains: ~33% more picture or sound for the same fee.
///
///   0xFF 'K' 'C' 'M' 0x01 | u32 big-endian header length | header JSON | raw file bytes
///   header JSON: {"name":"photo.jpg","mimeType":"image/jpeg","size":12345}
///
/// 0xFF can never begin UTF-8 text, so a frame is told apart from every text message without
/// ambiguity, and an app that predates it fails to decode it instead of showing garbage. On
/// receipt it becomes exactly the media-file JSON the text form carried (`MediaFileEnvelope`).
enum ContextualMediaFrame {
    static let magic: [UInt8] = [0xFF, 0x4B, 0x43, 0x4D, 0x01]

    /// The frame for a media-file envelope whose content is a base64 data URL of an image or
    /// audio type; nil for anything else, which is sent as UTF-8 text as before.
    static func frame(forEnvelope text: String) -> Data? {
        guard text.hasPrefix("{"), text.contains("\"type\":\"file\""),
              let json = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              object["type"] as? String == "file",
              let content = object["content"] as? String,
              content.hasPrefix("data:"),
              let comma = content.firstIndex(of: ",") else { return nil }
        let meta = content[content.index(content.startIndex, offsetBy: 5)..<comma]
        guard meta.hasSuffix(";base64") else { return nil }
        let mimeType = String(meta.dropLast(";base64".count))
        let lowered = mimeType.lowercased()
        guard lowered.hasPrefix("image/") || lowered.hasPrefix("audio/"),
              let raw = Data(base64Encoded: String(content[content.index(after: comma)...])), !raw.isEmpty else { return nil }
        let header: [String: Any] = [
            "name": (object["name"] as? String) ?? "file",
            "mimeType": mimeType,
            "size": raw.count
        ]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              headerData.count <= Int(UInt32.max) else { return nil }
        var frame = Data(magic)
        var length = UInt32(headerData.count).bigEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(headerData)
        frame.append(raw)
        return frame
    }

    /// The media-file JSON a frame stands for; nil when `data` is not a frame.
    static func envelopeText(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > magic.count + 4, Array(bytes[0..<magic.count]) == magic else { return nil }
        let lengthBytes = bytes[magic.count..<(magic.count + 4)]
        let headerLength = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
        let headerStart = magic.count + 4
        guard headerLength > 0, headerStart + headerLength <= bytes.count,
              let header = (try? JSONSerialization.jsonObject(with: Data(bytes[headerStart..<(headerStart + headerLength)]))) as? [String: Any],
              let mimeType = header["mimeType"] as? String, !mimeType.isEmpty else { return nil }
        let raw = Data(bytes[(headerStart + headerLength)...])
        guard !raw.isEmpty else { return nil }
        return MediaFileEnvelope.json(
            name: (header["name"] as? String) ?? "file",
            size: raw.count,
            mimeType: mimeType,
            dataUrlContent: "data:\(mimeType);base64,\(raw.base64EncodedString())"
        )
    }
}
