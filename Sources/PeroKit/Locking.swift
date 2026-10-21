import CommonCrypto
import CryptoKit
import Foundation

/// A locked note on disk (`Название.pero-locked`): the title stays readable, as in Notes;
/// the text is AES-256-GCM encrypted with the note's own key, which is wrapped by the
/// library's master key. Format: docs/locked-format.md.
public struct LockedEnvelope: Codable, Sendable {
    public var format = "pero-locked"
    public var version = 1
    public var title: String
    public var wrappedKey: String
    public var ciphertext: String

    public static func title(of data: Data) -> String? {
        (try? JSONDecoder().decode(LockedEnvelope.self, from: data))?.title
    }
}

/// What a locked note holds once decrypted.
struct LockedPayload: Codable {
    var text: String
    var files: [String: Data] = [:]
}

/// `.pero/lock.json`: the master key wrapped by a key derived from the password.
struct LockConfig: Codable {
    var version = 1
    var iterations: Int
    var salt: Data
    var wrappedMasterKey: Data
    var hint: String?
}

public enum LockError: Error {
    case notConfigured, wrongPassword, damaged
}

public final class NoteLocker {
    public static let iterations = 600_000
    private let configURL: URL
    private var config: LockConfig?

    public init(library: Library) {
        configURL = library.meta.appendingPathComponent("lock.json")
        config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(LockConfig.self, from: $0) }
    }

    public var hasPassword: Bool { config != nil }
    public var hint: String? { config?.hint }

    // MARK: Password

    /// Creates the password for locked notes and returns the new master key.
    @discardableResult
    public func setPassword(_ password: String, hint: String?) throws -> SymmetricKey {
        let master = SymmetricKey(size: .bits256)
        try store(master: master, password: password, hint: hint)
        return master
    }

    /// The master key, if the password is right.
    public func unlock(password: String) throws -> SymmetricKey {
        guard let config else { throw LockError.notConfigured }
        let key = Self.derive(password, salt: config.salt, iterations: config.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: config.wrappedMasterKey),
              let raw = try? AES.GCM.open(box, using: key) else { throw LockError.wrongPassword }
        return SymmetricKey(data: raw)
    }

    /// New password, same master key: locked notes stay as they are.
    public func changePassword(from old: String, to new: String, hint: String?) throws {
        let master = try unlock(password: old)
        try store(master: master, password: new, hint: hint)
    }

    private func store(master: SymmetricKey, password: String, hint: String?) throws {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = Self.derive(password, salt: salt, iterations: Self.iterations)
        let wrapped = try AES.GCM.seal(master.withUnsafeBytes { Data($0) }, using: key).combined!
        let config = LockConfig(iterations: Self.iterations, salt: salt, wrappedMasterKey: wrapped,
                                hint: hint?.isEmpty == true ? nil : hint)
        try SafeWrite.write(try JSONEncoder().encode(config), to: configURL)
        self.config = config
    }

    static func derive(_ password: String, salt: Data, iterations: Int) -> SymmetricKey {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return SymmetricKey(data: out)
    }

    // MARK: Notes

    public static func seal(text: String, title: String, master: SymmetricKey) throws -> Data {
        let noteKey = SymmetricKey(size: .bits256)
        let wrapped = try AES.GCM.seal(noteKey.withUnsafeBytes { Data($0) }, using: master).combined!
        let payload = try JSONEncoder().encode(LockedPayload(text: text))
        let sealed = try AES.GCM.seal(payload, using: noteKey).combined!
        let envelope = LockedEnvelope(title: title, wrappedKey: wrapped.base64EncodedString(),
                                      ciphertext: sealed.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func open(_ data: Data, master: SymmetricKey) throws -> String {
        guard let envelope = try? JSONDecoder().decode(LockedEnvelope.self, from: data),
              let wrapped = Data(base64Encoded: envelope.wrappedKey),
              let sealed = Data(base64Encoded: envelope.ciphertext) else { throw LockError.damaged }
        guard let rawKey = try? AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: master) else {
            throw LockError.wrongPassword
        }
        let payload = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: rawKey))
        return try JSONDecoder().decode(LockedPayload.self, from: payload).text
    }
}

extension Library {
    /// Locks a note: the Markdown file is replaced by an encrypted `.pero-locked` file.
    @discardableResult
    public func lock(_ path: String, master: SymmetricKey) throws -> String {
        guard let record = record(path), !record.isLocked else { return path }
        let text = try loadBuffer(path).text
        let data = try NoteLocker.seal(text: text, title: record.displayTitle, master: master)
        let base = (record.fileName as NSString).deletingPathExtension
        let target = FileNames.unique(base, ext: Self.lockedExtension, in: url(record.folder))
        try data.write(to: target, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: url(path))
        let newPath = record.folder.isEmpty ? target.lastPathComponent : record.folder + "/" + target.lastPathComponent
        replaceAfterConversion(from: path, to: newPath)
        return newPath
    }

    /// Removes the lock: the note becomes a plain Markdown file again.
    @discardableResult
    public func removeLock(_ path: String, master: SymmetricKey) throws -> String {
        guard let record = record(path), record.isLocked else { return path }
        let text = try NoteLocker.open(Data(contentsOf: url(path)), master: master)
        let base = (record.fileName as NSString).deletingPathExtension
        let target = FileNames.unique(base, ext: Self.noteExtension, in: url(record.folder))
        try Data(text.utf8).write(to: target, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: url(path))
        let newPath = record.folder.isEmpty ? target.lastPathComponent : record.folder + "/" + target.lastPathComponent
        replaceAfterConversion(from: path, to: newPath)
        return newPath
    }

    public func readLocked(_ path: String, master: SymmetricKey) throws -> String {
        try NoteLocker.open(Data(contentsOf: url(path)), master: master)
    }

    /// Saves the text of an unlocked note, encrypted again.
    public func saveLocked(_ path: String, text: String, master: SymmetricKey) throws {
        let title = NoteParser.parse(text).title
        let data = try NoteLocker.seal(text: text, title: title.isEmpty ? FileNames.untitled : title, master: master)
        try SafeWrite.write(data, to: url(path))
        rescanOne(path)
    }
}
