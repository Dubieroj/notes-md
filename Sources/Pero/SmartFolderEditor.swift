import AppKit
import PeroKit
import SwiftUI

/// «Новая смарт-папка» / «Изменить смарт-папку»: a name and filters, all or any of them.
enum SmartFolderEditor {
    static func present(on window: NSWindow, library: Library, folder: SmartFolder?, done: @escaping (SmartFolder) -> Void) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        let model = SmartFolderModel(folder: folder, folders: library.folders, tags: library.tagCounts().map(\.tag))
        let view = SmartFolderForm(model: model, isNew: folder == nil) { result in
            window.endSheet(sheet)
            if let result { done(result) }
        }
        sheet.contentViewController = NSHostingController(rootView: view)
        window.beginSheet(sheet)
    }
}

final class FilterRow: ObservableObject, Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case tags = "Теги", created = "Дата создания", edited = "Дата изменения", checklists = "Чек-листы"
        case attachments = "Вложения", folders = "Папки", quick = "Быстрые заметки", pinned = "Закреплённые"
        case locked = "Заблокированные", query = "Текст"
        var id: String { rawValue }
    }

    let id = UUID()
    @Published var kind: Kind = .tags
    @Published var tagMatch: TagMatch = .anySelected
    @Published var tags = ""
    @Published var dateMatch: DateMatch = .last7Days
    @Published var date1 = Date()
    @Published var date2 = Date()
    @Published var checklist: ChecklistMatch = .any
    @Published var attachment: AttachmentMatch = .any
    @Published var include = true
    @Published var folders: Set<String> = []
    @Published var flag = true
    @Published var query = ""

    init() {}

    init(_ f: SmartFilter) {
        switch f {
        case .tags(let m, let t): kind = .tags; tagMatch = m; tags = t.joined(separator: ", ")
        case .created(let m, let a, let b): kind = .created; dateMatch = m; date1 = a ?? Date(); date2 = b ?? Date()
        case .edited(let m, let a, let b): kind = .edited; dateMatch = m; date1 = a ?? Date(); date2 = b ?? Date()
        case .checklists(let m): kind = .checklists; checklist = m
        case .attachments(let m): kind = .attachments; attachment = m
        case .folders(let inc, let list): kind = .folders; include = inc; folders = Set(list)
        case .quickNotes(let v): kind = .quick; flag = v
        case .pinned(let v): kind = .pinned; flag = v
        case .locked(let v): kind = .locked; flag = v
        case .query(let q): kind = .query; query = q
        }
    }

    var filter: SmartFilter {
        switch kind {
        case .tags:
            return .tags(tagMatch, tags.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #")) }.filter { !$0.isEmpty })
        case .created: return .created(dateMatch, date1, date2)
        case .edited: return .edited(dateMatch, date1, date2)
        case .checklists: return .checklists(checklist)
        case .attachments: return .attachments(attachment)
        case .folders: return .folders(include: include, folders.sorted())
        case .quick: return .quickNotes(flag)
        case .pinned: return .pinned(flag)
        case .locked: return .locked(flag)
        case .query: return .query(query)
        }
    }
}

final class SmartFolderModel: ObservableObject {
    @Published var name: String
    @Published var matchAll: Bool
    @Published var rows: [FilterRow]
    let id: String
    let allFolders: [String]
    let allTags: [String]

    init(folder: SmartFolder?, folders: [String], tags: [String]) {
        name = folder?.name ?? "Новая смарт-папка"
        matchAll = folder?.matchAll ?? true
        rows = folder?.filters.map(FilterRow.init) ?? [FilterRow()]
        id = folder?.id ?? UUID().uuidString
        allFolders = [""] + folders.filter { $0 != Library.quickFolder }
        allTags = tags
    }

    var result: SmartFolder {
        SmartFolder(id: id, name: name.trimmingCharacters(in: .whitespaces), matchAll: matchAll, filters: rows.map(\.filter))
    }
}

private struct SmartFolderForm: View {
    @ObservedObject var model: SmartFolderModel
    let isNew: Bool
    let done: (SmartFolder?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Новая смарт-папка" : "Изменить смарт-папку").font(.headline)
            TextField("Название", text: $model.name)
            HStack {
                Text("Заметки, которые соответствуют")
                Picker("", selection: $model.matchAll) {
                    Text("всем фильтрам").tag(true)
                    Text("любому фильтру").tag(false)
                }
                .labelsHidden()
                .fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.rows) { row in
                        FilterRowView(row: row, folders: model.allFolders, tags: model.allTags) {
                            model.rows.removeAll { $0.id == row.id }
                        } canRemove: { model.rows.count > 1 }
                    }
                }
            }
            Button {
                model.rows.append(FilterRow())
            } label: {
                Label("Добавить фильтр", systemImage: "plus")
            }
            HStack {
                Spacer()
                Button("Отменить") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { done(model.result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty || model.rows.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}

private struct FilterRowView: View {
    @ObservedObject var row: FilterRow
    let folders: [String]
    let tags: [String]
    let remove: () -> Void
    let canRemove: () -> Bool

    var body: some View {
        HStack(alignment: .top) {
            Picker("", selection: $row.kind) {
                ForEach(FilterRow.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
            detail
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(!canRemove())
        }
    }

    @ViewBuilder private var detail: some View {
        switch row.kind {
        case .tags:
            VStack(alignment: .leading) {
                Picker("", selection: $row.tagMatch) {
                    Text("любой из тегов").tag(TagMatch.anySelected)
                    Text("все теги").tag(TagMatch.allSelected)
                    Text("с любым тегом").tag(TagMatch.anyTag)
                    Text("без тегов").tag(TagMatch.noTags)
                }
                .labelsHidden()
                if row.tagMatch == .anySelected || row.tagMatch == .allSelected {
                    TextField("теги через запятую", text: $row.tags)
                    if !tags.isEmpty {
                        Text(tags.prefix(12).map { "#" + $0 }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .created, .edited:
            VStack(alignment: .leading) {
                Picker("", selection: $row.dateMatch) {
                    Text("сегодня").tag(DateMatch.today)
                    Text("вчера").tag(DateMatch.yesterday)
                    Text("последние 7 дней").tag(DateMatch.last7Days)
                    Text("последние 30 дней").tag(DateMatch.last30Days)
                    Text("последние 3 месяца").tag(DateMatch.last3Months)
                    Text("последние 12 месяцев").tag(DateMatch.last12Months)
                    Text("до даты").tag(DateMatch.before)
                    Text("после даты").tag(DateMatch.after)
                    Text("между датами").tag(DateMatch.between)
                }
                .labelsHidden()
                if [.before, .after, .between].contains(row.dateMatch) {
                    DatePicker("", selection: $row.date1, displayedComponents: .date).labelsHidden()
                }
                if row.dateMatch == .between {
                    DatePicker("", selection: $row.date2, displayedComponents: .date).labelsHidden()
                }
            }
        case .checklists:
            Picker("", selection: $row.checklist) {
                Text("есть чек-лист").tag(ChecklistMatch.any)
                Text("всё отмечено").tag(ChecklistMatch.allChecked)
                Text("есть неотмеченные").tag(ChecklistMatch.someUnchecked)
                Text("нет чек-листов").tag(ChecklistMatch.none)
            }
            .labelsHidden()
        case .attachments:
            Picker("", selection: $row.attachment) {
                Text("любые").tag(AttachmentMatch.any)
                Text("фото").tag(AttachmentMatch.images)
                Text("сканы").tag(AttachmentMatch.scans)
                Text("PDF").tag(AttachmentMatch.pdfs)
                Text("документы").tag(AttachmentMatch.documents)
                Text("рисунки").tag(AttachmentMatch.sketches)
                Text("аудио").tag(AttachmentMatch.audio)
                Text("без вложений").tag(AttachmentMatch.none)
            }
            .labelsHidden()
        case .folders:
            VStack(alignment: .leading) {
                Picker("", selection: $row.include) {
                    Text("в папках").tag(true)
                    Text("не в папках").tag(false)
                }
                .labelsHidden()
                ForEach(folders, id: \.self) { f in
                    Toggle(f.isEmpty ? "Заметки" : f, isOn: Binding(
                        get: { row.folders.contains(f) },
                        set: { on in if on { row.folders.insert(f) } else { row.folders.remove(f) } }))
                }
            }
        case .quick, .pinned, .locked:
            Picker("", selection: $row.flag) {
                Text("да").tag(true)
                Text("нет").tag(false)
            }
            .labelsHidden()
            .frame(width: 100)
        case .query:
            TextField("слова для поиска", text: $row.query)
        }
    }
}
