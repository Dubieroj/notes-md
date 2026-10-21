import AppKit
import PeroKit
import UniformTypeIdentifiers
import WebKit

/// Serves the editor page from the app bundle (pero://app/…) and local images
/// referenced by documents (pero://file/<absolute path>).
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pero"
    static let pageURL = URL(string: "pero://app/index.html")!

    private static let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web").standardizedFileURL

    /// Folder a web view may read pictures from (the library); none means any folder,
    /// as for Markdown files opened from Finder.
    static var allowedRoots: [ObjectIdentifier: URL] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(for: url),
              Self.isAllowed(file, root: Self.allowedRoots[ObjectIdentifier(webView)]),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func isAllowed(_ file: URL, root: URL?) -> Bool {
        guard let root, file.isFileURL, url(file, isUnder: webRoot) == false else { return true }
        return url(file, isUnder: root)
    }

    private static func url(_ file: URL, isUnder root: URL) -> Bool {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base + "/")
    }

    private static func file(for url: URL) -> URL? {
        switch url.host {
        case "app":
            let file = webRoot.appendingPathComponent(url.path).standardizedFileURL
            return file.path.hasPrefix(webRoot.path + "/") ? file : nil
        case "file":
            // Only images: the page has no business reading other files.
            let file = URL(fileURLWithPath: url.path)
            guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) else { return nil }
            return file
        default:
            return nil
        }
    }
}

enum FileTypes {
    static let markdownExtensions = Library.markdownExtensions
    static let markdownType = "net.daringfireball.markdown"

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// A file shown as a picture in a note (`![](…)`) rather than as a file card.
    static func isImage(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true
    }

    /// The types Finder knows Markdown files by: the common one and the ones other apps
    /// declared for some extensions (Typora's for .mkd, .mdwn…).
    static var markdownTypes: [UTType] {
        guard let common = UTType(markdownType) else { return [] }
        let found = markdownExtensions.compactMap { UTType(filenameExtension: $0) }
            .filter { !$0.isDynamic && ($0.conforms(to: common) || $0.identifier.lowercased().contains("markdown")) }
        return Array(Set(found + [common]))
    }

    static var peroOpensMarkdown: Bool {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return markdownTypes.allSatisfy { NSWorkspace.shared.urlForApplication(toOpen: $0)?.resolvingSymlinksInPath() == app }
    }

    /// Makes Перо the app Finder opens Markdown files with.
    @MainActor
    static func openMarkdownInPero() async throws {
        for type in markdownTypes {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
        }
    }
}
