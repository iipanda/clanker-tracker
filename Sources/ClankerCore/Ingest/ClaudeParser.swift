import Foundation

/// Reads Claude Code limits. Claude Code only reports them to its status line command, so a small
/// block in the user's status line script (see `StatusLineHook`) appends each change to `history.jsonl`:
/// `{"ts":1790000000,"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1790010000},"seven_day":{...}}}`
public enum ClaudeParser {
    public static let needle = Array(#""rate_limits""#.utf8)
    static let windows: [(key: String, minutes: Int)] = [("five_hour", 300), ("seven_day", 10080)]

    public static func parse(historyLine line: UnsafeRawBufferPointer) -> [Sample] {
        parse(historyLine: Data(line))
    }

    public static func parse(historyLine data: Data) -> [Sample] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = number(obj["ts"]),
              let limits = obj["rate_limits"] as? [String: Any]
        else { return [] }
        return samples(rateLimits: limits, at: Date(timeIntervalSince1970: ts), percentKey: "used_percentage")
    }

    public static func scan(_ buf: UnsafeRawBufferPointer, into samples: inout [Sample]) -> Int {
        var out: [Sample] = []
        let used = LineScanner.scan(buf, needle: needle) { out += parse(historyLine: $0) }
        samples += out
        return used
    }

    /// `cachedUsageUtilization` in `~/.claude.json`: the last usage response Claude Code fetched (often stale).
    public static func bootstrap(claudeJSON data: Data) -> (samples: [Sample], fetchedAt: Date)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let ms = number(cached["fetchedAtMs"]),
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }
        let at = Date(timeIntervalSince1970: ms / 1000)
        return (samples(rateLimits: utilization, at: at, percentKey: "utilization"), at)
    }

    static func samples(rateLimits: [String: Any], at t: Date, percentKey: String) -> [Sample] {
        windows.compactMap { key, minutes in
            guard let w = rateLimits[key] as? [String: Any],
                  let pct = number(w[percentKey]),
                  let resetsAt = date(w["resets_at"]),
                  resetsAt > t.addingTimeInterval(-60)
            else { return nil }
            return Sample(tool: .claude, minutes: minutes, resetsAt: resetsAt, reading: Reading(t: t, pct: pct))
        }
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func date(_ v: Any?) -> Date? {
        if let n = number(v) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let s = v as? String { return ISOTime.parse(s) }
        return nil
    }
}
