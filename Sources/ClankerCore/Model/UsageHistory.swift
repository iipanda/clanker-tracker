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
            $0.tool == s.tool && $0.minutes == s.minutes
                && abs($0.resetsAt.timeIntervalSince(s.resetsAt)) <= Self.resetTolerance
        }) {
            windows[i].insert(s.reading)
        } else {
            windows.append(LimitWindow(tool: s.tool, minutes: s.minutes, resetsAt: s.resetsAt, points: [s.reading]))
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
            .filter { $0.tool == w.tool && $0.minutes == w.minutes && $0.resetsAt > w.resetsAt.addingTimeInterval(Self.resetTolerance) }
            .compactMap { $0.points.first?.t }
            .filter { $0 >= last }
            .min()
        guard let takeover, takeover < w.resetsAt else { return w.resetsAt }
        return takeover
    }

    /// The current window of each limit kind the tool has used recently, shortest window first.
    /// "Current" is the window that got the latest reading: Codex windows can overlap after early resets.
    public func currentForecasts(for tool: Tool, now: Date) -> [Forecast] {
        let ws = windows.filter { $0.tool == tool }
        let kinds = Set(ws.filter { now.timeIntervalSince($0.lastSeen) <= Self.activeWithin }.map(\.minutes)).sorted()
        return kinds.compactMap { minutes in
            guard let w = ws.filter({ $0.minutes == minutes }).max(by: { ($0.lastSeen, $0.resetsAt) < ($1.lastSeen, $1.resetsAt) })
            else { return nil }
            return Forecast(w, end: effectiveEnd(of: w), heartbeat: heartbeats[tool.rawValue], now: now)
        }
    }

    public func currentForecasts(now: Date) -> [Forecast] {
        Tool.allCases.flatMap { currentForecasts(for: $0, now: now) }
    }
}
