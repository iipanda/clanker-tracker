import Foundation

public enum Tool: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One observed usage value: percent of a limit used at a moment.
public struct Reading: Codable, Sendable, Hashable {
    public var t: Date
    public var pct: Double

    public init(t: Date, pct: Double) {
        self.t = t
        self.pct = pct
    }
}

/// A reading as produced by an ingestor, before it's grouped into a window.
public struct Sample: Sendable, Hashable {
    public var tool: Tool
    public var minutes: Int
    public var resetsAt: Date
    public var reading: Reading

    public init(tool: Tool, minutes: Int, resetsAt: Date, reading: Reading) {
        self.tool = tool
        self.minutes = minutes
        self.resetsAt = resetsAt
        self.reading = reading
    }
}

/// One instance of a rate-limit window (e.g. the weekly Codex window that resets Monday 4:58 PM).
public struct LimitWindow: Codable, Sendable, Hashable, Identifiable {
    public var tool: Tool
    public var minutes: Int
    public var resetsAt: Date
    /// Sorted by time. Runs of equal values keep only their first and last reading.
    public var points: [Reading]
    public var lastSeen: Date

    public init(tool: Tool, minutes: Int, resetsAt: Date, points: [Reading] = [], lastSeen: Date? = nil) {
        self.tool = tool
        self.minutes = minutes
        self.resetsAt = resetsAt
        self.points = []
        self.lastSeen = lastSeen ?? .distantPast
        for p in points { insert(p) }
    }

    public var id: String { "\(tool.rawValue).\(minutes).\(Int(resetsAt.timeIntervalSince1970))" }
    public var duration: TimeInterval { TimeInterval(minutes) * 60 }
    public var start: Date { resetsAt.addingTimeInterval(-duration) }
    public var peak: Double { points.map(\.pct).max() ?? 0 }
    /// Windows of a day or less forecast from the last hour; longer ones from the last six.
    public var isShort: Bool { minutes <= 24 * 60 }

    /// "5-hour", "Weekly"
    public var label: String {
        if minutes == 7 * 24 * 60 { return "Weekly" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    /// For sentences: "5-hour", "weekly"
    public var sentenceLabel: String { minutes == 7 * 24 * 60 ? "weekly" : label }

    /// "5h", "7d"
    public var shortLabel: String {
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    public mutating func insert(_ r: Reading) {
        guard r.pct.isFinite else { return }
        lastSeen = max(lastSeen, r.t)
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t < r.t { lo = mid + 1 } else { hi = mid }
        }
        if lo < points.count, points[lo].t == r.t {
            points[lo].pct = max(points[lo].pct, r.pct)
        } else {
            points.insert(r, at: lo)
        }
        // Only the neighbours of the new point can have become the middle of an equal run.
        for j in [lo + 1, lo, lo - 1] where j > 0 && j < points.count - 1 {
            if points[j - 1].pct == points[j].pct && points[j].pct == points[j + 1].pct {
                points.remove(at: j)
            }
        }
    }
}
