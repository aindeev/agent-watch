import CryptoKit
import Foundation

// Cryptography for teammate links. Everything is CryptoKit primitives; no custom ciphers.
//
// Pairing (first contact, numeric comparison like Bluetooth SSP / ZRTP):
//   initiator -> responder  pair1  { identity key, name, commit = SHA256(nonceI) }
//   responder -> initiator  pair2  { identity key, name, nonceR }
//   initiator -> responder  pair3  { nonceI }                 responder checks it against the commit
//   both show SAS = 6 digits of SHA256(label | idI | idR | nonceI | nonceR); both people confirm it matches.
//   Committing to nonceI before seeing nonceR stops a man in the middle from grinding a matching code, and the
//   code covers both identity keys, so a match proves each side holds the key the other will remember.
//
// Session (every later connection, mutual auth + forward secrecy):
//   client -> server  hello   { identity key, ephemeral X25519 key }
//   server -> client  hello2  { identity key, ephemeral key, sig_S(transcript) }   client checks it's the paired key
//   client -> server  hello3  { sig_C(transcript) }                                server checks it's a paired key
//   keys = HKDF-SHA256(X25519(eC, eS), salt = SHA256(transcript)), one per direction; frames are ChaChaPoly with
//   counter nonces, so a replayed, reordered or altered frame fails to open and drops the link.

enum PeerCrypto {
    static let pairLabel = Data("agentwatch-pair-v1".utf8)
    static let sessionLabel = Data("agentwatch-session-v1".utf8)

    static func random(_ n: Int = 32) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    static func sha256(_ parts: Data...) -> Data {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    /// Short, stable name for an identity key, shown in the UI and used as the peer id.
    static func fingerprint(_ publicKey: Data) -> String {
        sha256(publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func sas(idI: Data, idR: Data, nonceI: Data, nonceR: Data) -> String {
        let h = [UInt8](sha256(pairLabel, idI, idR, nonceI, nonceR))
        let n = (UInt32(h[0]) << 16 | UInt32(h[1]) << 8 | UInt32(h[2])) % 1_000_000
        return String(format: "%03d %03d", n / 1000, n % 1000)
    }

    static func transcript(idC: Data, idS: Data, eC: Data, eS: Data) -> Data {
        sha256(sessionLabel, idC, idS, eC, eS)
    }

    static func sessionKeys(_ secret: SharedSecret, transcript: Data) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let c2s = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("c2s".utf8), outputByteCount: 32)
        let s2c = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("s2c".utf8), outputByteCount: 32)
        return (c2s, s2c)
    }
}

/// This Mac's long-term identity: an Ed25519 key kept in a 0600 file, like an SSH key. (A Keychain item would
/// re-prompt every time an ad-hoc signed build changes.)
struct Identity {
    let key: Curve25519.Signing.PrivateKey
    var publicKey: Data { key.publicKey.rawRepresentation }
    var id: String { PeerCrypto.fingerprint(publicKey) }

    static func load(dir: URL) -> Identity {
        let file = dir.appendingPathComponent("identity.key")
        if let raw = try? Data(contentsOf: file), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return Identity(key: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: file.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600])
        return Identity(key: key)
    }

    func sign(_ data: Data) throws -> Data { try key.signature(for: data) }

    static func verify(_ sig: Data, _ data: Data, publicKey: Data) -> Bool {
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return pk.isValidSignature(sig, for: data)
    }
}

/// An established session: seals and opens frames in order, one key and counter per direction.
final class SecureChannel {
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    init(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send
        recvKey = receive
    }

    private static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { bytes[4 + i] = UInt8((n >> (8 * UInt64(7 - i))) & 0xff) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    func seal(_ plain: Data) throws -> Data {
        defer { sendCounter += 1 }
        let box = try ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(sendCounter))
        return box.ciphertext + box.tag
    }

    /// Opens the next frame; the nonce is implied by the counter, so anything replayed or out of order fails.
    func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw CryptoKitError.authenticationFailure }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(recvCounter), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plain = try ChaChaPoly.open(box, using: recvKey)
        recvCounter += 1
        return plain
    }
}
