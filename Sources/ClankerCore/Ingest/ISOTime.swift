import Foundation

/// Fast ISO-8601 parsing for log timestamps ("2026-09-23T16:33:55.729Z", "2026-09-19T08:20:00.963880+00:00").
/// Runs millions of times during a backfill, so it avoids formatters.
public enum ISOTime {
    public static func parse(_ s: String) -> Date? {
        var s = s
        return s.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    public static func parse(_ b: UnsafeRawBufferPointer) -> Date? {
        guard b.count >= 19 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<from + len {
                let c = b[i]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = num(0, 4), b[4] == 45, let mo = num(5, 2), b[7] == 45, let d = num(8, 2),
              b[10] == 84 || b[10] == 32, let h = num(11, 2), b[13] == 58, let mi = num(14, 2), b[16] == 58,
              let sec = num(17, 2), (1...12).contains(mo), (1...31).contains(d)
        else { return nil }

        var i = 19
        var frac = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                frac += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < b.count, b[i] == 43 || b[i] == 45, i + 6 <= b.count, let oh = num(i + 1, 2), let om = num(i + 4, 2) {
            offset = (oh * 3600 + om * 60) * (b[i] == 43 ? 1 : -1)
        }

        let days = daysFromCivil(y, mo, d)
        let seconds = Double(days * 86400 + h * 3600 + mi * 60 + sec - offset) + frac
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
