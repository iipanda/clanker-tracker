import Foundation

public struct NotificationPrefs: Sendable, Equatable {
    public var runout: Bool
    /// Percent to notify at, or nil when off.
    public var threshold: Double?
    public var reset: Bool
    /// "Runs out if you keep this pace" for spikes on 5-hour limits.
    public var spikes: Bool

    public init(runout: Bool, threshold: Double?, reset: Bool, spikes: Bool = true) {
        self.runout = runout
        self.threshold = threshold
        self.reset = reset
        self.spikes = spikes
    }
}

public struct PlannedNotification: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
}

/// Decides which notifications to send. Each condition fires at most once per window, tracked in a
/// ledger of keys mapped to the window's end so old entries can be pruned. Spike alerts are the
/// exception: they re-arm when the spike calms down.
public enum NotificationPlanner {
    /// Readings older than this are not acted on (the numbers may already be out of date).
    public static let freshness: TimeInterval = 10 * 60

    /// With `deliver == false` conditions are only recorded, so the first launch doesn't replay old alerts.
    public static func plan(
        _ forecasts: [Forecast], prefs: NotificationPrefs, ledger: inout [String: Date], now: Date, deliver: Bool
    ) -> [PlannedNotification] {
        ledger = ledger.filter { $0.value > now.addingTimeInterval(-8 * 24 * 3600) }
        var out: [PlannedNotification] = []

        func fire(_ key: String, _ f: Forecast, _ title: String, _ body: String) {
            let id = "\(f.window.id).\(key)"
            guard ledger[id] == nil else { return }
            ledger[id] = f.end
            if deliver { out.append(PlannedNotification(id: id, title: title, body: body)) }
        }

        for f in forecasts {
            let name = f.tool.displayName, kind = f.window.sentenceLabel, short = f.window.isShort
            let fresh = now.timeIntervalSince(f.lastUpdate) <= freshness

            if f.isReset {
                if prefs.reset, now.timeIntervalSince(f.end) <= freshness, f.window.peak > 0 {
                    fire("reset", f, "\(name) \(kind) limit has reset", "You're back to 0%. It peaked at \(Fmt.pct(min(100, f.window.peak))).")
                }
                continue
            }
            // A spike alert re-arms once the spike calms down (going quiet counts), so a later spike can
            // alert again.
            let spikeID = "\(f.window.id).spike"
            if ledger[spikeID] != nil, f.spikeCalm { ledger[spikeID] = nil }
            guard fresh else { continue }

            if prefs.spikes, let runout = f.spikeRunoutDate, let pace = f.spikePace {
                fire("spike", f,
                     "\(name) \(kind) limit runs out at \(Fmt.clock(runout)) if you keep this pace",
                     "You're at \(Fmt.pct(f.used)), using about \(Fmt.pct(pace)) an hour over the last 30 minutes. It resets at \(Fmt.when(f.end, short: short)).")
            }

            if prefs.runout, let runout = f.runoutDate {
                fire("runout", f,
                     "\(name) \(kind) limit runs out around \(Fmt.clock(runout))",
                     "You're at \(Fmt.pct(f.used)) and using about \(Fmt.pct(f.pace)) an hour. It resets at \(Fmt.when(f.end, short: short)).")
            }
            if let t = prefs.threshold, f.used >= t {
                let tail = f.isHit ? "It resets at \(Fmt.when(f.end, short: short))." :
                    "At this pace you'll be near \(Fmt.pct(f.projected)) when it resets at \(Fmt.when(f.end, short: short))."
                fire("threshold\(Int(t))", f, "\(name) \(kind) limit is at \(Fmt.pct(f.used))", tail)
            }
        }
        return out
    }
}
