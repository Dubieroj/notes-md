import AppIntents
import AppKit
import PeroKit

// Actions for «Команды» and Siri: create, append, open, find, read notes.

@MainActor
private var library: Library? { (NSApp.delegate as? AppDelegate)?.library }

struct PeroNoteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Заметка"
    static var defaultQuery = PeroNoteQuery()
    var id: String
    var title: String
    var folder: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: folder.isEmpty ? "Заметки" : "\(folder)")
    }

    init(_ r: NoteRecord) {
        id = r.path
        title = r.displayTitle
        folder = r.folder
    }
}

struct PeroNoteQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PeroNoteEntity] {
        identifiers.compactMap { library?.record($0) }.map(PeroNoteEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PeroNoteEntity] {
        (library?.search(string) ?? []).prefix(30).map(PeroNoteEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PeroNoteEntity] {
        (library?.notes.values.sorted { $0.modified > $1.modified } ?? []).prefix(30).map(PeroNoteEntity.init)
    }
}

struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Создать заметку"
    static var description = IntentDescription("Создаёт заметку в Заметках.md.")
    @Parameter(title: "Текст") var text: String
    @Parameter(title: "Папка", default: "") var folder: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PeroNoteEntity> {
        guard let library else { throw CocoaError(.fileNoSuchFile) }
        let path = try library.createNote(in: folder, text: text)
        guard let record = library.record(path) else { throw CocoaError(.fileNoSuchFile) }
        return .result(value: PeroNoteEntity(record))
    }
}

struct AppendToNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Добавить к заметке"
    static var description = IntentDescription("Дописывает текст в конец заметки.")
    @Parameter(title: "Заметка") var note: PeroNoteEntity
    @Parameter(title: "Текст") var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let library, let record = library.record(note.id), !record.isLocked else { throw CocoaError(.fileNoSuchFile) }
        SessionStore.shared.saveAll()
        let buffer = try library.loadBuffer(note.id)
        let current = buffer.text
        buffer.setText(current + (current.hasSuffix("\n") || current.isEmpty ? "" : "\n") + text + "\n")
        try library.save(note.id, buffer: buffer)
        return .result()
    }
}

struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Открыть заметку"
    static var openAppWhenRun = true
    @Parameter(title: "Заметка") var note: PeroNoteEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        (NSApp.delegate as? AppDelegate)?.handlePeroURL(PeroLinks.note(note.id))
        return .result()
    }
}

struct FindNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Найти заметки"
    @Parameter(title: "Что искать") var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PeroNoteEntity]> {
        .result(value: (library?.search(query) ?? []).map(PeroNoteEntity.init))
    }
}

struct GetNoteTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Получить текст заметки"
    @Parameter(title: "Заметка") var note: PeroNoteEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let library, let record = library.record(note.id), !record.isLocked else { throw CocoaError(.fileNoSuchFile) }
        return .result(value: try library.loadBuffer(note.id).text)
    }
}

struct PeroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateNoteIntent(), phrases: ["Создай заметку в \(.applicationName)", "Новая заметка в \(.applicationName)"],
                    shortTitle: "Новая заметка", systemImageName: "square.and.pencil")
        AppShortcut(intent: FindNotesIntent(), phrases: ["Найди заметки в \(.applicationName)"],
                    shortTitle: "Найти заметки", systemImageName: "magnifyingglass")
    }
}
