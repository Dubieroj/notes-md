import AppIntents
import SwiftUI
import WidgetKit

// Widgets as in Notes: one note, a folder, pinned notes. They read the snapshot Перо
// writes to the shared container; a click opens the note in Перо.

struct NoteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Заметка"
    static var defaultQuery = NoteQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct NoteQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        let notes = WidgetSnapshot.load()?.notes ?? []
        return identifiers.compactMap { id in notes.first { $0.path == id }.map { NoteEntity(id: $0.path, title: $0.title) } }
    }

    func suggestedEntities() async throws -> [NoteEntity] {
        (WidgetSnapshot.load()?.notes ?? []).prefix(50).map { NoteEntity(id: $0.path, title: $0.title) }
    }
}

struct FolderEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Папка"
    static var defaultQuery = FolderQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: id.isEmpty ? "Заметки" : "\((id as NSString).lastPathComponent)")
    }
}

struct FolderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FolderEntity] { identifiers.map(FolderEntity.init) }
    func suggestedEntities() async throws -> [FolderEntity] {
        ([""] + (WidgetSnapshot.load()?.folders ?? [])).map(FolderEntity.init)
    }
}

struct NoteWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Заметка"
    static var description = IntentDescription("Показывает выбранную заметку.")
    @Parameter(title: "Заметка") var note: NoteEntity?
}

struct FolderWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Папка"
    static var description = IntentDescription("Показывает последние заметки папки.")
    @Parameter(title: "Папка") var folder: FolderEntity?
}

struct NotesEntry: TimelineEntry {
    var date: Date
    var notes: [WidgetSnapshot.Note]
    var title: String
    var link: URL
}

private func entry(notes: [WidgetSnapshot.Note], title: String, link: URL) -> Timeline<NotesEntry> {
    Timeline(entries: [NotesEntry(date: Date(), notes: notes, title: title, link: link)], policy: .after(Date().addingTimeInterval(1800)))
}

struct NoteProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NotesEntry {
        NotesEntry(date: Date(), notes: [], title: String(localized: "Заметка"), link: PeroLinks.newNote())
    }

    func snapshot(for configuration: NoteWidgetIntent, in context: Context) async -> NotesEntry {
        await timeline(for: configuration, in: context).entries[0]
    }

    func timeline(for configuration: NoteWidgetIntent, in context: Context) async -> Timeline<NotesEntry> {
        let notes = WidgetSnapshot.load()?.notes ?? []
        let note = configuration.note.flatMap { n in notes.first { $0.path == n.id } } ?? notes.first
        return entry(notes: note.map { [$0] } ?? [], title: note?.title ?? String(localized: "Нет заметок"),
                     link: note.map { PeroLinks.note($0.path) } ?? PeroLinks.newNote())
    }
}

struct FolderProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NotesEntry {
        NotesEntry(date: Date(), notes: [], title: String(localized: "Заметки"), link: PeroLinks.newNote())
    }

    func snapshot(for configuration: FolderWidgetIntent, in context: Context) async -> NotesEntry {
        await timeline(for: configuration, in: context).entries[0]
    }

    func timeline(for configuration: FolderWidgetIntent, in context: Context) async -> Timeline<NotesEntry> {
        let folder = configuration.folder?.id ?? ""
        let notes = (WidgetSnapshot.load()?.notes ?? []).filter { $0.folder == folder }.sorted { $0.modified > $1.modified }
        let title = folder.isEmpty ? String(localized: "Заметки") : (folder as NSString).lastPathComponent
        return entry(notes: Array(notes.prefix(8)), title: title, link: PeroLinks.newNote(folder: folder))
    }
}

struct PinnedProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesEntry {
        NotesEntry(date: Date(), notes: [], title: String(localized: "Закреплённые"), link: PeroLinks.newNote())
    }

    func getSnapshot(in context: Context, completion: @escaping (NotesEntry) -> Void) {
        getTimeline(in: context) { completion($0.entries[0]) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesEntry>) -> Void) {
        let notes = (WidgetSnapshot.load()?.notes ?? []).filter(\.pinned).sorted { $0.modified > $1.modified }
        completion(entry(notes: Array(notes.prefix(8)), title: String(localized: "Закреплённые"), link: PeroLinks.newNote()))
    }
}

struct SingleNoteView: View {
    var entry: NotesEntry

    var body: some View {
        if let note = entry.notes.first {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.headline).lineLimit(2)
                if note.locked {
                    Label("Заблокировано", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(note.preview).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(note.modified, style: .date).font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(PeroLinks.note(note.path))
        } else {
            Text("Нет заметок").foregroundStyle(.secondary).widgetURL(entry.link)
        }
    }
}

struct NoteListView: View {
    var entry: NotesEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "note.text").foregroundStyle(.yellow)
                Text(entry.title).font(.headline).lineLimit(1)
                Spacer()
                Link(destination: entry.link) { Image(systemName: "square.and.pencil") }
            }
            if entry.notes.isEmpty {
                Text("Нет заметок").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.notes.prefix(family == .systemLarge ? 8 : family == .systemMedium ? 3 : 2)) { note in
                Link(destination: PeroLinks.note(note.path)) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            if note.locked { Image(systemName: "lock.fill").font(.caption2) }
                            Text(note.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        if family != .systemSmall && !note.locked {
                            Text(note.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NoteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "pero.note", intent: NoteWidgetIntent.self, provider: NoteProvider()) { entry in
            SingleNoteView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Заметка")
        .description("Одна заметка на рабочем столе.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FolderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "pero.folder", intent: FolderWidgetIntent.self, provider: FolderProvider()) { entry in
            NoteListView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Папка")
        .description("Последние заметки папки.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PinnedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "pero.pinned", provider: PinnedProvider()) { entry in
            NoteListView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Закреплённые")
        .description("Закреплённые заметки.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct PeroWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoteWidget()
        FolderWidget()
        PinnedWidget()
    }
}
