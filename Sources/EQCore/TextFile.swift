import Foundation

enum TextFile {
    /// Reads a text file exported by EQ and measurement tools. Most are UTF-8, but REW writes
    /// ISO-8859-1 (Latin-1) and some Windows tools write UTF-16, so fall back to those.
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        // Every byte sequence is valid Latin-1, so this always succeeds.
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
