import Foundation
import JavaScriptCore
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look for Markdown files: the space bar in Finder shows the note formatted,
/// with Перо's renderer (markdown-it) running in JavaScriptCore.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? ""
        let folder = request.fileURL.deletingLastPathComponent()
        var html = Self.render(text, title: request.fileURL.deletingPathExtension().lastPathComponent)
        // Pictures next to the file, when the sandbox lets the extension read them.
        var attachments: [String: QLPreviewReplyAttachment] = [:]
        let regex = try NSRegularExpression(pattern: #"(<img\s[^>]*?src=")([^"]+)(")"#, options: [.caseInsensitive])
        let ns = html as NSString
        for (i, m) in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).enumerated().reversed() {
            let src = ns.substring(with: m.range(at: 2))
            guard !src.contains("://"), !src.hasPrefix("data:"),
                  let path = src.removingPercentEncoding,
                  let image = try? Data(contentsOf: folder.appendingPathComponent(path)),
                  let range = Range(m.range(at: 2), in: html) else { continue }
            let type = UTType(filenameExtension: (path as NSString).pathExtension) ?? .image
            attachments["img\(i)"] = QLPreviewReplyAttachment(data: image, contentType: type)
            html.replaceSubrange(range, with: "cid:img\(i)")
        }
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { _ in Data(html.utf8) }
        reply.attachments = attachments
        reply.stringEncoding = .utf8
        return reply
    }

    static func render(_ markdown: String, title: String) -> String {
        guard let url = Bundle(for: PreviewProvider.self).url(forResource: "render", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return "<pre>" + escape(markdown) + "</pre>" }
        context.evaluateScript(script)
        let render = context.objectForKeyedSubscript("PeroRender")?.objectForKeyedSubscript("page")
        return render?.call(withArguments: [markdown, title]).toString() ?? "<pre>" + escape(markdown) + "</pre>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
