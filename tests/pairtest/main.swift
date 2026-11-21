// Pairing derivation check: two key pairs, both sides must get the same K.
// Build: xcrun swiftc -swift-version 5 tests/pairtest/main.swift src/Crypto.swift -o build/pairtest
import CryptoKit
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

/// The phone's likely route (CryptoKit's own HKDF on the shared secret), written independently of Pairing.deriveK.
func phoneSide(_ own: Curve25519.KeyAgreement.PrivateKey, _ other: Curve25519.KeyAgreement.PublicKey, _ code: String) throws -> String {
    let shared = try own.sharedSecretFromKeyAgreement(with: other)
    let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
                                             sharedInfo: Data("omnia-pair-v1".utf8), outputByteCount: 32)
    var s = key.withUnsafeBytes { Data($0) }.base64EncodedString()
    s = s.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    while s.hasSuffix("=") { s.removeLast() }
    return s
}

for round in 1...5 {
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let computer = Curve25519.KeyAgreement.PrivateKey()
    let code = String(format: "%06d", Int.random(in: 0...999_999))
    let kComputer = try Pairing.deriveK(own: computer, otherPublicBase64: Pairing.publicKeyBase64(phone), code: code)
    let kPhone = try Pairing.deriveK(own: phone, otherPublicBase64: Pairing.publicKeyBase64(computer), code: code)
    let kPhoneAlt = try phoneSide(phone, computer.publicKey, code)
    check(kComputer == kPhone, "round \(round): computer and phone derive the same K (\(kComputer.prefix(10))..., code \(code))")
    check(kPhoneAlt == kComputer, "round \(round): CryptoKit hkdfDerivedSymmetricKey route gives the same K")
    check(kComputer.count == 43 && !kComputer.contains("=") && !kComputer.contains("+") && !kComputer.contains("/"),
          "round \(round): K is 43 characters of base64url without padding")
    let other = code == "000000" ? "000001" : "000000"
    let kWrong = try Pairing.deriveK(own: computer, otherPublicBase64: Pairing.publicKeyBase64(phone), code: other)
    check(kWrong != kComputer, "round \(round): a different code gives a different K")
}

// Sealing round trip with a derived K.
let k = try Pairing.deriveK(own: .init(), otherPublicBase64: Pairing.publicKeyBase64(.init()), code: "123456")
let plain = Data("{\"snapshot\":{}}".utf8)
check((try? Box.open(Box.seal(plain, k: k), k: k)) == plain, "seal then open with K returns the plaintext")
check((try? Box.open(Box.seal(plain, k: k), k: k + "x")) == nil, "open with another K fails")
check(Box.headers("abc")["x-box"] == Box.sha256hex("box|abc") && Box.headers("abc")["x-auth"] == Box.sha256hex("auth|abc"),
      "box headers are sha256_hex(\"box|\" + K) and sha256_hex(\"auth|\" + K)")

print(failures == 0 ? "pairtest: all passed" : "pairtest: \(failures) failed")
exit(failures == 0 ? 0 : 1)
