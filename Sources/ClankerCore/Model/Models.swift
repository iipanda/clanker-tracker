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
    /// Estimated from token usage rather than reported (see `ScopedEstimate`); never saved.
    public var estimated: Bool?

    public init(t: Date, pct: Double, estimated: Bool? = nil) {
        self.t = t
        self.pct = pct
        self.estimated = estimated
    }

    public var isEstimated: Bool { estimated == true }
}

/// A reading as produced by an ingestor, before it's grouped into a window.
public struct Sample: Sendable, Hashable {
    public var tool: Tool
    public var minutes: Int
    public var resetsAt: Date
    public var reading: Reading
    /// A limit for part of the tool's usage, e.g. "fable" for Claude's Fable weekly limit; nil for the
    /// tool's main limits.
    public var scope: String?

    public init(tool: Tool, minutes: Int, resetsAt: Date, reading: Reading, scope: String? = nil) {
        self.tool = tool
        self.minutes = minutes
        self.resetsAt = resetsAt
        self.reading = reading
        self.scope = scope
    }
}

/// One instance of a rate-limit window (e.g. the weekly Codex window that resets Monday 4:58 PM).
public struct LimitWindow: Codable, Sendable, Hashable, Identifiable {
    public var tool: Tool
    public var minutes: Int
    public var resetsAt: Date
    /// Sorted by time. Runs of equal values keep only their first and last reading.
    public var points: [Reading]
    /// Time of the latest reported (not estimated) reading.
    public var lastSeen: Date
    /// See `Sample.scope`.
    public var scope: String?

    public init(tool: Tool, minutes: Int, resetsAt: Date, points: [Reading] = [], lastSeen: Date? = nil, scope: String? = nil) {
        self.tool = tool
        self.minutes = minutes
        self.resetsAt = resetsAt
        self.points = []
        self.lastSeen = lastSeen ?? .distantPast
        self.scope = scope
        for p in points { insert(p) }
    }

    public var id: String {
        "\(tool.rawValue).\(scope.map { "\($0)." } ?? "")\(minutes).\(Int(resetsAt.timeIntervalSince1970))"
    }

    /// Identifies the kind of limit (length and scope), e.g. "10080" or "10080.fable".
    public var kindKey: String { "\(minutes)" + (scope.map { ".\($0)" } ?? "") }
    /// "Fable" for a scoped limit.
    public var scopeName: String? { scope.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
    /// The latest reading that was reported rather than estimated.
    public var lastReported: Reading? { points.last { !$0.isEstimated } }
    public var isEstimated: Bool { points.last?.isEstimated ?? false }
    public var duration: TimeInterval { TimeInterval(minutes) * 60 }
    public var start: Date { resetsAt.addingTimeInterval(-duration) }
    public var peak: Double { points.map(\.pct).max() ?? 0 }
    /// Windows of a day or less forecast from the last hour; longer ones from the last six.
    public var isShort: Bool { minutes <= 24 * 60 }

    /// "5-hour", "Weekly", "Fable weekly"
    public var label: String {
        if let scopeName { return "\(scopeName) \(baseLabel.lowercased())" }
        return baseLabel
    }

    var baseLabel: String {
        if minutes == 7 * 24 * 60 { return "Weekly" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    /// For sentences: "5-hour", "weekly", "Fable weekly"
    public var sentenceLabel: String { scope == nil && minutes == 7 * 24 * 60 ? "weekly" : label }

    /// "5h", "7d", "Fable"
    public var shortLabel: String {
        if let scopeName { return scopeName }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    public mutating func insert(_ r: Reading) {
        guard r.pct.isFinite else { return }
        if !r.isEstimated { lastSeen = max(lastSeen, r.t) }
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
