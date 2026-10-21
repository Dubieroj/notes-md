import Foundation

/// How a text file was stored, so saving writes it back exactly as it was read.
public struct TextFormat: Equatable, Sendable {
    public var encoding: String.Encoding = .utf8
    public var hasBOM = false
    public var crlf = false

    public init() {}
}

public enum TextCodec {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// UTF-8 (with or without BOM) or Windows-1251. Pure Windows line endings become \n
    /// and come back on save; mixed files are passed through as is.
    public static func decode(_ data: Data) throws -> (text: String, format: TextFormat) {
        var format = TextFormat()
        format.hasBOM = data.starts(with: bom)
        let body = format.hasBOM ? data.dropFirst(bom.count) : data[...]
        var string: String
        if let s = String(data: body, encoding: .utf8) {
            string = s
        } else if let s = String(data: body, encoding: .windowsCP1251) {
            string = s
            format.encoding = .windowsCP1251
        } else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let crlfCount = string.components(separatedBy: "\r\n").count - 1
        let lfCount = string.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        format.crlf = crlfCount > 0 && crlfCount == lfCount
        if format.crlf { string = string.replacingOccurrences(of: "\r\n", with: "\n") }
        return (string, format)
    }

    public static func encode(_ text: String, _ format: TextFormat) throws -> Data {
        let out = format.crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        guard var data = out.data(using: format.encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if format.hasBOM { data.insert(contentsOf: bom, at: 0) }
        return data
    }
}

public enum SafeWrite {
    /// Writes through a temporary file and swaps it in, so a crash never leaves half a
    /// file, and the original's creation date and permissions survive the save.
    public static func write(_ data: Data, to link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: dir) }
        let temp = dir.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temp)
        _ = try fm.replaceItemAt(url, withItemAt: temp)
    }
}
