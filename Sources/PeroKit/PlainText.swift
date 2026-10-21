import Foundation

/// Markdown → plain text for «Экспортировать как ▸ Текст»: no markup, lists keep
/// bullets, checklists get boxes, tables become tab-separated lines.
public enum PlainText {
    private static let task = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\][ \t]*"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+"#)
    private static let number = try! NSRegularExpression(pattern: #"^([ \t]*)(\d+[.)])[ \t]+"#)
    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}#{1,6}[ \t]+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)+"#)
    private static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#)
    private static let separator = try! NSRegularExpression(pattern: #"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    private static let link = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\(\s*<?([^)>\s]+)>?(?:\s+"[^"]*")?\s*\)"#)

    public static func from(_ markdown: String) -> String {
        var out: [String] = []
        var fenceMarker: String?
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let marker = fenceMarker {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(marker) { fenceMarker = nil } else { out.append(line) }
                continue
            }
            if let m = fence.firstMatch(in: line, range: range) { fenceMarker = ns.substring(with: m.range(at: 1)); continue }
            if line.contains("|"), separator.firstMatch(in: line, range: range) != nil { continue }
            if line.trimmingCharacters(in: .whitespaces).range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                out.append("————————")
                continue
            }
            var prefix = ""
            var rest = line
            if let m = task.firstMatch(in: line, range: range) {
                prefix = ns.substring(with: m.range(at: 1)) + (ns.substring(with: m.range(at: 2)) == " " ? "☐ " : "☑ ")
                rest = ns.substring(from: m.range.upperBound)
            } else if let m = bullet.firstMatch(in: line, range: range) {
                prefix = ns.substring(with: m.range(at: 1)) + (ns.substring(with: m.range(at: 2)) == "+" ? "– " : "• ")
                rest = ns.substring(from: m.range.upperBound)
            } else if let m = number.firstMatch(in: line, range: range) {
                prefix = ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + " "
                rest = ns.substring(from: m.range.upperBound)
            } else if let m = heading.firstMatch(in: line, range: range) {
                rest = ns.substring(from: m.range.upperBound).replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
            } else if let m = quote.firstMatch(in: line, range: range) {
                rest = ns.substring(from: m.range.upperBound)
            }
            if rest.contains("|"), rest.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                let cells = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { NoteParser.plainInline($0.trimmingCharacters(in: .whitespaces)) }
                out.append(prefix + cells.joined(separator: "\t"))
                continue
            }
            // Links keep their address: «текст (адрес)».
            let restNS = rest as NSString
            rest = link.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: restNS.length), withTemplate: "$1 ($2)")
            rest = rest.replacingOccurrences(of: #"\\$"#, with: "", options: .regularExpression)
            out.append(prefix + NoteParser.plainInline(rest))
        }
        return out.joined(separator: "\n")
    }
}
