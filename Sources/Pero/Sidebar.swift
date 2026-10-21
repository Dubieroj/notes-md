import SwiftUI

/// One entry of the folder tree. Folder contents are read on first use.
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
    private var cached: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var children: [FileNode] {
        if let cached { return cached }
        let list = FileNode.list(url)
        cached = list
        return list
    }

    /// Folders and Markdown files, folders first, hidden files skipped.
    static func list(_ dir: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.compactMap { url -> FileNode? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            guard isDir || FileTypes.isMarkdown(url) else { return nil }
            return FileNode(url: url, isDirectory: isDir)
        }
        return nodes.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

final class SidebarModel: ObservableObject {
    enum Tab: Hashable { case files, outline }

    @Published var tab: Tab = .files
    @Published private(set) var root: URL?
    @Published private(set) var tree: [FileNode] = []
    @Published var expanded: Set<URL> = []
    @Published var currentFile: URL?
    @Published var headings: [Heading] = []
    @Published var currentHeading = -1

    var openFile: (URL) -> Void = { _ in }
    var revealHeading: (Heading) -> Void = { _ in }
    var chooseFolder: () -> Void = {}

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false

    func setRoot(_ url: URL?) {
        root = url
        reload()
        if let currentFile { expandPath(to: currentFile) }
        watchRoot()
    }

    /// New, renamed and deleted files in the folder show up without a manual refresh.
    private func watchRoot() {
        watcher?.cancel()
        watcher = nil
        guard let path = root?.path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !self.reloadPending else { return }
            self.reloadPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.reloadPending = false
                self.reload()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    deinit { watcher?.cancel() }

    func reload() {
        tree = root.map { FileNode.list($0) } ?? []
    }

    func showFile(_ url: URL?) {
        currentFile = url
        if let url { expandPath(to: url) }
    }

    /// Opens the folders between the root and a file so the file is visible.
    private func expandPath(to file: URL) {
        guard let root else { return }
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while dir.path.hasPrefix(rootPath + "/") {
            expanded.insert(dir)
            dir = dir.deletingLastPathComponent()
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                Text("Файлы").tag(SidebarModel.Tab.files)
                Text("Оглавление").tag(SidebarModel.Tab.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            switch model.tab {
            case .files: FilesView(model: model)
            case .outline: OutlineView(model: model)
            }
        }
    }
}

private struct FilesView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        if let root = model.root {
            List(selection: Binding(
                get: { model.currentFile },
                set: { url in if let url, FileTypes.isMarkdown(url) { model.openFile(url) } }
            )) {
                Section {
                    ForEach(model.tree) { FileRow(node: $0, model: model) }
                } header: {
                    HStack(spacing: 4) {
                        Text(root.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Menu {
                            Button("Открыть другую папку…") { model.chooseFolder() }
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                            Button("Обновить") { model.reload() }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Папка")
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            Placeholder(text: "Откройте папку, чтобы видеть её файлы здесь.") {
                Button("Открыть папку…") { model.chooseFolder() }
            }
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    @ObservedObject var model: SidebarModel

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { model.expanded.contains(node.url) },
                set: { open in
                    if open { model.expanded.insert(node.url) } else { model.expanded.remove(node.url) }
                }
            )) {
                ForEach(node.children) { FileRow(node: $0, model: model) }
            } label: {
                Label(node.name, systemImage: "folder")
            }
        } else {
            Label(node.url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                .tag(node.url)
                .help(node.name)
        }
    }
}

private struct OutlineView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        if model.headings.isEmpty {
            Placeholder(text: "В документе пока нет заголовков.") { EmptyView() }
        } else {
            let minLevel = model.headings.map(\.level).min() ?? 1
            List(selection: Binding(
                get: { model.currentHeading >= 0 ? model.currentHeading : nil },
                set: { index in if let index, model.headings.indices.contains(index) { model.revealHeading(model.headings[index]) } }
            )) {
                ForEach(Array(model.headings.enumerated()), id: \.offset) { index, heading in
                    Text(heading.text)
                        .lineLimit(2)
                        .fontWeight(heading.level == minLevel ? .semibold : .regular)
                        .padding(.leading, CGFloat(heading.level - minLevel) * 12)
                        .tag(index)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct Placeholder<Action: View>: View {
    let text: LocalizedStringKey
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
