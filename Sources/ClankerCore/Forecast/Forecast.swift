import Foundation

/// Where a limit window stands and where it's heading. The projection comes from an estimator that
/// learns your usual hours from past windows and lets a recent burst fade into them (see
/// `Estimators.chosen`, picked by backtesting past Codex windows); `pace` is what you actually used
/// over the last hour (5-hour windows) or 6 hours (weekly).
public struct Forecast: Sendable, Identifiable, Equatable {
    public let window: LimitWindow
    public let now: Date
    public let start: Date
    public let end: Date
    /// Usage curve for display: (start, 0) followed by readings, never decreasing.
    public let curve: [Reading]
    /// Predicted usage from now until the reset.
    public let projection: Projection

    public let used: Double
    /// Percent per hour actually used over the lookback.
    public let pace: Double
    /// Percent per hour that would land exactly on 100% at the reset.
    public let sustainable: Double
    /// Hours until the projection reaches 100%; infinity when it doesn't before the reset.
    public let runoutHours: Double
    public let runsOut: Bool
    /// Predicted usage at the reset.
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
    /// How many past windows the projection learned your usual hours from.
    public let learnedFrom: Int
    /// 5-hour windows: percent per hour over the last 30 minutes, to catch spikes the forecast
    /// expects to fade.
    public let spikePace: Double?
    /// When the limit would run out if the last 30 minutes' pace kept up, when the forecast itself
    /// doesn't expect a run-out ("runs out at 15:40 if you keep this pace").
    public let spikeRunoutDate: Date?
    /// The spike has calmed down: the recent pace is back well under what the limit can sustain.
    public var spikeCalm: Bool { (spikePace ?? 0) < sustainable * 0.8 }
    /// The earliest run-out to warn about: the forecast's, or a spike's.
    public var alertRunout: Date? { runoutDate ?? spikeRunoutDate }

    /// How far back a spike is measured, for 5-hour windows.
    public static let spikeLookback: TimeInterval = 30 * 60

    public var id: String { window.id }
    public var tool: Tool { window.tool }
    public var runoutDate: Date? { runsOut ? now.addingTimeInterval(runoutHours * 3600) : nil }
    public var ratio: Double { sustainable > 0 ? pace / sustainable : .infinity }

    /// Pace is unreliable in the first minutes of a window, so no warnings before this.
    public static let warmup: TimeInterval = 10 * 60
    public static let hitThreshold = 99.5

    /// - Parameter past: earlier windows of the same tool and length, for learning usual hours.
    public init(_ w: LimitWindow, end: Date? = nil, heartbeat: Date? = nil, now: Date,
                past: [WindowSeries] = [], estimator: (any UsageEstimator)? = nil) {
        window = w
        self.now = now
        start = w.start
        self.end = end ?? w.resetsAt
        curve = Self.curve(w)
        learnedFrom = past.count

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
        isHit = !isReset && used >= Self.hitThreshold

        if isReset {
            projection = Projection(now: now, used: 0, step: 3600, increments: [0])
        } else {
            let input = EstimationInput(window: w, now: now, past: past)
            projection = (estimator ?? Estimators.chosen(minutes: w.minutes)).project(input)
        }
        let runout = isReset || isHit ? nil : projection.runout(before: self.end)
        runoutHours = runout.map { max(0, $0.timeIntervalSince(now) / 3600) } ?? .infinity
        runsOut = runout != nil && elapsedHours * 3600 >= Self.warmup
        projected = isReset ? 0 : projection.value(at: self.end)
        if w.isShort && !isReset {
            let input = EstimationInput(window: w, now: now, past: [])
            let spike = LinearPace(lookback: Self.spikeLookback)
            spikePace = LinearPace.pace(input, lookback: Self.spikeLookback)
            spikeRunoutDate = runsOut || isHit || elapsedHours * 3600 < Self.warmup ? nil : spike.project(input).runout(before: self.end)
        } else {
            spikePace = nil
            spikeRunoutDate = nil
        }
        even = min(100, elapsedHours / durationH * 100)

        lastSeen = max(w.lastSeen, heartbeat ?? .distantPast)
        let staleAfter: TimeInterval = w.isShort ? 30 * 60 : 6 * 3600
        isStale = !isReset && now.timeIntervalSince(lastSeen) > staleAfter
    }

    /// Recorded usage at a time within the window (flat after the last reading).
    public func value(at t: Date) -> Double { Self.interpolate(curve, at: t) }

    /// Recorded usage up to now, projected after.
    public func estimate(at t: Date) -> Double {
        t <= now ? value(at: t) : projection.value(at: t)
    }

    /// The projection as points from now until it reaches 100% or the window ends, for charts.
    public func projectionPoints(maxPoints: Int = 200) -> [Reading] {
        let stop = runoutDate.map { min($0, end) } ?? end
        guard stop > now else { return [Reading(t: now, pct: used)] }
        let n = max(1, min(maxPoints, Int(stop.timeIntervalSince(now) / projection.step)))
        return (0...n).map { i in
            let t = now.addingTimeInterval(stop.timeIntervalSince(now) * Double(i) / Double(n))
            return Reading(t: t, pct: projection.value(at: t))
        }
    }

    /// (start, 0) followed by the readings, never decreasing.
    static func curve(_ w: LimitWindow) -> [Reading] {
        var curve = [Reading(t: w.start, pct: 0)]
        var peak = 0.0
        for p in w.points {
            peak = max(peak, p.pct)
            curve.append(Reading(t: max(p.t, w.start), pct: peak))
        }
        return curve
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
        if let out = live.filter({ $0.alertRunout != nil }).min(by: { $0.alertRunout! < $1.alertRunout! }) { return out }
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
