import Foundation

/// Every limit window seen for both tools. Merging is idempotent, so re-reading the same logs changes nothing.
public struct UsageHistory: Codable, Sendable, Equatable {
    /// Readings whose reset times differ by less than this belong to the same window.
    public static let resetTolerance: TimeInterval = 15 * 60
    /// A window kind (e.g. Codex 5-hour) is shown only if it was seen this recently.
    public static let activeWithin: TimeInterval = 8 * 24 * 3600

    public var schemaVersion = 1
    public var windows: [LimitWindow] = []
    /// Plan names by tool raw value ("pro").
    public var plans: [String: String] = [:]
    /// Last time a source confirmed its data is current without a new reading.
    public var heartbeats: [String: Date] = [:]

    public init() {}

    public mutating func add(_ s: Sample) {
        // A reading can't predate its own window or come after it reset; the few that do are log noise.
        let start = s.resetsAt.addingTimeInterval(-TimeInterval(s.minutes) * 60)
        guard s.reading.t >= start.addingTimeInterval(-3600),
              s.reading.t <= s.resetsAt.addingTimeInterval(Self.resetTolerance)
        else { return }
        if let i = windows.firstIndex(where: {
            $0.tool == s.tool && $0.minutes == s.minutes && $0.scope == s.scope
                && abs($0.resetsAt.timeIntervalSince(s.resetsAt)) <= Self.resetTolerance
        }) {
            windows[i].insert(s.reading)
        } else {
            windows.append(LimitWindow(tool: s.tool, minutes: s.minutes, resetsAt: s.resetsAt, points: [s.reading], scope: s.scope))
        }
    }

    public mutating func add(contentsOf samples: some Sequence<Sample>) {
        for s in samples { add(s) }
    }

    public mutating func heartbeat(_ tool: Tool, at date: Date) {
        heartbeats[tool.rawValue] = max(heartbeats[tool.rawValue] ?? .distantPast, date)
    }

    public mutating func setPlan(_ plan: String?, for tool: Tool) {
        guard let plan, !plan.isEmpty else { return }
        plans[tool.rawValue] = plan
    }

    public mutating func prune(before date: Date) {
        windows.removeAll { $0.resetsAt < date }
    }

    public func windows(for tool: Tool) -> [LimitWindow] {
        windows.filter { $0.tool == tool }.sorted { $0.resetsAt < $1.resetsAt }
    }

    public func lastSeen(_ tool: Tool) -> Date? {
        let seen = windows.filter { $0.tool == tool }.map(\.lastSeen) + [heartbeats[tool.rawValue]].compactMap { $0 }
        return seen.max()
    }

    public func plan(for tool: Tool) -> String? { plans[tool.rawValue] }

    /// When a window actually ended: its reset time, or earlier if a later window of the same kind
    /// took over after its last reading (the provider reset it early). Windows that keep getting
    /// readings side by side overlap rather than replace each other, so they keep their reset time.
    public func effectiveEnd(of w: LimitWindow) -> Date {
        let last = w.points.last?.t ?? w.start
        let takeover = windows
            .filter { $0.tool == w.tool && $0.minutes == w.minutes && $0.scope == w.scope && $0.resetsAt > w.resetsAt.addingTimeInterval(Self.resetTolerance) }
            .compactMap { $0.points.first?.t }
            .filter { $0 >= last }
            .min()
        guard let takeover, takeover < w.resetsAt else { return w.resetsAt }
        return takeover
    }

    /// Windows of one kind that have ended by `now`, oldest end first, each with when it actually
    /// ended (see `effectiveEnd(of:)`).
    public func endedWindows(tool: Tool, minutes: Int, scope: String?, now: Date) -> [EndedWindow] {
        let kind = windows.filter { $0.tool == tool && $0.minutes == minutes && $0.scope == scope }.sorted { $0.resetsAt < $1.resetsAt }
        var out: [EndedWindow] = []
        for (i, w) in kind.enumerated() {
            // Same rule as `effectiveEnd(of:)`, looking only at the windows that can take over: a
            // window starting (readings allow an hour early) after this one's reset can't end it early.
            let last = w.points.last?.t ?? w.start
            var end = w.resetsAt
            var j = i + 1
            while j < kind.count, kind[j].start.addingTimeInterval(-3600) < w.resetsAt {
                if kind[j].resetsAt > w.resetsAt.addingTimeInterval(Self.resetTolerance), let first = kind[j].points.first?.t, first >= last {
                    end = min(end, first)
                }
                j += 1
            }
            if end <= now { out.append(EndedWindow(window: w, end: end)) }
        }
        return out.sorted { $0.end < $1.end }
    }

    /// A kind of limit: its length, and its scope for limits on part of the usage (e.g. Fable).
    public struct Kind: Hashable, Sendable, Comparable {
        public let minutes: Int
        public let scope: String?

        public static func < (a: Kind, b: Kind) -> Bool { (a.minutes, a.scope ?? "") < (b.minutes, b.scope ?? "") }
    }

    /// The limit kinds a tool has used recently, shortest first, main limits before scoped ones.
    public func kinds(for tool: Tool, now: Date) -> [Kind] {
        Set(windows.filter { $0.tool == tool && now.timeIntervalSince($0.lastSeen) <= Self.activeWithin }
            .map { Kind(minutes: $0.minutes, scope: $0.scope) }).sorted()
    }

    /// The current window of each limit kind the tool has used recently, shortest window first.
    /// "Current" is the window that got the latest reading: Codex windows can overlap after early resets.
    public func currentForecasts(for tool: Tool, now: Date) -> [Forecast] {
        kinds(for: tool, now: now).compactMap { kind in
            guard let w = current(tool: tool, kind: kind) else { return nil }
            // The status line heartbeat vouches for the main limits only.
            return Forecast(w, end: effectiveEnd(of: w), heartbeat: kind.scope == nil ? heartbeats[tool.rawValue] : nil, now: now,
                            past: pastSeries(tool: tool, minutes: kind.minutes, scope: kind.scope, before: now))
        }
    }

    /// The window of a kind that got the latest reading (estimated readings count).
    public func current(tool: Tool, kind: Kind) -> LimitWindow? {
        windows.filter { $0.tool == tool && $0.minutes == kind.minutes && $0.scope == kind.scope }
            .max { ($0.points.last?.t ?? $0.lastSeen, $0.resetsAt) < ($1.points.last?.t ?? $1.lastSeen, $1.resetsAt) }
    }

    /// Recent finished windows of one kind as usage series, for learning usual hours.
    public func pastSeries(tool: Tool, minutes: Int, scope: String? = nil, before now: Date, within: TimeInterval = 8 * 7 * 86400) -> [WindowSeries] {
        windows(for: tool)
            .filter { $0.minutes == minutes && $0.scope == scope && $0.points.count >= 3 && $0.resetsAt > now.addingTimeInterval(-within - TimeInterval(minutes) * 60) }
            .map { (w: $0, end: effectiveEnd(of: $0)) }
            .filter { $0.end <= now }
            .map { WindowSeries($0.w, end: $0.end) }
    }

    public func currentForecasts(now: Date) -> [Forecast] {
        Tool.allCases.flatMap { currentForecasts(for: $0, now: now) }
    }
}
