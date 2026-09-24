import Foundation

/// Keeps a scoped limit (e.g. Claude's Fable weekly limit) current between reported readings, which
/// only arrive when Claude Code refreshes its usage cache or the opt-in usage check runs.
///
/// Each reported reading pairs a percentage with the API-equivalent cost of that scope's models so far
/// in the window, which gives "percent of the limit per dollar". From the last reported reading on,
/// the estimate adds that rate times the scope's usage since. (This holds for a single model family;
/// the shared weekly limit counts models differently, so it isn't estimated this way.)
public enum ScopedEstimate {
    /// Readings need at least this much usage and percentage to calibrate from.
    static let minCost = 5.0
    static let minPercent = 3.0

    /// How much of a scoped limit a dollar of API-equivalent usage takes.
    public struct Calibration: Sendable, Equatable {
        public var percentPerDollar: Double
        /// The rate in earlier windows, when the latest reading shows it has changed (Anthropic adjusts
        /// limits from time to time).
        public var earlier: Double?
    }

    /// From the latest reported reading of each of the last few windows: their median, or the latest
    /// alone when it differs from the earlier ones by more than 1.5×.
    public static func calibration(history: UsageHistory, spend: SpendLedger, prices: PriceTable,
                                   tool: Tool, scope: String, now: Date) -> Calibration? {
        let entries = scopedEntries(spend, tool: tool, scope: scope)
        var samples: [(t: Date, k: Double, pct: Double)] = []
        for w in history.windows(for: tool) where w.scope == scope {
            for r in w.points.reversed() where !r.isEstimated && r.pct >= minPercent && r.t <= now {
                let c = cost(entries, prices: prices, from: w.start, to: r.t)
                if c >= minCost {
                    samples.append((r.t, r.pct / c, r.pct))
                    break
                }
            }
        }
        let recent = samples.sorted { $0.t > $1.t }.prefix(4)
        guard let latest = recent.first else { return nil }
        if recent.count > 1, latest.pct >= 10 {
            let earlier = median(recent.dropFirst().map(\.k))
            if max(latest.k / earlier, earlier / latest.k) > 1.5 {
                return Calibration(percentPerDollar: latest.k, earlier: earlier)
            }
        }
        return Calibration(percentPerDollar: median(recent.map(\.k)))
    }

    static func median(_ values: [Double]) -> Double {
        let v = values.sorted()
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// A copy of `history` where each scoped limit's current window continues past its last reported
    /// reading with estimated readings, hour by hour up to `now`. After a reset it opens the next
    /// window, ending with the tool's main weekly limit (they reset together).
    public static func apply(to history: UsageHistory, spend: SpendLedger, prices: PriceTable, now: Date) -> UsageHistory {
        var out = history
        let scoped = Set(history.windows.compactMap { w in w.scope.map { (w.tool, $0, w.minutes) } }.map(Key.init))
        for key in scoped {
            guard let k = calibration(history: history, spend: spend, prices: prices, tool: key.tool, scope: key.scope, now: now)?.percentPerDollar,
                  var window = history.current(tool: key.tool, kind: .init(minutes: key.minutes, scope: key.scope))
            else { continue }
            var base = window.lastReported.map { ($0.t, $0.pct) } ?? (window.start, 0)
            if window.resetsAt <= now {
                // The last window reset: continue in the next one, which ends with the main weekly window.
                guard let main = history.current(tool: key.tool, kind: .init(minutes: key.minutes, scope: nil)),
                      main.resetsAt > now, main.resetsAt > window.resetsAt
                else { continue }
                window = LimitWindow(tool: key.tool, minutes: key.minutes, resetsAt: main.resetsAt, scope: key.scope)
                base = (max(window.start, history.current(tool: key.tool, kind: .init(minutes: key.minutes, scope: key.scope))?.resetsAt ?? window.start), 0)
            }
            let entries = scopedEntries(spend, tool: key.tool, scope: key.scope)
            var points: [Reading] = []
            var t = base.0
            while t < now {
                let next = min(now, Date(timeIntervalSince1970: ((t.timeIntervalSince1970 / 3600).rounded(.down) + 1) * 3600))
                let pct = min(100, base.1 + k * cost(entries, prices: prices, from: base.0, to: next))
                if pct > (points.last?.pct ?? base.1) + 0.05 { points.append(Reading(t: next, pct: pct, estimated: true)) }
                t = next
            }
            guard !points.isEmpty else { continue }
            if let i = out.windows.firstIndex(where: { $0.id == window.id }) {
                for p in points { out.windows[i].insert(p) }
            } else {
                for p in points { window.insert(p) }
                out.windows.append(window)
            }
        }
        return out
    }

    struct Key: Hashable {
        let tool: Tool
        let scope: String
        let minutes: Int
        init(_ t: (Tool, String, Int)) { (tool, scope, minutes) = t }
    }

    /// Ledger entries of the scope's models ("fable" → claude-fable-5, claude-fable-5-1, …).
    static func scopedEntries(_ spend: SpendLedger, tool: Tool, scope: String) -> [SpendLedger.Entry] {
        spend.entries.filter { $0.tool == tool && $0.model.lowercased().contains(scope) }
    }

    /// API-equivalent cost of the entries in [from, to), with partial hours counted proportionally.
    static func cost(_ entries: [SpendLedger.Entry], prices: PriceTable, from: Date, to: Date) -> Double {
        guard to > from else { return 0 }
        var total = 0.0
        for e in entries {
            let start = e.start, end = e.start.addingTimeInterval(3600)
            let overlap = min(end, to).timeIntervalSince(max(start, from))
            guard overlap > 0, let price = prices.price(for: e.model) else { continue }
            total += price.cost(e.tokens, context: e.context) * (e.fast ? 2 : 1) * overlap / 3600
        }
        return total
    }
}
