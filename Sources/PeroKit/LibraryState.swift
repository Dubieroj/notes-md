import Foundation

public enum SortKey: String, Codable, Sendable, CaseIterable {
    case modified, created, title
}

public struct FolderSettings: Codable, Hashable, Sendable {
    public var sort: SortKey?
    public var ascending: Bool?
    public var groupByDate: Bool?

    public init(sort: SortKey? = nil, ascending: Bool? = nil, groupByDate: Bool? = nil) {
        self.sort = sort
        self.ascending = ascending
        self.groupByDate = groupByDate
    }

    var isEmpty: Bool { sort == nil && ascending == nil && groupByDate == nil }
}

/// Everything about the library that is not inside the notes themselves.
/// Lives in .pero/state.json: readable, stable key order, friendly to git.
public struct LibraryState: Codable, Sendable {
    public var version = 1
    public var pinned: [String] = []
    public var smartFolders: [SmartFolder] = []
    public var folders: [String: FolderSettings] = [:]
    public var tagColors: [String: String] = [:]
    public var trash: [TrashItem] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        smartFolders = try c.decodeIfPresent([SmartFolder].self, forKey: .smartFolders) ?? []
        folders = try c.decodeIfPresent([String: FolderSettings].self, forKey: .folders) ?? [:]
        tagColors = try c.decodeIfPresent([String: String].self, forKey: .tagColors) ?? [:]
        trash = try c.decodeIfPresent([TrashItem].self, forKey: .trash) ?? []
    }

    static func load(from url: URL) -> LibraryState {
        guard let data = try? Data(contentsOf: url) else { return LibraryState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var state = try? decoder.decode(LibraryState.self, from: data) else {
            // A hand edit or a newer version: keep it next to the new one instead of losing pins and smart folders.
            let aside = url.deletingLastPathComponent().appendingPathComponent("state-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return LibraryState()
        }
        state.trash = state.trash.filter(\.isWellFormed)
        return state
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try SafeWrite.write(try encoder.encode(self), to: url)
    }
}

// MARK: Smart folders

public struct SmartFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var matchAll: Bool
    public var filters: [SmartFilter]

    public init(id: String = UUID().uuidString, name: String, matchAll: Bool = true, filters: [SmartFilter]) {
        self.id = id
        self.name = name
        self.matchAll = matchAll
        self.filters = filters
    }
}

public enum TagMatch: String, Codable, Sendable, CaseIterable {
    case anySelected, allSelected, anyTag, noTags
}

public enum DateMatch: String, Codable, Sendable, CaseIterable {
    case today, yesterday, last7Days, last30Days, last3Months, last12Months, before, after, between
}

public enum ChecklistMatch: String, Codable, Sendable, CaseIterable {
    case any, allChecked, someUnchecked, none
}

public enum AttachmentMatch: String, Codable, Sendable, CaseIterable {
    case any, images, scans, pdfs, documents, sketches, audio, none
}

public enum SmartFilter: Codable, Hashable, Sendable {
    case tags(TagMatch, [String])
    case created(DateMatch, Date?, Date?)
    case edited(DateMatch, Date?, Date?)
    case checklists(ChecklistMatch)
    case attachments(AttachmentMatch)
    case folders(include: Bool, [String])
    case quickNotes(Bool)
    case pinned(Bool)
    case locked(Bool)
    /// Saved search (Перо, сверх Notes).
    case query(String)
}
