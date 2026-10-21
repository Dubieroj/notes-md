import AppKit
import CryptoKit
import LocalAuthentication
import PeroKit
import Security

/// Keeps the key of locked notes in memory while they are open, as Notes does: one
/// password opens all of them until a period of inactivity, sleep, screen lock or quit.
final class LockManager {
    static let didChange = Notification.Name("PeroLockDidChange")

    let library: Library
    let locker: NoteLocker
    private(set) var master: SymmetricKey?
    private var lastActivity = Date()
    private var timer: Timer?

    init(library: Library) {
        self.library = library
        locker = NoteLocker(library: library)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(lockNow), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(lockNow), name: NSWorkspace.screensDidSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockNow),
                                                            name: .init("com.apple.screenIsLocked"), object: nil)
    }

    var isUnlocked: Bool { master != nil }
    var hasPassword: Bool { locker.hasPassword }
    var hint: String? { locker.hint }

    func touch() { lastActivity = Date() }

    func unlock(password: String) -> Bool {
        guard let key = try? locker.unlock(password: password) else { return false }
        opened(key)
        remember(key)
        return true
    }

    func setPassword(_ password: String, hint: String?) throws {
        let key = try locker.setPassword(password, hint: hint)
        opened(key)
        remember(key)
    }

    /// The key is kept for Touch ID only on a Mac that has it, and only while it is on.
    private func remember(_ key: SymmetricKey) {
        if Settings.useTouchID && Self.canUseBiometrics {
            Keychain.store(key, for: library.root)
        } else {
            Keychain.remove(for: library.root)
        }
    }

    func changePassword(from old: String, to new: String, hint: String?) throws {
        try locker.changePassword(from: old, to: new, hint: hint)
    }

    static var canUseBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Touch ID: the key was saved in the keychain the last time the password was typed.
    func unlockWithTouchID(_ done: @escaping (Bool) -> Void) {
        guard Settings.useTouchID, Self.canUseBiometrics, Keychain.load(for: library.root) != nil else { return done(false) }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "открыть заблокированные заметки") { ok, _ in
            DispatchQueue.main.async {
                guard ok, let key = Keychain.load(for: self.library.root) else { return done(false) }
                self.opened(key)
                done(true)
            }
        }
    }

    private func opened(_ key: SymmetricKey) {
        master = key
        touch()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastActivity) > Double(Settings.autoLockMinutes * 60) { self.lockNow() }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// «Закрыть заблокированные заметки».
    @objc func lockNow() {
        guard master != nil else { return }
        master = nil
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// The key of locked notes in the login keychain, for Touch ID.
enum Keychain {
    private static let service = "local.pero.markdown.locked-notes"

    static func store(_ key: SymmetricKey, for root: URL) {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: root.path]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Заметки.md: заблокированные заметки"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(for root: URL) -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: root.path, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    static func remove(for root: URL) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: root.path] as CFDictionary)
    }
}
