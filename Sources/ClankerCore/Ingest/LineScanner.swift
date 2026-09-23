import Foundation

public enum LineScanner {
    /// Calls `line` for every complete (newline-terminated) line containing `needle`.
    /// Returns the number of bytes consumed: everything up to and including the last newline,
    /// so a partially written last line is read again next time.
    @discardableResult
    public static func scan(_ buf: UnsafeRawBufferPointer, needle: [UInt8], line: (UnsafeRawBufferPointer) -> Void) -> Int {
        guard let base = buf.baseAddress, !buf.isEmpty, !needle.isEmpty else { return 0 }
        var limit = buf.count
        while limit > 0 && buf[limit - 1] != 0x0A { limit -= 1 }
        guard limit > 0 else { return 0 }

        needle.withUnsafeBytes { n in
            var pos = 0
            while pos < limit, let hit = memmem(base + pos, limit - pos, n.baseAddress, n.count) {
                let m = base.distance(to: UnsafeRawPointer(hit))
                var s = m
                while s > pos && buf[s - 1] != 0x0A { s -= 1 }
                var e = m
                while e < limit && buf[e] != 0x0A { e += 1 }
                line(UnsafeRawBufferPointer(rebasing: buf[s..<e]))
                pos = e + 1
            }
        }
        return limit
    }
}

public struct FileCursor: Codable, Sendable, Hashable {
    public var inode: UInt64
    public var offset: Int64

    public init(inode: UInt64, offset: Int64) {
        self.inode = inode
        self.offset = offset
    }
}

public enum FileTail {
    /// Reads bytes appended since `cursor` and hands them to `consume`, which returns how many bytes it used.
    /// Starts over when the file was replaced (new inode) or truncated. Returns nil if the file can't be read.
    public static func read(path: String, cursor: FileCursor?, consume: (UnsafeRawBufferPointer) -> Int) -> FileCursor? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let inode = UInt64(st.st_ino)
        let size = Int64(st.st_size)
        var offset = cursor?.inode == inode ? cursor!.offset : 0
        if size < offset { offset = 0 }
        if size == offset { return FileCursor(inode: inode, offset: offset) }

        let data: Data
        if offset == 0 {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
            data = d
        } else {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            guard (try? h.seek(toOffset: UInt64(offset))) != nil,
                  let d = try? h.read(upToCount: Int(size - offset)) else { return nil }
            data = d
        }
        let used = data.withUnsafeBytes { consume($0) }
        return FileCursor(inode: inode, offset: offset + Int64(used))
    }
}
