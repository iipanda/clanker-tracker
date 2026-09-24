import Foundation

/// Spend periods that follow a tool's weekly limit: one per weekly window, ending early where the
/// provider reset the window before its time (Codex early and banked resets, the odd Claude reset).
public enum WeeklyPeriods {
    static let week: TimeInterval = 7 * 86400

    /// The `count` most recent periods, oldest first, ending with the one containing `now`; nil when
    /// the tool has no weekly windows yet. Stretches without a window (no readings) and the time before
    /// the first one are filled with week-long periods.
    public static func recent(_ history: UsageHistory, tool: Tool, now: Date, count: Int) -> [DateInterval]? {
        var windows: [(start: Date, end: Date)] = []
        for w in history.windows(for: tool) where w.minutes == 7 * 24 * 60 && w.scope == nil && w.start <= now {
            // Readings of one window can disagree on its reset time by a few minutes.
            if let last = windows.last, w.start.timeIntervalSince(last.start) <= UsageHistory.resetTolerance { continue }
            windows.append((w.start, w.resetsAt))
        }
        guard !windows.isEmpty else { return nil }

        var out: [DateInterval] = []
        // Unused time too short for a period of its own (a reset, then the next window a bit later),
        // added to the next window.
        var carried: Date?
        for (i, w) in windows.enumerated() {
            let next = i + 1 < windows.count ? windows[i + 1].start : nil
            // A window reset early ends where the next one starts.
            var t = next.map { min($0, w.end) } ?? w.end
            out.append(DateInterval(start: carried ?? w.start, end: t))
            carried = nil
            if let next {
                while next.timeIntervalSince(t) >= 86400 {
                    let end = min(next, t.addingTimeInterval(week))
                    out.append(DateInterval(start: t, end: end))
                    t = end
                }
                if t < next { carried = t }
            } else {
                // Reset with no reading since: assume the next window started right away.
                while t <= now {
                    out.append(DateInterval(start: t, duration: week))
                    t = t.addingTimeInterval(week)
                }
            }
        }
        while out.count < count, let first = out.first {
            out.insert(DateInterval(start: first.start.addingTimeInterval(-week), end: first.start), at: 0)
        }
        return Array(out.suffix(count))
    }
}
