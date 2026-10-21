import Foundation

/// A note as the lists, sidebar and smart folders see it. Identity is the path
/// relative to the library root, e.g. "Работа/План.md".
public struct NoteRecord: Hashable, Sendable {
    public var path: String
    public var title: String
    public var preview: String
    public var created: Date
    public var modified: Date
    public var size: Int
    public var tags: [String]
    public var wikiLinks: [String]
    public var tasksTotal: Int
    public var tasksDone: Int
    public var flags: NoteFlags
    /// Library-relative path of the first local image, if any.
    public var firstImage: String?
    public var isLocked: Bool
    public var words: Int

    public init(path: String, title: String, preview: String, created: Date, modified: Date, size: Int,
                tags: [String] = [], wikiLinks: [String] = [], tasksTotal: Int = 0, tasksDone: Int = 0,
                flags: NoteFlags = [], firstImage: String? = nil, isLocked: Bool = false, words: Int = 0) {
        self.path = path
        self.title = title
        self.preview = preview
        self.created = created
        self.modified = modified
        self.size = size
        self.tags = tags
        self.wikiLinks = wikiLinks
        self.tasksTotal = tasksTotal
        self.tasksDone = tasksDone
        self.flags = flags
        self.firstImage = firstImage
        self.isLocked = isLocked
        self.words = words
    }

    /// Folder path relative to the root; "" is the root («Заметки»).
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var fileName: String { (path as NSString).lastPathComponent }
    public var displayTitle: String { title.isEmpty ? "Новая заметка" : title }
    public var isQuickNote: Bool { folder == Library.quickFolder }

    public func hasTag(_ tag: String) -> Bool {
        let key = tag.lowercased()
        return tags.contains { $0.lowercased() == key }
    }
}

/// A note in «Недавно удалённые».
public struct TrashItem: Codable, Hashable, Sendable {
    public var id: String
    public var originalPath: String
    public var deletedAt: Date
    /// Path inside .pero/trash.
    public var file: String

    /// Its id and file name become paths inside .pero/trash, and its original path is where
    /// it goes back to: none of them may point anywhere else.
    var isWellFormed: Bool {
        let name = file.hasPrefix(id + "/") ? String(file.dropFirst(id.count + 1)) : ""
        return UUID(uuidString: id) != nil && !name.isEmpty && !name.contains("/") && name != ".." && name != "."
            && Library.isInsideFolder(originalPath)
    }

    public func daysLeft(now: Date = Date(), retention: Int = Library.trashDays) -> Int {
        let passed = Calendar.current.dateComponents([.day], from: deletedAt, to: now).day ?? 0
        return max(0, retention - passed)
    }
}
