import Foundation
import PeroKit

/// The interface language — English or Russian, as macOS picks from the app's
/// localizations — and the names the app gives to what it creates on disk.
enum UILanguage {
    static let code = Bundle.main.preferredLocalizations.first ?? "en"
    static var isRussian: Bool { code.hasPrefix("ru") }
    static var locale: Locale { Locale(identifier: isRussian ? "ru_RU" : code) }

    /// Runs before a library opens. A library keeps the Quick Notes folder it already
    /// has, whichever language it was made in.
    static func setUp(libraryRoot: URL) {
        PeroStrings.localize = { String(localized: String.LocalizationValue($0)) }
        PeroStrings.locale = locale
        FileNames.untitled = String(localized: "Новая заметка")
        Library.importedFolder = String(localized: "Импортированные заметки")
        let existing = ["Быстрые заметки", "Quick Notes"].first {
            FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent($0).path)
        }
        Library.quickFolder = existing ?? String(localized: "Быстрые заметки")
    }
}
