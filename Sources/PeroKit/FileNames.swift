import Foundation

public enum FileNames {
    /// The name of a note without a title; the app sets it in the interface language.
    public static var untitled = "Новая заметка"

    /// File name (without extension) for a note title: «/» and «:» become «-», no leading
    /// dots, at most ~200 bytes so a « 99» suffix and the extension still fit in 255.
    public static func baseName(forTitle title: String) -> String {
        var s = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        while s.utf8.count > 200 { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? untitled : s
    }

    /// `base.ext` in `dir`, or `base 2.ext`, `base 3.ext`… if taken.
    public static func unique(_ base: String, ext: String, in dir: URL, allowing existing: URL? = nil) -> URL {
        let fm = FileManager.default
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? dir.appendingPathComponent(name) : dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var n = 1
        while true {
            let url = candidate(n)
            if let existing, url.standardizedFileURL.path == existing.standardizedFileURL.path { return url }
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// True if `name` is `base` or `base N` (a numbered duplicate of it).
    public static func matches(_ name: String, base: String) -> Bool {
        if name == base { return true }
        guard name.hasPrefix(base + " ") else { return false }
        return Int(name.dropFirst(base.count + 1)) != nil
    }

    /// Characters safe in a Markdown link target without escaping.
    public static func attachmentName(_ original: String) -> String {
        let ext = (original as NSString).pathExtension
        var stem = (original as NSString).deletingPathExtension
        stem = String(stem.unicodeScalars.map { s -> Character in
            CharacterSet.alphanumerics.contains(s) || s == "." || s == "_" || s == "-" ? Character(s) : "-"
        })
        while stem.contains("--") { stem = stem.replacingOccurrences(of: "--", with: "-") }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if stem.isEmpty { stem = "file" }
        if stem.utf8.count > 120 { stem = String(stem.prefix(60)) }
        return ext.isEmpty ? stem : stem + "." + ext.lowercased()
    }
}
