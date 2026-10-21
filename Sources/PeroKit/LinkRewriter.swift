import Foundation

/// Keeps relative links pointing at the same files when notes move, and wiki links
/// pointing at the same note when it is renamed.
public enum LinkRewriter {
    private static let markdownTarget = try! NSRegularExpression(pattern: #"(\]\(\s*)(<[^>\n]*>|[^)\s]+)"#)
    private static let htmlSource = try! NSRegularExpression(pattern: #"(\ssrc\s*=\s*")([^"]+)(")"#, options: [.caseInsensitive])
    private static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#)

    /// Library-relative path for a link target written in a note in `folder`, or nil
    /// for web links, anchors, absolute paths and paths leaving the library.
    public static func resolve(_ target: String, from folder: String) -> String? {
        var t = target.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<") && t.hasSuffix(">") { t = String(t.dropFirst().dropLast()) }
        if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("/") { return nil }
        if t.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil { return nil }
        t = t.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        t = t.removingPercentEncoding ?? t
        var parts = folder.isEmpty ? [] : folder.components(separatedBy: "/")
        for p in t.components(separatedBy: "/") {
            switch p {
            case "", ".": continue
            case "..":
                if parts.isEmpty { return nil }
                parts.removeLast()
            default: parts.append(p)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Relative target from a note in `folder` to the library-relative `path`.
    public static func relative(from folder: String, to path: String) -> String {
        let from = folder.isEmpty ? [] : folder.components(separatedBy: "/")
        let to = path.components(separatedBy: "/")
        var common = 0
        while common < from.count, common < to.count - 1, from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    /// Writes `path` as a link target: spaces and brackets need angle brackets.
    public static func target(_ path: String) -> String {
        path.rangeOfCharacter(from: CharacterSet(charactersIn: " ()<>")) == nil ? path : "<\(path)>"
    }

    /// The text with relative targets rebased from `oldFolder` to `newFolder`, or nil if
    /// nothing changed. Code blocks are left alone.
    /// `moving` gives the new place of targets that move along (a whole folder, several notes).
    public static func rebase(_ text: String, from oldFolder: String, to newFolder: String,
                              moving: (String) -> String? = { _ in nil }) -> String? {
        guard oldFolder != newFolder else { return nil }
        var changed = false
        var inFence: String?
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            let line = lines[i]
            let ns = line as NSString
            if let marker = inFence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(marker) { inFence = nil }
                continue
            }
            if let m = fence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                inFence = ns.substring(with: m.range(at: 1))
                continue
            }
            var edits: [(NSRange, String)] = []
            for regex in [markdownTarget, htmlSource] {
                for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let range = m.range(at: 2)
                    let original = ns.substring(with: range)
                    guard var resolved = resolve(original, from: oldFolder) else { continue }
                    if let moved = moving(resolved) { resolved = moved }
                    var suffix = ""
                    var bare = original
                    let wrapped = bare.hasPrefix("<") && bare.hasSuffix(">")
                    if wrapped { bare = String(bare.dropFirst().dropLast()) }
                    if let cut = bare.firstIndex(where: { $0 == "?" || $0 == "#" }) { suffix = String(bare[cut...]) }
                    var path = relative(from: newFolder, to: resolved)
                    if bare.contains("%") {
                        path = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                    }
                    var out = path + suffix
                    if regex === markdownTarget { out = wrapped ? "<\(out)>" : target(out) }
                    if out != original { edits.append((range, out)) }
                }
            }
            guard !edits.isEmpty else { continue }
            let mutable = NSMutableString(string: line)
            for (range, value) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                mutable.replaceCharacters(in: range, with: value)
            }
            lines[i] = mutable as String
            changed = true
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// `[[old]]`, `[[old|…]]` and `[[old#…]]` become `new`; nil if there were none.
    public static func renameWikiLinks(_ text: String, from old: String, to new: String) -> String? {
        guard !old.isEmpty, old != new else { return nil }
        let pattern = #"\[\[\s*"# + NSRegularExpression.escapedPattern(for: old) + #"\s*(?=\]\]|\||#)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard regex.firstMatch(in: text, range: range) != nil else { return nil }
        let replacement = NSRegularExpression.escapedTemplate(for: "[[" + new)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
