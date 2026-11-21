// Sealing and pairing, exactly as in research/launch-with-claude-spec.md.
// The relay never sees the pair key K; it only sees two hashes of it (box name and box password).
import CryptoKit
import Foundation

enum Box {
    static func sha256hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `x-box` names the box, `x-auth` is its password. Both are hashes of K.
    static func headers(_ k: String) -> [String: String] {
        ["x-box": sha256hex("box|" + k), "x-auth": sha256hex("auth|" + k)]
    }

    /// AES-GCM key: HKDF-SHA256(ikm = utf8(K), no salt, info = "omnia-relay-v1", 32 bytes).
    /// Same call as mac/omniacrypt.swift and the app's `Relay.key`.
    static func sealKey(_ k: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(k.utf8)),
                               info: Data("omnia-relay-v1".utf8), outputByteCount: 32)
    }

    /// Base64 of CryptoKit's combined layout: 12-byte nonce, ciphertext, 16-byte tag.
    static func seal(_ plain: Data, k: String) throws -> String {
        guard let combined = try AES.GCM.seal(plain, using: sealKey(k)).combined else { throw CryptoKitError.incorrectParameterSize }
        return combined.base64EncodedString()
    }

    static func open(_ text: String, k: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else { throw CryptoKitError.incorrectParameterSize }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: sealKey(k))
    }
}

enum Pairing {
    enum Failure: Error { case badPublicKey, badCode }

    static func publicKeyBase64(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    static func isCode(_ code: String) -> Bool {
        code.count == 6 && code.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// shared = X25519(own private, other pub)
    /// K = base64url_no_padding(HKDF-SHA256(ikm = shared, salt = utf8(code), info = "omnia-pair-v1", 32 bytes))
    static func deriveK(own: Curve25519.KeyAgreement.PrivateKey, otherPublicBase64: String, code: String) throws -> String {
        guard isCode(code) else { throw Failure.badCode }
        guard let raw = Data(base64Encoded: otherPublicBase64.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else {
            throw Failure.badPublicKey
        }
        let other = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let shared = try own.sharedSecretFromKeyAgreement(with: other)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedBytes), salt: Data(code.utf8),
                                         info: Data("omnia-pair-v1".utf8), outputByteCount: 32)
        return base64url(key.withUnsafeBytes { Data($0) })
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
