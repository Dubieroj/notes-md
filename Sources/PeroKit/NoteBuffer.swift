import Foundation

/// The text of an open note. The editor page sends every edit here as it happens,
/// so the buffer always holds the current text and saving never waits for the page.
public final class NoteBuffer {
    // UTF-16 based, like JavaScript strings: editor positions apply directly.
    private let storage = NSMutableString()
    public var format: TextFormat

    public init(text: String = "", format: TextFormat = TextFormat()) {
        storage.setString(text)
        self.format = format
    }

    public convenience init(data: Data) throws {
        let decoded = try TextCodec.decode(data)
        self.init(text: decoded.text, format: decoded.format)
    }

    public var text: String { storage as String }
    public var length: Int { storage.length }

    public func setText(_ text: String) { storage.setString(text) }

    /// Applies edits from the page: [position, deleted length, inserted text], in order.
    /// Returns false if the copies went out of step (the caller then resyncs).
    public func applyEdits(_ changes: [[Any]], expectedLength: Int?) -> Bool {
        for change in changes {
            guard change.count == 3, let from = change[0] as? Int, let length = change[1] as? Int,
                  let insert = change[2] as? String, from >= 0, length >= 0, from + length <= storage.length
            else { return false }
            storage.replaceCharacters(in: NSRange(location: from, length: length), with: insert)
        }
        return expectedLength.map { $0 == storage.length } ?? true
    }

    /// The bytes to write. Text that the file's encoding cannot hold (an emoji in a
    /// Windows-1251 note) switches the note to UTF-8 rather than failing every save.
    public func data() throws -> Data {
        if let data = try? TextCodec.encode(text, format) { return data }
        format.encoding = .utf8
        return try TextCodec.encode(text, format)
    }
}
