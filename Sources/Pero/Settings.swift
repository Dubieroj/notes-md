import Foundation
import PeroKit

/// App settings (Notes's Settings window plus Перо's own), in UserDefaults.
enum Settings {
    static let didChange = Notification.Name("PeroSettingsDidChange")
    /// Automated checks keep their settings apart from the user's.
    #if PERO_TEST_HOOKS
    static let isTesting = ProcessInfo.processInfo.environment["PERO_TEST_DIR"] != nil
    #else
    static let isTesting = false
    #endif
    static let defaults: UserDefaults = isTesting ? UserDefaults(suiteName: "local.pero.markdown.tests")! : .standard
    private static var d: UserDefaults { defaults }

    private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

    /// The library folder. Tests point PERO_LIBRARY at a temporary folder.
    static var libraryURL: URL {
        if isTesting, let env = ProcessInfo.processInfo.environment["PERO_LIBRARY"] { return URL(fileURLWithPath: env) }
        if let custom = d.url(forKey: "libraryURL") { return custom }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Pero/Library")
    }

    static func setLibraryURL(_ url: URL?) { d.set(url, forKey: "libraryURL") }

    /// Folders linked from the disk, shown in the sidebar under «Папки на диске».
    static var linkedFolders: [String] {
        get { d.stringArray(forKey: "linkedFolders") ?? [] }
        set { d.set(newValue, forKey: "linkedFolders") }
    }

    /// Перо's index and trash for linked folders (never inside those folders).
    static var linkedDataURL: URL {
        if isTesting { return libraryURL.deletingLastPathComponent().appendingPathComponent("Linked") }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Pero/Linked")
    }

    static var sortKey: SortKey {
        get { SortKey(rawValue: d.string(forKey: "sortKey") ?? "") ?? .modified }
        set { d.set(newValue.rawValue, forKey: "sortKey"); changed() }
    }

    /// Newest first unless set otherwise; by title A→Я.
    static var sortAscending: Bool {
        get { d.object(forKey: "sortAscending") as? Bool ?? (sortKey == .title) }
        set { d.set(newValue, forKey: "sortAscending"); changed() }
    }

    static var groupByDate: Bool {
        get { d.object(forKey: "groupByDate") as? Bool ?? true }
        set { d.set(newValue, forKey: "groupByDate"); changed() }
    }

    /// «Новые заметки начинаются с»: h1 (Название), h2, h3 or body.
    static var newNoteStyle: String {
        get { d.string(forKey: "newNoteStyle") ?? "h1" }
        set { d.set(newValue, forKey: "newNoteStyle"); changed() }
    }

    static var newNotePrefix: String {
        switch newNoteStyle {
        case "h1": return "# "
        case "h2": return "## "
        case "h3": return "### "
        default: return ""
        }
    }

    static var autoSortChecked: Bool {
        get { d.bool(forKey: "autoSortChecked") }
        set { d.set(newValue, forKey: "autoSortChecked"); changed() }
    }

    static var resumeLastQuickNote: Bool {
        get { d.bool(forKey: "resumeLastQuickNote") }
        set { d.set(newValue, forKey: "resumeLastQuickNote"); changed() }
    }

    /// Text size of notes, as a factor (⇧⌘. and ⇧⌘, change it).
    static var zoom: Double {
        get { let z = d.double(forKey: "zoom"); return z == 0 ? 1 : z }
        set { d.set(min(3, max(0.5, newValue)), forKey: "zoom"); changed() }
    }

    static var galleryView: Bool {
        get { d.bool(forKey: "galleryView") }
        set { d.set(newValue, forKey: "galleryView"); changed() }
    }

    static var lastScope: String? {
        get { d.string(forKey: "lastScope") }
        set { d.set(newValue, forKey: "lastScope") }
    }

    static var quickNoteShortcut: Bool {
        get { d.object(forKey: "quickNoteShortcut") as? Bool ?? true }
        set { d.set(newValue, forKey: "quickNoteShortcut"); changed() }
    }

    static var useTouchID: Bool {
        get { d.object(forKey: "useTouchID") as? Bool ?? true }
        set { d.set(newValue, forKey: "useTouchID"); changed() }
    }

    static var autoLockMinutes: Int {
        get { d.object(forKey: "autoLockMinutes") as? Int ?? 5 }
        set { d.set(newValue, forKey: "autoLockMinutes"); changed() }
    }

    static var writingTools: Bool {
        get { d.object(forKey: "writingTools") as? Bool ?? true }
        set { d.set(newValue, forKey: "writingTools"); changed() }
    }

    static var showDockBadge: Bool {
        get { d.bool(forKey: "showDockBadge") }
        set { d.set(newValue, forKey: "showDockBadge"); changed() }
    }

    static var showWordCount: Bool {
        get { d.bool(forKey: "showWordCount") }
        set { d.set(newValue, forKey: "showWordCount"); changed() }
    }

    static var backupInterval: Int {  // days; 0 = off
        get { d.integer(forKey: "backupInterval") }
        set { d.set(newValue, forKey: "backupInterval"); changed() }
    }

    static var backupFolder: URL? {
        get { d.url(forKey: "backupFolder") }
        set { d.set(newValue, forKey: "backupFolder"); changed() }
    }

    static var lastBackup: Date? {
        get { d.object(forKey: "lastBackup") as? Date }
        set { d.set(newValue, forKey: "lastBackup") }
    }
}

extension Scope {
    var encoded: String {
        switch self {
        case .all: return "all"
        case .quick: return "quick"
        case .trash: return "trash"
        case .folder(let p): return "folder:" + p
        case .smart(let id): return "smart:" + id
        case .tags(let t): return "tags:" + t.joined(separator: "\u{1F}")
        }
    }

    init?(encoded: String) {
        switch encoded {
        case "all": self = .all
        case "quick": self = .quick
        case "trash": self = .trash
        default:
            if encoded.hasPrefix("folder:") { self = .folder(String(encoded.dropFirst(7))) }
            else if encoded.hasPrefix("smart:") { self = .smart(String(encoded.dropFirst(6))) }
            else if encoded.hasPrefix("tags:") {
                let rest = encoded.dropFirst(5)
                self = .tags(rest.isEmpty ? [] : rest.components(separatedBy: "\u{1F}"))
            } else { return nil }
        }
    }
}
