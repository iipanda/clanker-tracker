import Foundation

/// Edits one top-level member of a JSON object in place, leaving every other byte of the file
/// (formatting, key order, other settings) exactly as it was.
enum JSONText {
    struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    struct Object {
        let open: Int
        let close: Int
        let members: [Member]
    }

    enum EditError: Error { case notAnObject, invalidResult }

    static func value(of key: String, in text: String) -> String? {
        let b = Array(text.utf8)
        guard let obj = parse(b), let m = obj.members.last(where: { $0.key == key }) else { return nil }
        return String(decoding: b[m.valueStart..<m.valueEnd], as: UTF8.self)
    }

    /// Replaces the member's value, or inserts the member first in the object if it's missing.
    static func setting(_ key: String, to value: String, in text: String) throws -> String {
        let b = Array(text.utf8)
        guard let obj = parse(b) else { throw EditError.notAnObject }
        var out: [UInt8]
        if let m = obj.members.last(where: { $0.key == key }) {
            out = Array(b[..<m.valueStart]) + Array(value.utf8) + Array(b[m.valueEnd...])
        } else if let first = obj.members.first {
            // Match the indentation of the first member so removal restores the file exactly.
            var lineStart = first.keyStart
            while lineStart > obj.open + 1 && b[lineStart - 1] != 0x0A { lineStart -= 1 }
            let indent = b[lineStart - 1] == 0x0A ? Array(b[lineStart..<first.keyStart]) : []
            let separator: [UInt8] = indent.isEmpty && b[lineStart - 1] != 0x0A ? Array(", ".utf8) : Array(",\n".utf8) + indent
            out = Array(b[..<first.keyStart]) + Array("\(quoted(key)): \(value)".utf8) + separator + Array(b[first.keyStart...])
        } else {
            out = Array(b[...obj.open]) + Array("\n  \(quoted(key)): \(value)\n".utf8) + Array(b[obj.close...])
        }
        return try validated(out)
    }

    static func removing(_ key: String, in text: String) throws -> String {
        let b = Array(text.utf8)
        guard let obj = parse(b) else { throw EditError.notAnObject }
        guard let i = obj.members.lastIndex(where: { $0.key == key }) else { return text }
        let m = obj.members[i]
        let out: [UInt8]
        if i + 1 < obj.members.count {
            out = Array(b[..<m.keyStart]) + Array(b[obj.members[i + 1].keyStart...])
        } else if i > 0 {
            out = Array(b[..<obj.members[i - 1].valueEnd]) + Array(b[m.valueEnd...])
        } else {
            out = Array(b[...obj.open]) + Array(b[obj.close...])
        }
        return try validated(out)
    }

    private static func validated(_ bytes: [UInt8]) throws -> String {
        guard (try? JSONSerialization.jsonObject(with: Data(bytes))) is [String: Any] else { throw EditError.invalidResult }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func quoted(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\(s)\""
    }

    // MARK: Scanning

    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), colon = UInt8(ascii: ":"), comma = UInt8(ascii: ",")
    private static let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}"), openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
    private static let space: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09]

    static func parse(_ b: [UInt8]) -> Object? {
        var i = 0
        func skipSpace() { while i < b.count, space.contains(b[i]) { i += 1 } }
        skipSpace()
        guard i < b.count, b[i] == openBrace else { return nil }
        let open = i
        i += 1
        skipSpace()
        if i < b.count, b[i] == closeBrace { return Object(open: open, close: i, members: []) }

        var members: [Member] = []
        while i < b.count {
            skipSpace()
            guard i < b.count, b[i] == quote, let keyEnd = skipString(b, i),
                  let key = (try? JSONSerialization.jsonObject(with: Data(b[i..<keyEnd]), options: .fragmentsAllowed)) as? String
            else { return nil }
            let keyStart = i
            i = keyEnd
            skipSpace()
            guard i < b.count, b[i] == colon else { return nil }
            i += 1
            skipSpace()
            guard let valueEnd = skipValue(b, i) else { return nil }
            members.append(Member(key: key, keyStart: keyStart, valueStart: i, valueEnd: valueEnd))
            i = valueEnd
            skipSpace()
            guard i < b.count else { return nil }
            if b[i] == comma { i += 1; continue }
            if b[i] == closeBrace { return Object(open: open, close: i, members: members) }
            return nil
        }
        return nil
    }

    private static func skipString(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < b.count {
            if b[i] == backslash { i += 2; continue }
            if b[i] == quote { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func skipValue(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        switch b[start] {
        case quote:
            return skipString(b, start)
        case openBrace, openBracket:
            var depth = 0, i = start
            while i < b.count {
                let c = b[i]
                if c == quote {
                    guard let end = skipString(b, i) else { return nil }
                    i = end
                    continue
                }
                if c == openBrace || c == openBracket { depth += 1 }
                if c == closeBrace || c == closeBracket {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count, !space.contains(b[i]), ![comma, closeBrace, closeBracket].contains(b[i]) { i += 1 }
            return i > start ? i : nil
        }
    }
}
