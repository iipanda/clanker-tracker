import Foundation

/// Where a limit window stands and where it's heading at the current pace.
/// Ported from `stats()` in design/index.html.
public struct Forecast: Sendable, Identifiable, Equatable {
    public let window: LimitWindow
    public let now: Date
    public let start: Date
    public let end: Date
    /// Usage curve for display: (start, 0) followed by readings, never decreasing.
    public let curve: [Reading]

    public let used: Double
    /// Percent per hour over the lookback.
    public let pace: Double
    /// Percent per hour that would land exactly on 100% at the reset.
    public let sustainable: Double
    /// Hours until 100% at the current pace; infinity when idle.
    public let runoutHours: Double
    public let runsOut: Bool
    public let projected: Double
    /// Where an even pace from 0% to 100% would be right now.
    public let even: Double
    public let lookbackHours: Double
    public let elapsedHours: Double
    public let leftHours: Double
    public let isReset: Bool
    public let isHit: Bool
    public let lastSeen: Date
    public let isStale: Bool

    public var id: String { window.id }
    public var tool: Tool { window.tool }
    public var runoutDate: Date? { runsOut ? now.addingTimeInterval(runoutHours * 3600) : nil }
    public var ratio: Double { sustainable > 0 ? pace / sustainable : .infinity }

    /// Pace is unreliable in the first minutes of a window, so no warnings before this.
    public static let warmup: TimeInterval = 10 * 60
    public static let hitThreshold = 99.5

    public init(_ w: LimitWindow, end: Date? = nil, heartbeat: Date? = nil, now: Date) {
        window = w
        self.now = now
        start = w.start
        self.end = end ?? w.resetsAt

        var curve = [Reading(t: w.start, pct: 0)]
        var peak = 0.0
        for p in w.points {
            peak = max(peak, p.pct)
            curve.append(Reading(t: max(p.t, w.start), pct: peak))
        }
        self.curve = curve

        let durationH = w.duration / 3600
        isReset = now >= self.end
        elapsedHours = min(durationH, max(0, now.timeIntervalSince(w.start) / 3600))
        leftHours = max(0, self.end.timeIntervalSince(now) / 3600)
        lookbackHours = w.isShort ? 1 : 6

        let current = Self.interpolate(curve, at: now)
        used = isReset ? 0 : current
        let span = min(lookbackHours, elapsedHours)
        pace = (isReset || span <= 0) ? 0 : max(0, current - Self.interpolate(curve, at: now.addingTimeInterval(-span * 3600))) / span
        sustainable = leftHours > 0 ? max(0, 100 - used) / leftHours : 0
        runoutHours = pace > 0 ? max(0, 100 - used) / pace : .infinity
        isHit = !isReset && used >= Self.hitThreshold
        runsOut = !isReset && !isHit && elapsedHours * 3600 >= Self.warmup && runoutHours < leftHours
        projected = min(100, used + pace * leftHours)
        even = min(100, elapsedHours / durationH * 100)

        lastSeen = max(w.lastSeen, heartbeat ?? .distantPast)
        let staleAfter: TimeInterval = w.isShort ? 30 * 60 : 6 * 3600
        isStale = !isReset && now.timeIntervalSince(lastSeen) > staleAfter
    }

    /// Recorded usage at a time within the window (flat after the last reading).
    public func value(at t: Date) -> Double { Self.interpolate(curve, at: t) }

    /// Recorded usage up to now, projected at the current pace after.
    public func estimate(at t: Date) -> Double {
        t <= now ? value(at: t) : min(100, used + pace * t.timeIntervalSince(now) / 3600)
    }

    static func interpolate(_ curve: [Reading], at t: Date) -> Double {
        guard let first = curve.first else { return 0 }
        if t <= first.t { return first.pct }
        for i in 1..<curve.count where t <= curve[i].t {
            let a = curve[i - 1], b = curve[i]
            let span = b.t.timeIntervalSince(a.t)
            return span > 0 ? a.pct + (b.pct - a.pct) * t.timeIntervalSince(a.t) / span : b.pct
        }
        return curve[curve.count - 1].pct
    }
}

public enum Tightest {
    /// The limit closest to running out: a hit limit first, then the soonest projected run-out, else the fullest.
    public static func pick(_ forecasts: [Forecast]) -> Forecast? {
        let live = forecasts.filter { !$0.isReset }
        if let hit = live.filter(\.isHit).min(by: { $0.end < $1.end }) { return hit }
        if let out = live.filter(\.runsOut).min(by: { $0.runoutHours < $1.runoutHours }) { return out }
        return live.max(by: { $0.used < $1.used }) ?? forecasts.first
    }
}

public struct WeekBar: Sendable, Identifiable, Equatable {
    public let id: String
    public let start: Date
    /// When the window actually ended (Codex often resets weekly windows early).
    public let end: Date
    public let peak: Double
    public let isCurrent: Bool
}

public enum PastWeeks {
    /// Peak usage of the most recent weekly windows, oldest first, ending with the current one.
    public static func bars(_ history: UsageHistory, tool: Tool, now: Date, count: Int = 8) -> [WeekBar] {
        let weekly = history.windows(for: tool).filter { $0.minutes == 7 * 24 * 60 }
        let current = history.currentForecasts(for: tool, now: now).first { $0.window.minutes == 7 * 24 * 60 && !$0.isReset }?.window.id
        let ended = weekly.filter { $0.id != current }
            .map { (w: $0, end: history.effectiveEnd(of: $0)) }
            .filter { $0.end <= now }
            .sorted { $0.end < $1.end }
            .suffix(current == nil ? count : count - 1)
            .map { WeekBar(id: $0.w.id, start: $0.w.start, end: $0.end, peak: min(100, $0.w.peak), isCurrent: false) }
        guard let current, let w = weekly.first(where: { $0.id == current }) else { return Array(ended) }
        return ended + [WeekBar(id: w.id, start: w.start, end: w.resetsAt, peak: min(100, w.peak), isCurrent: true)]
    }
}
