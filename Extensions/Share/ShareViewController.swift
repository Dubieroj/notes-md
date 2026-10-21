import AppKit
import UniformTypeIdentifiers

/// «Поделиться ▸ Заметки.md»: text, links, pictures and files from any app become a new note
/// (or a Quick Note). The note waits in the shared inbox until Перо picks it up.
final class ShareViewController: NSViewController {
    private let textView = NSTextView()
    private let quick = NSButton(checkboxWithTitle: String(localized: "В быструю заметку"), target: nil, action: nil)
    private var files: [URL] = []
    private let status = NSTextField(labelWithString: "")

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let title = NSTextField(labelWithString: String(localized: "Новая заметка в Заметках.md"))
        title.font = .boldSystemFont(ofSize: 13)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.autoresizingMask = [.width]
        status.textColor = .secondaryLabelColor
        let cancel = NSButton(title: String(localized: "Отменить"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: String(localized: "Сохранить"), target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        for v in [title, scroll, quick, status, cancel, save] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: quick.topAnchor, constant: -10),
            quick.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            quick.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])
        view = root
        load()
    }

    /// Text, a page (title + address) or files from the share request.
    private func load() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var parts: [String] = []
        if let title = items.first?.attributedTitle?.string, !title.isEmpty { parts.append("# " + title) }
        if let body = items.first?.attributedContentText?.string, !body.isEmpty { parts.append(body) }
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    defer { group.leave() }
                    lock.lock(); defer { lock.unlock() }
                    if let url = item as? URL ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) {
                        if url.isFileURL { self.files.append(url) } else { parts.append(url.absoluteString) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                    try? FileManager.default.copyItem(at: url, to: copy)
                    lock.lock(); self.files.append(copy); lock.unlock()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    defer { group.leave() }
                    lock.lock(); defer { lock.unlock() }
                    if let text = item as? String { parts.append(text) }
                }
            }
        }
        group.notify(queue: .main) {
            self.textView.string = parts.joined(separator: "\n\n")
            if !self.files.isEmpty { self.status.stringValue = String(localized: "Файлов: \(self.files.count)") }
        }
    }

    @objc private func save(_ sender: Any?) {
        let fm = FileManager.default
        let id = UUID().uuidString
        let dir = SharedContainer.inboxURL.appendingPathComponent(id)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var names: [String] = []
            for file in files {
                var name = file.lastPathComponent.replacingOccurrences(of: #"^[0-9A-F-]{36}-"#, with: "", options: .regularExpression)
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                var n = 2
                while names.contains(name) {
                    name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    n += 1
                }
                try fm.copyItem(at: file, to: dir.appendingPathComponent(name))
                names.append(name)
            }
            let item = InboxItem(text: textView.string, quick: quick.state == .on, folder: nil, files: names, created: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // The JSON goes last: Перо takes an item only once its file is complete.
            try encoder.encode(item).write(to: dir.appendingPathComponent("note.json"), options: .atomic)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            extensionContext?.cancelRequest(withError: error)
        }
    }

    @objc private func cancel(_ sender: Any?) {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
