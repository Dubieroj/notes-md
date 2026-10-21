import AppKit
import PeroKit
import WidgetKit

/// Writes what widgets show into the shared container and asks WidgetKit to redraw.
final class WidgetPublisher {
    private let library: Library
    private var work: DispatchWorkItem?

    init(library: Library) {
        self.library = library
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: Library.didChange, object: library)
        publish()
    }

    @objc private func changed() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.publish() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    func publish() {
        let records = library.notes.values.sorted { $0.modified > $1.modified }.prefix(300)
        let pinned = Set(library.state.pinned)
        let thumbs = SharedContainer.thumbnailsURL
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let notes = records.map { r in
            WidgetSnapshot.Note(path: r.path, title: r.displayTitle, preview: r.isLocked ? "" : r.preview, folder: r.folder,
                                modified: r.modified, pinned: pinned.contains(r.path), locked: r.isLocked, thumbnail: nil)
        }
        let snapshot = WidgetSnapshot(notes: Array(notes), folders: library.folders.filter { $0 != Library.quickFolder }, generated: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: SharedContainer.snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: SharedContainer.snapshotURL, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            NSLog("Pero: widgets snapshot: \(error)")
        }
    }
}

/// Notes sent from «Поделиться»: each waits in the shared inbox as a folder with
/// note.json and its files; Перо turns it into a note and removes it.
final class InboxReader {
    private let library: Library
    private var watcher: DirectoryWatcher?

    init(library: Library) {
        self.library = library
        try? FileManager.default.createDirectory(at: SharedContainer.inboxURL, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: SharedContainer.inboxURL, latency: 0.5) { [weak self] _ in self?.ingest() }
        ingest()
    }

    func ingest() {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = (try? fm.contentsOfDirectory(at: SharedContainer.inboxURL, includingPropertiesForKeys: nil)) ?? []
        for dir in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let json = dir.appendingPathComponent("note.json")
            guard let data = try? Data(contentsOf: json), let item = try? decoder.decode(InboxItem.self, from: data) else { continue }
            let wanted = item.folder ?? ""
            let folder = item.quick ? Library.quickFolder : Library.isInsideFolder(wanted) ? wanted : ""
            var text = item.text
            for name in item.files.map({ ($0 as NSString).lastPathComponent }) {
                guard let file = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let path = try? library.addAttachment(data: file, name: name) else { continue }
                let target = library.linkTarget(to: path, fromFolder: folder)
                let isImage = FileTypes.isImage(name)
                text += (text.isEmpty ? "" : "\n\n") + (isImage ? "![](\(target))" : "[\(name)](\(target))")
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = String(localized: "Из «Поделиться»") }
            if (try? library.createNote(in: folder, text: text, created: item.created)) != nil {
                try? fm.removeItem(at: dir)
            }
        }
    }
}

extension AppDelegate {
    /// pero://note?path=… (widgets, Spotlight) and pero://new?folder=…
    func handlePeroURL(_ url: URL) {
        guard let main else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        switch url.host {
        case "note":
            if let path = value("path") { main.reveal(path) }
        case "new":
            main.createNote(text: Settings.newNotePrefix, in: value("folder"), focus: true)
        default: break
        }
    }
}
