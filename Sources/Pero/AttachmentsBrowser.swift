import AppKit
import PeroKit
import SwiftUI

/// Вид ▸ Вложения (⌘3): every attachment of the library by kind, as in Notes.
final class AttachmentsWindowController: NSWindowController {
    private static var shared: AttachmentsWindowController?

    static func show(library: Library, reveal: @escaping (String) -> Void) {
        if shared == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = String(localized: "Вложения")
            window.setFrameAutosaveName("PeroAttachments")
            shared = AttachmentsWindowController(window: window)
        }
        let model = AttachmentsModel(library: library)
        shared?.window?.contentViewController = NSHostingController(rootView: AttachmentsView(model: model, reveal: reveal))
        shared?.showWindow(nil)
        model.load()
    }
}

struct AttachmentItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case photos = "Фото и видео", scans = "Сканы", sketches = "Рисунки", audio = "Аудио", documents = "Документы", links = "Ссылки"
        var id: String { rawValue }
    }

    let id: String
    let kind: Kind
    let path: String       // library path of the file, or the address for links
    let notePath: String
    let noteTitle: String
    var name: String { kind == .links ? path : (path as NSString).lastPathComponent.replacingOccurrences(of: #"^[0-9a-f]{6}-"#, with: "", options: .regularExpression) }
}

final class AttachmentsModel: ObservableObject {
    let library: Library
    @Published var items: [AttachmentItem] = []
    @Published var kind: AttachmentItem.Kind = .photos
    @Published var loading = true

    init(library: Library) { self.library = library }

    /// Reads the notes in the background and collects what they link to.
    func load() {
        let notes = library.notes.values.filter { !$0.isLocked }
        let root = library.root
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [AttachmentItem] = []
            var seen = Set<String>()
            let url = try! NSRegularExpression(pattern: #"https?://[^\s<>()\]]+"#)
            for r in notes {
                guard let data = try? Data(contentsOf: root.appendingPathComponent(r.path)),
                      let text = try? TextCodec.decode(data).text else { continue }
                for target in NoteParser.parse(text).localTargets {
                    // Inside the library (relative) or anywhere on the Mac (absolute, ~/…).
                    guard let path = LinkRewriter.resolve(target, from: r.folder) ?? Library.absolutePicture(target),
                          !path.hasSuffix(".md"),
                          FileManager.default.fileExists(atPath: path.hasPrefix("/") ? path : root.appendingPathComponent(path).path),
                          seen.insert(path + "|" + r.path).inserted else { continue }
                    out.append(AttachmentItem(id: path + "|" + r.path, kind: Self.kind(of: path), path: path, notePath: r.path, noteTitle: r.displayTitle))
                }
                let ns = text as NSString
                for m in url.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let link = ns.substring(with: m.range)
                    guard seen.insert(link + "|" + r.path).inserted else { continue }
                    out.append(AttachmentItem(id: link + "|" + r.path, kind: .links, path: link, notePath: r.path, noteTitle: r.displayTitle))
                }
            }
            DispatchQueue.main.async {
                self.items = out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.loading = false
            }
        }
    }

    static func kind(of path: String) -> AttachmentItem.Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent
        if name.contains("Скан") || name.contains("Scan") { return .scans }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "mov", "mp4", "m4v": return .photos
        case "svg": return .sketches
        case "m4a", "mp3", "wav", "aac", "caf", "aiff": return .audio
        default: return .documents
        }
    }
}

private struct AttachmentsView: View {
    @ObservedObject var model: AttachmentsModel
    let reveal: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.kind) {
                ForEach(AttachmentItem.Kind.allCases) { k in Text(LocalizedStringKey(k.rawValue)).tag(k) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            let shown = model.items.filter { $0.kind == model.kind }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text("Нет вложений").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.kind == .links || model.kind == .documents || model.kind == .audio {
                List(shown) { item in
                    HStack {
                        Image(systemName: model.kind == .links ? "link" : model.kind == .audio ? "waveform" : "doc")
                        VStack(alignment: .leading) {
                            Text(item.name).lineLimit(1)
                            Text(item.noteTitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Показать в заметке") { reveal(item.notePath) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(item) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 14) {
                        ForEach(shown) { item in
                            AttachmentTile(item: item, library: model.library)
                                .onTapGesture(count: 2) { open(item) }
                                .contextMenu {
                                    Button("Показать в заметке") { reveal(item.notePath) }
                                    Button("Открыть") { open(item) }
                                    Button("Показать в Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([model.library.fileURL(for: item.path)])
                                    }
                                }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func open(_ item: AttachmentItem) {
        if item.kind == .links, let url = URL(string: item.path) { NSWorkspace.shared.open(url) } else {
            NSWorkspace.shared.open(model.library.fileURL(for: item.path))
        }
    }
}

private struct AttachmentTile: View {
    let item: AttachmentItem
    let library: Library
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternaryLabelColor))
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.noteTitle).font(.caption).lineLimit(1).frame(width: 140)
        }
        .onAppear {
            Thumbnails.shared.thumbnail(for: library.fileURL(for: item.path), size: 280) { image = $0 }
        }
    }
}
