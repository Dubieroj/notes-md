import AppKit
import PeroKit
import UniformTypeIdentifiers

/// Export of library notes: Markdown with its attachments, one-file HTML with pictures
/// inside, PDF and plain text. Single notes, selections and whole folders.
struct LibraryExport {
    let library: Library
    let editor: EditorViewController

    func export(_ record: NoteRecord, as format: ExportFormat, to url: URL, done: @escaping (Error?) -> Void) {
        do {
            let text = try library.loadBuffer(record.path).text
            switch format {
            case .markdown:
                // The note sits at the top of the destination; its files go to Attachments/ next to it.
                let rebased = LinkRewriter.rebase(text, from: record.folder, to: "") ?? text
                try copyAttachments(of: text, folder: record.folder, into: url.deletingLastPathComponent())
                try Data(rebased.utf8).write(to: url, options: .atomic)
                done(nil)
            case .text:
                try Data(PlainText.from(text).utf8).write(to: url, options: .atomic)
                done(nil)
            case .html:
                editor.renderHTML(text, title: record.displayTitle, baseDir: library.url(record.folder), fileImages: true) { html in
                    guard let html else { return done(CocoaError(.fileWriteUnknown)) }
                    done(Result { try Self.inlineImages(html).write(to: url, atomically: true, encoding: .utf8) }.failure)
                }
            case .pdf:
                editor.renderHTML(text, title: record.displayTitle, baseDir: library.url(record.folder), fileImages: true) { html in
                    guard let html else { return done(CocoaError(.fileWriteUnknown)) }
                    PDFExport.write(html: html, to: url, done: done)
                }
            }
        } catch { done(error) }
    }

    /// Several notes into one folder, side by side.
    func exportMany(_ records: [NoteRecord], as format: ExportFormat, into dir: URL, done: @escaping (Error?) -> Void) {
        var queue = records
        func next() {
            guard let r = queue.first else { return done(nil) }
            queue.removeFirst()
            let url = FileNames.unique(FileNames.baseName(forTitle: r.displayTitle), ext: format.ext, in: dir)
            export(r, as: format, to: url) { error in
                if let error { return done(error) }
                next()
            }
        }
        next()
    }

    /// A folder with its subfolders, as Markdown with attachments: the same layout as
    /// in the library, so every relative link keeps working.
    func exportTree(_ records: [NoteRecord], base: String, into dir: URL, done: @escaping (Error?) -> Void) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for r in records {
                let relative = base.isEmpty ? r.path : String(r.path.dropFirst(base.count + 1))
                let target = dir.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let text = try library.loadBuffer(r.path).text
                let newFolder = (relative as NSString).deletingLastPathComponent
                // Attachments go to the top of the export, links are rebased to match.
                let rebased = rebaseForExport(text, from: r.folder, base: base, newFolder: newFolder)
                try copyAttachments(of: text, folder: r.folder, into: dir)
                try Data(rebased.utf8).write(to: target, options: .atomic)
            }
            done(nil)
        } catch { done(error) }
    }

    private func rebaseForExport(_ text: String, from folder: String, base: String, newFolder: String) -> String {
        // Links to attachments: Attachments/… at the export root; other links as they are.
        var out = text
        if let r = LinkRewriter.rebase(text, from: folder, to: "") { out = r }
        if !newFolder.isEmpty, let r = LinkRewriter.rebase(out, from: "", to: newFolder) { out = r }
        return out
    }

    /// Copies the library files a note links to (pictures, PDFs…) into `dir`, at their
    /// library-relative paths.
    private func copyAttachments(of text: String, folder: String, into dir: URL) throws {
        let fm = FileManager.default
        for target in NoteParser.parse(text).localTargets {
            guard let path = LinkRewriter.resolve(target, from: folder), !path.hasSuffix(".md") else { continue }
            let source = library.url(path)
            guard fm.fileExists(atPath: source.path) else { continue }
            let dest = dir.appendingPathComponent(path)
            if fm.fileExists(atPath: dest.path) { continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
        }
    }

    /// Local pictures become data: URIs, so the HTML file stands on its own.
    static func inlineImages(_ html: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(<img\s[^>]*?src=")(file://[^"]+)(")"#, options: [.caseInsensitive])
        let ns = html as NSString
        var out = html
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let src = ns.substring(with: m.range(at: 2))
            guard let url = URL(string: src), UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            let mime = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "svg" ? "image/svg+xml" : ext == "webp" ? "image/webp" : "image/jpeg"
            let range = Range(m.range(at: 2), in: out)!
            out.replaceSubrange(range, with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        return out
    }
}

private extension Result where Success == Void {
    var failure: Error? { if case .failure(let e) = self { return e } else { return nil } }
}

/// The PDF half of Exporter for HTML that is already rendered.
enum PDFExport {
    static func write(html: String, to url: URL, done: @escaping (Error?) -> Void) {
        Exporter.writePDF(html: html, to: url, done: done)
    }
}
