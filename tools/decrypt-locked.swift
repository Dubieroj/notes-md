// Decrypts a locked note without the app, so locked notes never depend on it.
// Usage: swift tools/decrypt-locked.swift <library>/.pero/lock.json <note>.pero-locked
// The password is asked for (or read from standard input); the Markdown goes to standard output.
// Format: docs/locked-format.md.
import CommonCrypto
import CryptoKit
import Foundation

struct Config: Decodable { var iterations: Int; var salt: Data; var wrappedMasterKey: Data }
struct Envelope: Decodable { var wrappedKey: String; var ciphertext: String }
struct Payload: Decodable { var text: String }

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: swift tools/decrypt-locked.swift <lock.json> <note.pero-locked>", 2) }
guard let configData = FileManager.default.contents(atPath: args[1]),
      let config = try? JSONDecoder().decode(Config.self, from: configData),
      let noteData = FileManager.default.contents(atPath: args[2]),
      let envelope = try? JSONDecoder().decode(Envelope.self, from: noteData),
      let wrappedKey = Data(base64Encoded: envelope.wrappedKey),
      let ciphertext = Data(base64Encoded: envelope.ciphertext) else { fail("Cannot read the files", 2) }

func readPassword() -> String {
    guard isatty(0) != 0 else { return readLine(strippingNewline: true) ?? "" }
    var buffer = [CChar](repeating: 0, count: 1024)
    return readpassphrase("Password: ", &buffer, buffer.count, 0).map { String(cString: $0) } ?? ""
}
let password = Array(readPassword().utf8)
// PBKDF2-HMAC-SHA256 of the UTF-8 password → the key that wraps the library's master key.
var derived = Data(count: 32)
_ = derived.withUnsafeMutableBytes { out in
    config.salt.withUnsafeBytes { salt in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count,
                             salt.bindMemory(to: UInt8.self).baseAddress, config.salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(config.iterations),
                             out.bindMemory(to: UInt8.self).baseAddress, 32)
    }
}

// Every layer is AES-256-GCM in CryptoKit's combined form: nonce (12) + ciphertext + tag (16).
func open(_ combined: Data, with key: Data) throws -> Data {
    try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key))
}
do {
    let master = try open(config.wrappedMasterKey, with: derived)
    let noteKey = try open(wrappedKey, with: master)
    let payload = try JSONDecoder().decode(Payload.self, from: open(ciphertext, with: noteKey))
    FileHandle.standardOutput.write(Data(payload.text.utf8))
} catch {
    fail("Wrong password or damaged file", 1)
}
