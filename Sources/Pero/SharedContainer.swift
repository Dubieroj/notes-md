import Foundation

/// The App Group folder shared by Перо and its extensions. The app is the only one
/// that writes the library; extensions read a snapshot and drop new notes in an inbox.
enum SharedContainer {
    /// "<team>.local.pero", filled in from the signing team at build time (Info.plist).
    /// An unsigned SwiftPM build has no extensions, so its own folder name is enough.
    static let group: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "PeroAppGroup") as? String ?? ""
        return value.isEmpty || value.contains("$(") ? "local.pero" : value
    }()

    static var url: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) { return url }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/" + group)
    }

    static var snapshotURL: URL { url.appendingPathComponent("widgets/snapshot.json") }
    static var thumbnailsURL: URL { url.appendingPathComponent("widgets/thumbnails") }
    static var inboxURL: URL { url.appendingPathComponent("inbox") }
}

/// What widgets show: recent, pinned and per-folder notes, without any locked text.
struct WidgetSnapshot: Codable {
    struct Note: Codable, Hashable, Identifiable {
        var path: String
        var title: String
        var preview: String
        var folder: String
        var modified: Date
        var pinned: Bool
        var locked: Bool
        var thumbnail: String?
        var id: String { path }
    }

    var notes: [Note]
    var folders: [String]
    var generated: Date

    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: SharedContainer.snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// A note sent from «Поделиться», waiting for Перо to pick it up.
struct InboxItem: Codable {
    var text: String
    var quick: Bool
    var folder: String?
    var files: [String]
    var created: Date
}

enum PeroLinks {
    /// pero://note?path=… opens a note in Перо.
    static func note(_ path: String) -> URL {
        var c = URLComponents()
        c.scheme = "pero"
        c.host = "note"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return c.url!
    }

    static func newNote(folder: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = "pero"
        c.host = "new"
        if let folder { c.queryItems = [URLQueryItem(name: "folder", value: folder)] }
        return c.url!
    }
}
