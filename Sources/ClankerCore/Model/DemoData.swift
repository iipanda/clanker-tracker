import Foundation

/// The sample data from design/index.html, for `--demo` and tests.
public enum DemoData {
    struct Spec {
        let tool: Tool
        let minutes: Int
        let elapsedHours: Double
        let keys: [(Double, Double)]
    }

    static let specs: [Spec] = [
        Spec(tool: .claude, minutes: 300, elapsedHours: 3.4,
             keys: [(0, 0), (0.5, 8), (1.2, 15), (1.8, 22), (2.4, 32), (3.0, 56), (3.4, 72)]),
        Spec(tool: .claude, minutes: 10080, elapsedHours: 100.8,
             keys: [(0, 0), (3, 4), (9, 9), (14, 9), (27, 14), (33, 19), (38, 19), (51, 24), (57, 29), (62, 29), (75, 31), (81, 35), (86, 35), (99, 38), (100.8, 41)]),
        Spec(tool: .codex, minutes: 10080, elapsedHours: 60,
             keys: [(0, 0), (4, 4), (10, 8), (14, 8), (26, 13), (33, 20), (38, 20), (50, 26), (53, 33), (54, 34), (60, 35.5)]),
    ]

    static let pastPeaks: [Tool: [Double]] = [
        .claude: [62, 88, 100, 74, 55, 93, 100],
        .codex: [30, 45, 38, 70, 52, 61, 48],
    ]

    /// Twelve weeks of plausible hourly usage for both tools, busier on weekdays and in the afternoon.
    public static func spend(now: Date) -> SpendLedger {
        var ledger = SpendLedger()
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -84, to: cal.startOfDay(for: now)) ?? now
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var t = start
        while t < now {
            let hour = cal.component(.hour, from: t), weekday = cal.component(.weekday, from: t)
            let busy = (9...19).contains(hour) ? 1.0 : 0.15
            let weekdayFactor = (2...6).contains(weekday) ? 1.0 : 0.35
            let growth = 0.6 + 0.8 * t.timeIntervalSince(start) / now.timeIntervalSince(start)
            for (tool, model, scale) in [(Tool.claude, "claude-opus-5", 1.0), (.claude, "claude-fable-5-1", 0.35), (.codex, "gpt-5.6-sol", 1.4), (.codex, "gpt-6-astra", 0.3)] {
                guard next() < busy * weekdayFactor else { continue }
                let k = scale * growth * (0.5 + next())
                let tokens = TokenCounts(input: Int(40_000 * k), cacheWrite5m: tool == .claude ? Int(180_000 * k) : 0,
                                         cacheRead: Int(2_600_000 * k), output: Int(30_000 * k))
                ledger.add(UsageEvent(tool: tool, model: model, t: t, tokens: tokens, dedupeKey: 0))
            }
            t = t.addingTimeInterval(3600)
        }
        return ledger
    }

    public static func history(now: Date) -> UsageHistory {
        var h = UsageHistory()
        for s in specs {
            let start = now.addingTimeInterval(-s.elapsedHours * 3600)
            let resetsAt = start.addingTimeInterval(TimeInterval(s.minutes) * 60)
            for (hours, pct) in s.keys where hours > 0 {
                h.add(Sample(tool: s.tool, minutes: s.minutes, resetsAt: resetsAt,
                             reading: Reading(t: start.addingTimeInterval(hours * 3600), pct: pct)))
            }
            if s.minutes == 10080, let peaks = pastPeaks[s.tool] {
                // Past weeks: working hours on weekdays, growing to each week's peak.
                let cal = Calendar.current
                for (i, peak) in peaks.enumerated() {
                    let reset = resetsAt.addingTimeInterval(-Double(peaks.count - i) * 7 * 86400)
                    let begin = reset.addingTimeInterval(-7 * 86400)
                    let hours = (0..<(7 * 24)).map { begin.addingTimeInterval(Double($0) * 3600) }
                    let active = hours.filter { (10...18).contains(cal.component(.hour, from: $0)) && !cal.isDateInWeekend($0) }
                    for (k, t) in active.enumerated() where k % 2 == 1 || k == active.count - 1 {
                        h.add(Sample(tool: s.tool, minutes: 10080, resetsAt: reset,
                                     reading: Reading(t: t, pct: (peak * Double(k + 1) / Double(active.count)).rounded())))
                    }
                }
            }
        }
        h.setPlan("pro", for: .codex)
        h.heartbeat(.claude, at: now.addingTimeInterval(-38))
        h.heartbeat(.codex, at: now.addingTimeInterval(-38))
        return h
    }
}
