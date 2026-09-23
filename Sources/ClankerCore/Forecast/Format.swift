import Foundation

public enum Fmt {
    /// "42 min", "1.6 h", "4.5 days"
    public static func duration(hours h: Double) -> String {
        if !h.isFinite { return "–" }
        if h < 1 { return "\(max(1, Int((h * 60).rounded()))) min" }
        if h < 24 { return String(format: "%.1f h", h) }
        return String(format: "%.1f days", h / 24)
    }

    /// "7:14 PM"
    public static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "Mon 4:58 PM"
    public static func dayClock(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "Wed, Sep 23, 09:52"
    public static func dateClock(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    /// Clock time for short windows, weekday and time for long ones.
    public static func when(_ d: Date, short: Bool) -> String { short ? clock(d) : dayClock(d) }

    /// "Mon"
    public static func weekday(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated)) }

    /// "Sep 16"
    public static func monthDay(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    public static func pct(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", v)
    }

    /// "%/h" rate with one decimal: "40.0"
    public static func rate(_ v: Double) -> String { String(format: v < 10 ? "%.2f" : "%.1f", v) }

    /// "just now", "41s ago", "3 min ago", "2 h ago", "3 days ago"
    public static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 48 * 3600 { return "\(s / 3600) h ago" }
        return "\(s / 86400) days ago"
    }

    /// "$4.72", "$1,240"
    public static func usd(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(v < 100 ? 2 : 0)))
    }

    /// "812", "12.3k", "345M", "1.2B"
    public static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: v < 10_000 ? "%.1fk" : "%.0fk", v / 1_000)
        case ..<1_000_000_000: return String(format: v < 10_000_000 ? "%.1fM" : "%.0fM", v / 1_000_000)
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

    /// "1:12" until a moment, for the menu bar when a limit is hit.
    public static func countdown(to d: Date, from now: Date) -> String {
        let m = max(0, Int(d.timeIntervalSince(now) / 60))
        return m >= 24 * 60 ? "\(m / 1440)d \(m % 1440 / 60)h" : String(format: "%d:%02d", m / 60, m % 60)
    }
}
