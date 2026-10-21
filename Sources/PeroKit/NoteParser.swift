import Foundation

/// What a note contains, for smart folders, the gallery and search.
public struct NoteFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let images = NoteFlags(rawValue: 1 << 0)
    public static let pdfs = NoteFlags(rawValue: 1 << 1)
    public static let documents = NoteFlags(rawValue: 1 << 2)
    public static let scans = NoteFlags(rawValue: 1 << 3)
    public static let sketches = NoteFlags(rawValue: 1 << 4)
    public static let audio = NoteFlags(rawValue: 1 << 5)
    public static let tables = NoteFlags(rawValue: 1 << 6)
    public static let code = NoteFlags(rawValue: 1 << 7)
    public static let links = NoteFlags(rawValue: 1 << 8)
    public static let checklists = NoteFlags(rawValue: 1 << 9)

    public static let anyAttachment: NoteFlags = [.images, .pdfs, .documents, .scans, .sketches, .audio]
}

public struct Heading: Hashable, Sendable {
    public var level: Int
    public var text: String
    public var offset: Int  // UTF-16, like the editor
}

public struct WikiLink: Hashable, Sendable {
    public var target: String
    public var section: String?
}

public struct ParsedNote: Sendable {
    public var title = ""
    public var preview = ""
    public var tags: [String] = []           // as first written, without "#"
    public var wikiLinks: [WikiLink] = []
    public var headings: [Heading] = []
    public var tasksTotal = 0
    public var tasksDone = 0
    public var flags: NoteFlags = []
    public var firstImage: String?           // as written in the note
    public var localTargets: [String] = []   // relative link and image targets, as written
    public var plainText = ""
    public var words = 0
}

public enum NoteParser {
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let fence = re(#"^ {0,3}(`{3,}|~{3,})"#)
    static let heading = re(#"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
    static let task = re(#"^[ \t>]*(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\](?:[ \t]|$)"#)
    static let tableSeparator = re(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    static let codeSpan = re(#"(`+)(?:(?!\1).)+?\1"#)
    static let image = re(#"!\[([^\]\n]*)\]\(\s*(<[^>\n]*>|[^)\s]+)(?:\s+"[^"]*")?\s*\)"#)
    static let link = re(#"(?<!!)\[([^\]\n]*)\]\(\s*(<[^>\n]*>|[^)\s]+)(?:\s+"[^"]*")?\s*\)"#)
    static let htmlImage = re(#"<img\s[^>]*?src\s*=\s*"([^"]+)"[^>]*>"#, [.caseInsensitive])
    static let wiki = re(#"\[\[([^\[\]|#\n]+)(?:#([^\[\]|\n]+))?(?:\|([^\[\]\n]+))?\]\]"#)
    static let url = re(#"(?:https?|ftp)://[^\s<>()]+|www\.[^\s<>()]+"#, [.caseInsensitive])
    static let tag = re(#"(?<![\p{L}\p{N}_#/&\-])#([\p{L}\p{N}_][\p{L}\p{N}_\-]*)"#)
    static let word = re(#"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#)
    static let lineMarkers = re(#"^[ \t]*(?:>[ \t]?)*(?:#{1,6}[ \t]+|(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?"#)
    static let htmlTag = re(#"</?[A-Za-z][^>\n]*>"#)
    static let emphasis = re(#"(\*\*|__|\*|_|~~|==)(?=\S)(.+?)(?<=\S)\1"#)

    public static func parse(_ text: String) -> ParsedNote {
        var note = ParsedNote()
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices where lines[i].hasSuffix("\r") { lines[i].removeLast() }

        var offset = 0
        var start = 0
        // Front matter: shown as properties, its tags count, never its text.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }), end < 200 {
            for line in lines[1..<end] {
                for t in frontMatterTags(line) { addTag(t, to: &note) }
            }
            for line in lines[0...end] { offset += (line as NSString).length + 1 }
            start = end + 1
        }

        var plain: [String] = []
        var fenceMarker: String?
        var previous = ""
        var previewParts: [String] = []
        var previewLength = 0

        for index in start..<lines.count {
            let line = lines[index]
            let ns = line as NSString
            let lineOffset = offset
            offset += ns.length + 1
            let whole = NSRange(location: 0, length: ns.length)

            if let marker = fenceMarker {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(marker) && trimmed.allSatisfy({ $0 == marker.first }) {
                    fenceMarker = nil
                } else {
                    plain.append(line)
                    if note.title.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty { note.title = clip(line.trimmingCharacters(in: .whitespaces), 200) }
                }
                previous = line
                continue
            }
            if let m = fence.firstMatch(in: line, range: whole) {
                fenceMarker = ns.substring(with: m.range(at: 1))
                note.flags.insert(.code)
                previous = line
                continue
            }

            if let m = heading.firstMatch(in: line, range: whole) {
                let level = m.range(at: 1).length
                let raw = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
                note.headings.append(Heading(level: level, text: plainInline(raw), offset: lineOffset))
            }
            if let m = task.firstMatch(in: line, range: whole) {
                note.tasksTotal += 1
                if ns.substring(with: m.range(at: 1)) != " " { note.tasksDone += 1 }
                note.flags.insert(.checklists)
            }
            if line.contains("|"), previous.contains("|"), tableSeparator.firstMatch(in: line, range: whole) != nil {
                note.flags.insert(.tables)
                previous = line
                continue
            }

            // A divider («---», «***») is not text.
            if line.range(of: #"^ {0,3}([-*_])( *\1){2,} *$"#, options: .regularExpression) != nil {
                previous = line
                continue
            }

            scanInline(line, into: &note)

            let text = plainLine(line)
            plain.append(text)
            if !text.isEmpty {
                if note.title.isEmpty {
                    note.title = clip(text, 200)
                } else if previewLength < 200 {
                    previewParts.append(text)
                    previewLength += text.count + 1
                }
            }
            previous = line
        }

        note.preview = clip(previewParts.joined(separator: " "), 200)
        note.plainText = plain.joined(separator: "\n")
        let plainNS = note.plainText as NSString
        note.words = word.numberOfMatches(in: note.plainText, range: NSRange(location: 0, length: plainNS.length))
        return note
    }

    // MARK: Inline

    private static func scanInline(_ line: String, into note: inout ParsedNote) {
        // Code spans hold no tags or links.
        var s = codeSpan.stringByReplacingMatches(in: line, range: full(line), withTemplate: " ")
        let ns = s as NSString

        for m in image.matches(in: s, range: full(s)) {
            let target = unwrap(ns.substring(with: m.range(at: 2)))
            if note.firstImage == nil { note.firstImage = target }
            addTarget(target, image: true, to: &note)
        }
        for m in htmlImage.matches(in: s, range: full(s)) {
            let target = ns.substring(with: m.range(at: 1))
            if note.firstImage == nil { note.firstImage = target }
            addTarget(target, image: true, to: &note)
        }
        for m in link.matches(in: s, range: full(s)) {
            addTarget(unwrap(ns.substring(with: m.range(at: 2))), image: false, to: &note)
        }
        for m in wiki.matches(in: s, range: full(s)) {
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let section = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            note.wikiLinks.append(WikiLink(target: target, section: section))
            note.flags.insert(.links)
        }
        if url.firstMatch(in: s, range: full(s)) != nil { note.flags.insert(.links) }

        // Tags: not inside link targets, URLs or wiki links.
        s = image.stringByReplacingMatches(in: s, range: full(s), withTemplate: " ")
        s = link.stringByReplacingMatches(in: s, range: full(s), withTemplate: "$1")
        s = wiki.stringByReplacingMatches(in: s, range: full(s), withTemplate: " ")
        s = url.stringByReplacingMatches(in: s, range: full(s), withTemplate: " ")
        s = htmlTag.stringByReplacingMatches(in: s, range: full(s), withTemplate: " ")
        let tagNS = s as NSString
        for m in tag.matches(in: s, range: full(s)) {
            var name = tagNS.substring(with: m.range(at: 1))
            while name.hasSuffix("-") || name.hasSuffix("_") { name.removeLast() }
            if name.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { addTag(name, to: &note) }
        }
    }

    private static func addTarget(_ raw: String, image: Bool, to note: inout ParsedNote) {
        var target = raw.trimmingCharacters(in: .whitespaces)
        // file:// links point at files on this Mac like absolute paths do.
        if target.lowercased().hasPrefix("file://"), let url = URL(string: target), url.isFileURL { target = url.path }
        if target.isEmpty || target.hasPrefix("#") { return }
        if target.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil {
            if !image { note.flags.insert(.links) }
            return
        }
        let path = (target.removingPercentEncoding ?? target).components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent
        note.localTargets.append(target)
        switch ext {
        case "md", "markdown", "mdown", "mkd", "mkdn", "":
            note.flags.insert(.links)
        case "svg":
            note.flags.insert(.sketches)
        case "pdf":
            note.flags.insert(name.hasPrefix("Скан") ? .scans : .pdfs)
        case "m4a", "mp3", "wav", "aac", "caf", "aiff", "aif":
            note.flags.insert(.audio)
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp":
            note.flags.insert(name.hasPrefix("Скан") ? .scans : .images)
        default:
            note.flags.insert(image ? .images : .documents)
        }
    }

    private static func addTag(_ name: String, to note: inout ParsedNote) {
        let key = name.lowercased()
        if !note.tags.contains(where: { $0.lowercased() == key }) { note.tags.append(name) }
    }

    private static func frontMatterTags(_ line: String) -> [String] {
        // "tags: [a, b]", "tags: a, b" or a "- a" item under tags.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("tags:") {
            let value = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            return value.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #\"'")) }.filter { !$0.isEmpty }
        }
        return []
    }

    // MARK: Plain text

    /// One line without Markdown: markers, emphasis, link targets and HTML tags removed.
    public static func plainLine(_ line: String) -> String {
        var s = line
        s = lineMarkers.stringByReplacingMatches(in: s, range: full(s), withTemplate: "")
        return plainInline(s)
    }

    public static func plainInline(_ text: String) -> String {
        var s = text
        s = image.stringByReplacingMatches(in: s, range: full(s), withTemplate: "$1")
        s = link.stringByReplacingMatches(in: s, range: full(s), withTemplate: "$1")
        // A wiki link with its own text shows that text, otherwise its target.
        s = s.replacingOccurrences(of: #"\[\[[^\[\]|]+\|([^\[\]]+)\]\]"#, with: "$1", options: .regularExpression)
        s = wiki.stringByReplacingMatches(in: s, range: full(s), withTemplate: "$1")
        s = htmlTag.stringByReplacingMatches(in: s, range: full(s), withTemplate: "")
        s = codeSpan.stringByReplacingMatches(in: s, range: full(s), withTemplate: "$0")
            .replacingOccurrences(of: "`", with: "")
        for _ in 0..<2 { s = emphasis.stringByReplacingMatches(in: s, range: full(s), withTemplate: "$2") }
        s = s.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!|~=<>])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\|\s*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Helpers

    private static func full(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    private static func unwrap(_ target: String) -> String {
        target.hasPrefix("<") && target.hasSuffix(">") ? String(target.dropFirst().dropLast()) : target
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) : s
    }
}
