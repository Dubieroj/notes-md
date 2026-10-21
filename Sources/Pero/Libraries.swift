import CryptoKit
import Foundation
import PeroKit

/// The main library plus folders linked from anywhere on the Mac. A linked folder is
/// read and edited in place; Перо keeps its index, trash and state for it elsewhere.
final class Libraries {
    static let didChange = Notification.Name("PeroLibrariesDidChange")

    private(set) var main: Library
    private(set) var linked: [Library] = []
    var all: [Library] { [main] + linked }

    init(main: Library) {
        self.main = main
        for path in Settings.linkedFolders {
            if let library = try? open(URL(fileURLWithPath: path)) { linked.append(library) }
        }
    }

    private func open(_ url: URL) throws -> Library {
        let library = try Library(root: url, meta: Self.metaDirectory(for: url))
        library.renamesFilesAfterTitle = false
        return library
    }

    /// Where Перо keeps its data for a linked folder: one folder per path, outside it.
    static func metaDirectory(for url: URL) -> URL {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return Settings.linkedDataURL.appendingPathComponent(url.lastPathComponent + "-" + hash)
    }

    enum LinkError: LocalizedError {
        case overlaps, alreadyLinked

        var errorDescription: String? {
            switch self {
            case .overlaps: return String(localized: "Эта папка пересекается с библиотекой заметок")
            case .alreadyLinked: return String(localized: "Эта папка уже подключена")
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .overlaps: return String(localized: "Нельзя подключить папку библиотеки, папку внутри неё или папку, в которой она лежит.")
            case .alreadyLinked: return nil
            }
        }
    }

    private static func path(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let pa = path(a), pb = path(b)
        return pa == pb || pa.hasPrefix(pb + "/") || pb.hasPrefix(pa + "/")
    }

    @discardableResult
    func link(_ url: URL) throws -> Library {
        if linked.contains(where: { Self.path($0.root) == Self.path(url) }) { throw LinkError.alreadyLinked }
        if Self.overlaps(url, main.root) || linked.contains(where: { Self.overlaps($0.root, url) }) { throw LinkError.overlaps }
        let library = try open(url)
        linked.append(library)
        save()
        return library
    }

    func unlink(_ library: Library) {
        linked.removeAll { $0 === library }
        save()
    }

    /// The main library moved to another folder (Settings).
    func replaceMain(_ library: Library) {
        linked.removeAll { Self.overlaps($0.root, library.root) }
        main = library
        save()
    }

    private func save() {
        Settings.linkedFolders = linked.map(\.root.path)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The library that holds a file, with the file's path inside it.
    func locate(_ url: URL) -> (Library, String)? {
        for library in all {
            if let path = Library.relative(url.resolvingSymlinksInPath(), to: library.root), library.record(path) != nil {
                return (library, path)
            }
        }
        return nil
    }

    func library(withRoot path: String) -> Library? {
        all.first { Self.path($0.root) == Self.path(URL(fileURLWithPath: path)) }
    }
}

extension Library {
    /// Moves notes into a folder of another library, pictures and files included: the
    /// note's relative links are pointed at copies in the target's Attachments. The
    /// originals go to this library's «Недавно удалённые». Returns the new paths.
    func transfer(_ paths: [String], to target: Library, folder: String) throws -> [String] {
        var moved: [String] = []
        for path in paths {
            guard let record = record(path), !record.isLocked else { continue }
            var text = try loadBuffer(path).text
            for raw in NoteParser.parse(text).localTargets {
                guard let inside = LinkRewriter.resolve(raw, from: record.folder), !inside.hasSuffix(".md"),
                      let data = try? Data(contentsOf: url(inside)) else { continue }
                let copy = try target.addAttachment(data: data, name: (inside as NSString).lastPathComponent)
                let link = target.linkTarget(to: copy, fromFolder: folder)
                text = text.replacingOccurrences(of: "](" + raw + ")", with: "](" + link + ")")
                    .replacingOccurrences(of: "src=\"" + raw + "\"", with: "src=\"" + LinkRewriter.relative(from: folder, to: copy) + "\"")
            }
            let values = try? url(path).resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let newPath = try target.createNote(in: folder, text: text,
                                                fileName: (record.fileName as NSString).deletingPathExtension,
                                                created: values?.creationDate, modified: values?.contentModificationDate)
            moved.append(newPath)
        }
        let done = paths.filter { p in record(p).map { !$0.isLocked } ?? false }
        try trash(done)
        return moved
    }
}
