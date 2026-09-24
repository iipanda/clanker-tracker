import Foundation

/// A window's usage growth per fixed step (an hour for weekly windows, five minutes for short ones),
/// with each step's local hour of the week, for learning when someone usually works.
public struct WindowSeries: Sendable {
    public let start: Date
    public let step: TimeInterval
    /// Percentage points added in each step.
    public let increments: [Double]
    /// Local hour of the week (0 = Sunday 00:00) of step 0; later steps follow on from it.
    public let startHourOfWeek: Int

    /// Builds the series from a window's readings, up to `end`. A reading that follows a gap (usage
    /// that happened elsewhere, or while nothing was recording) is spread over up to `spread` before it,
    /// rather than landing in a single step.
    public init(_ w: LimitWindow, end: Date, spread: TimeInterval? = nil) {
        start = w.start
        step = w.isShort ? 300 : 3600
        let spread = spread ?? (w.isShort ? 1800 : 3 * 3600)
        let n = max(0, Int((end.timeIntervalSince(w.start) / step).rounded(.down)))
        var out = [Double](repeating: 0, count: n)
        var level = 0.0, previous = w.start
        for p in w.points where p.t <= w.start.addingTimeInterval(Double(n) * step) {
            let jump = p.pct - level
            guard jump > 0 else { continue }
            // Spread the jump evenly over [from, p.t], split across the steps it covers.
            let from = max(previous, p.t.addingTimeInterval(-spread), w.start)
            let length = p.t.timeIntervalSince(from)
            if length <= 0 {
                out[min(n - 1, max(0, Int(p.t.timeIntervalSince(w.start) / step)))] += jump
            } else {
                var t = from
                while t < p.t {
                    let s = min(n - 1, Int(t.timeIntervalSince(w.start) / step))
                    let stepEnd = min(p.t, w.start.addingTimeInterval(Double(s + 1) * step))
                    out[s] += jump * stepEnd.timeIntervalSince(t) / length
                    t = stepEnd > t ? stepEnd : p.t
                }
            }
            level = p.pct
            previous = p.t
        }
        increments = out
        let c = Calendar.current.dateComponents([.weekday, .hour], from: w.start)
        startHourOfWeek = ((c.weekday ?? 1) - 1) * 24 + (c.hour ?? 0)
    }

    public func hourOfWeek(step s: Int) -> Int {
        (startHourOfWeek + Int(Double(s) * step / 3600)) % 168
    }
}

/// Everything an estimator may use when predicting a window's usage at `now`: nothing after it.
public struct EstimationInput: Sendable {
    /// The current window, with only the readings up to `now`.
    public let window: LimitWindow
    public let now: Date
    /// Earlier windows of the same tool and length, already over by `now`.
    public let past: [WindowSeries]
    /// The current window so far.
    public let current: WindowSeries

    public init(window: LimitWindow, now: Date, past: [WindowSeries]) {
        self.window = window
        self.now = now
        self.past = past
        current = WindowSeries(window, end: now)
    }

    public var start: Date { window.start }
    public var end: Date { window.resetsAt }
    /// Usage at `now` (the last reading, never decreasing).
    public var used: Double { Self.value(window.points, at: now) }

    /// Recorded usage at `t`: the highest reading at or before it (0 before the first).
    public static func value(_ points: [Reading], at t: Date) -> Double {
        var v = 0.0
        for p in points {
            if p.t > t { break }
            v = max(v, p.pct)
        }
        return v
    }
}

/// Predicted usage from `now` on: usage now plus predicted growth per step, capped at 100%.
public struct Projection: Sendable, Equatable {
    public let now: Date
    public let used: Double
    public let step: TimeInterval
    /// Percentage points added in each successive step after `now`; the last value repeats.
    public let increments: [Double]

    public init(now: Date, used: Double, step: TimeInterval, increments: [Double]) {
        self.now = now
        self.used = used
        self.step = step
        self.increments = increments
    }

    public func value(at t: Date) -> Double {
        guard t > now, !increments.isEmpty else { return used }
        let steps = t.timeIntervalSince(now) / step
        let whole = Int(steps)
        var total = used
        for i in 0..<whole {
            total += increments[min(i, increments.count - 1)]
            if total >= 100 { return 100 }
        }
        total += increments[min(whole, increments.count - 1)] * (steps - Double(whole))
        return min(100, total)
    }

    /// When usage would reach 100%, if it does before `end`.
    public func runout(before end: Date) -> Date? {
        guard used < 100 else { return now }
        var total = used, t = now
        var i = 0
        while t < end {
            let inc = increments[min(i, increments.count - 1)]
            if inc > 0, total + inc >= 100 {
                let hit = t.addingTimeInterval(step * (100 - total) / inc)
                return hit < end ? hit : nil
            }
            if i >= increments.count && inc <= 0 { return nil }
            total += inc
            t = t.addingTimeInterval(step)
            i += 1
        }
        return nil
    }
}

public protocol UsageEstimator: Sendable {
    var name: String { get }
    func project(_ input: EstimationInput) -> Projection
}

extension UsageEstimator {
    func step(_ input: EstimationInput) -> TimeInterval { input.current.step }
    func stepsToEnd(_ input: EstimationInput) -> Int {
        max(1, Int((input.end.timeIntervalSince(input.now) / step(input)).rounded(.up)))
    }
}

// MARK: - Estimators

/// Today's algorithm: the average pace over a fixed lookback, kept up until the reset.
/// (Interpolates between readings, like `Forecast`.)
public struct LinearPace: UsageEstimator {
    public let lookback: TimeInterval
    public var name: String { "Linear pace, last \(Estimators.duration(lookback))" }

    public init(lookback: TimeInterval) { self.lookback = lookback }

    public func project(_ input: EstimationInput) -> Projection {
        let s = step(input)
        return Projection(now: input.now, used: input.used, step: s, increments: [Self.pace(input, lookback: lookback) * s / 3600])
    }

    /// Percent per hour over the lookback, on the interpolated curve.
    static func pace(_ input: EstimationInput, lookback: TimeInterval) -> Double {
        let curve = Forecast.curve(input.window)
        let span = min(lookback, input.now.timeIntervalSince(input.start))
        guard span > 0 else { return 0 }
        let now = Forecast.interpolate(curve, at: input.now)
        return max(0, now - Forecast.interpolate(curve, at: input.now.addingTimeInterval(-span))) / (span / 3600)
    }
}

/// An exponentially weighted average of the window's growth so far: recent hours count most, idle
/// hours count as zero.
public struct WeightedPace: UsageEstimator {
    public let halfLife: TimeInterval
    public var name: String { "Weighted pace, half-life \(Estimators.duration(halfLife))" }

    public init(halfLife: TimeInterval) { self.halfLife = halfLife }

    public func project(_ input: EstimationInput) -> Projection {
        let s = step(input)
        return Projection(now: input.now, used: input.used, step: s, increments: [Self.rate(input.current, halfLife: halfLife) * s / 3600])
    }

    /// Percent per hour.
    static func rate(_ series: WindowSeries, halfLife: TimeInterval) -> Double {
        let incs = series.increments
        guard !incs.isEmpty else { return 0 }
        let decay = pow(0.5, series.step / halfLife)
        var w = 1.0, sum = 0.0, weights = 0.0
        for inc in incs.reversed() {
            sum += inc * w
            weights += w
            w *= decay
        }
        return sum / weights / (series.step / 3600)
    }
}

/// A recent burst fades into the window's longer-run pace: the rate `Δ` after now is
/// `base + (recent − base)·e^(−Δ/τ)`.
public struct FadingPace: UsageEstimator {
    public let recent: TimeInterval
    public let baseHalfLife: TimeInterval
    public let fade: TimeInterval
    public var name: String { "Fading: \(Estimators.duration(recent)) → hl \(Estimators.duration(baseHalfLife)), τ \(Estimators.duration(fade))" }

    public init(recent: TimeInterval, baseHalfLife: TimeInterval, fade: TimeInterval) {
        self.recent = recent
        self.baseHalfLife = baseHalfLife
        self.fade = fade
    }

    public func project(_ input: EstimationInput) -> Projection {
        let s = step(input)
        let r = LinearPace.pace(input, lookback: recent)
        let base = WeightedPace.rate(input.current, halfLife: baseHalfLife)
        let incs = (0..<stepsToEnd(input)).map { i -> Double in
            let dt = (Double(i) + 0.5) * s
            return max(0, base + (r - base) * exp(-dt / fade)) * s / 3600
        }
        return Projection(now: input.now, used: input.used, step: s, increments: incs)
    }
}

/// Learns when you usually work from past windows (hour of the day, or of the week), scales it by how
/// busy this window has been compared with usual, and lets a recent burst fade into that pattern.
public struct LearnedPattern: UsageEstimator {
    public enum Bins: String, Sendable { case hourOfDay = "hour of day", hourOfWeek = "hour of week", weekdayWeekend = "weekday/weekend hour" }

    public let bins: Bins
    /// How quickly old weeks stop counting.
    public let memory: TimeInterval
    /// How much of this window's history sets the "busier than usual" factor.
    public let intensityHalfLife: TimeInterval
    /// Fade of a recent burst; nil for none.
    public let fade: TimeInterval?
    public let recent: TimeInterval
    /// Leave the current window's last hours out of the pattern, so an ongoing burst isn't also
    /// learned as a habit.
    public let holdOut: TimeInterval
    /// Cap on how much busier than usual this window can be assumed to stay.
    public let maxIntensity: Double
    public var name: String {
        "Pattern \(bins == .hourOfDay ? "day" : bins == .hourOfWeek ? "week" : "wkday/end") m\(Estimators.duration(memory)) i\(Estimators.duration(intensityHalfLife))"
            + (fade.map { " τ\(Estimators.duration($0))" } ?? "")
            + (holdOut > 0 ? " ho\(Estimators.duration(holdOut))" : "") + (maxIntensity < 100 ? String(format: " ×%.0f", maxIntensity) : "")
    }

    public init(bins: Bins, memory: TimeInterval, intensityHalfLife: TimeInterval = 24 * 3600, fade: TimeInterval? = nil,
                recent: TimeInterval = 3600, holdOut: TimeInterval = 0, maxIntensity: Double = 1000) {
        self.bins = bins
        self.memory = memory
        self.intensityHalfLife = intensityHalfLife
        self.fade = fade
        self.recent = recent
        self.holdOut = holdOut
        self.maxIntensity = maxIntensity
    }

    func bin(_ hourOfWeek: Int) -> Int {
        switch bins {
        case .hourOfDay: hourOfWeek % 24
        case .hourOfWeek: hourOfWeek
        case .weekdayWeekend: ((hourOfWeek / 24 == 0 || hourOfWeek / 24 == 6) ? 24 : 0) + hourOfWeek % 24
        }
    }

    var binCount: Int { bins == .hourOfWeek ? 168 : bins == .hourOfDay ? 24 : 48 }

    /// Expected percent per hour for each bin, from past windows and this window so far.
    func profile(_ input: EstimationInput) -> (rates: [Double], mean: Double)? {
        var sum = [Double](repeating: 0, count: binCount), weight = [Double](repeating: 0, count: binCount)
        let now = input.now.timeIntervalSince1970
        var totalW = 0.0, totalRate = 0.0
        let heldOut = input.current.increments.count - Int(holdOut / input.current.step)
        for (k, series) in (input.past + [input.current]).enumerated() {
            let perHour = 3600 / series.step
            let t0 = series.start.timeIntervalSince1970
            let isCurrent = k == input.past.count
            for (s, inc) in series.increments.enumerated() {
                if isCurrent && s >= heldOut { break }
                let age = now - (t0 + Double(s) * series.step)
                let w = pow(0.5, age / memory)
                let b = bin(series.hourOfWeek(step: s))
                sum[b] += inc * perHour * w
                weight[b] += w
                totalRate += inc * perHour * w
                totalW += w
            }
        }
        guard totalW > 0 else { return nil }
        let mean = totalRate / totalW
        // Bins seen rarely lean on the overall mean.
        let prior = 2.0
        let rates = (0..<binCount).map { (sum[$0] + prior * mean) / (weight[$0] + prior) }
        return (rates, mean)
    }

    public func project(_ input: EstimationInput) -> Projection {
        let s = step(input)
        guard let (rates, mean) = profile(input) else {
            return LinearPace(lookback: 6 * 3600).project(input)
        }
        // How busy this window has been compared with the pattern, recent hours weighted most.
        let cur = input.current
        let decay = pow(0.5, cur.step / intensityHalfLife)
        var w = 1.0, observed = 0.0, expected = 0.0
        for i in stride(from: cur.increments.count - 1, through: 0, by: -1) {
            observed += cur.increments[i] * w
            expected += rates[bin(cur.hourOfWeek(step: i))] * cur.step / 3600 * w
            w *= decay
        }
        let shrink = mean * 6 // about six hours of usual usage
        let intensity = min(maxIntensity, (observed + shrink) / (expected + shrink))

        let recentRate = LinearPace.pace(input, lookback: recent)
        let startStep = cur.increments.count
        let incs = (0..<stepsToEnd(input)).map { i -> Double in
            let how = cur.hourOfWeek(step: startStep + i)
            let usual = rates[bin(how)] * intensity
            var rate = usual
            if let fade {
                let dt = (Double(i) + 0.5) * s
                rate = usual + (recentRate - usual) * exp(-dt / fade)
            }
            return max(0, rate) * s / 3600
        }
        return Projection(now: input.now, used: input.used, step: s, increments: incs)
    }
}

/// A weighted average of two estimators' projected growth.
public struct Blend: UsageEstimator {
    public let a: any UsageEstimator
    public let b: any UsageEstimator
    /// Weight of `a` (0...1).
    public let weight: Double
    public var name: String { String(format: "Blend %.0f%% ", weight * 100) + a.name.dropFirst(8).prefix(28) + " + " + b.name.prefix(4) }

    public init(_ a: any UsageEstimator, _ b: any UsageEstimator, weight: Double) {
        self.a = a
        self.b = b
        self.weight = weight
    }

    public func project(_ input: EstimationInput) -> Projection {
        let pa = a.project(input), pb = b.project(input)
        let n = max(pa.increments.count, pb.increments.count)
        let incs = (0..<n).map { i in
            weight * pa.increments[min(i, pa.increments.count - 1)] + (1 - weight) * pb.increments[min(i, pb.increments.count - 1)]
        }
        return Projection(now: input.now, used: input.used, step: pa.step, increments: incs)
    }
}

public enum Estimators {
    static func duration(_ s: TimeInterval) -> String {
        s >= 86400 && s.truncatingRemainder(dividingBy: 86400) == 0 ? "\(Int(s / 86400))d"
            : s >= 3600 ? "\(Int(s / 3600))h" : "\(Int(s / 60))m"
    }

    /// A parameter grid for tuning (`--backtest <file> --sweep`).
    public static func sweep(minutes: Int) -> [any UsageEstimator] {
        let h = 3600.0, d = 86400.0
        var out: [any UsageEstimator] = []
        if minutes <= 24 * 60 {
            for recent in [0.25, 0.5, 1] {
                for base in [1.0, 2, 4] {
                    for fade in [0.25, 0.5, 1, 2] {
                        out.append(FadingPace(recent: recent * h, baseHalfLife: base * h, fade: fade * h))
                    }
                }
            }
            for bins in [LearnedPattern.Bins.hourOfDay, .weekdayWeekend] {
                for memory in [7.0, 14, 28] {
                    for ih in [0.5, 1, 2] {
                        for fade in [0.5, 1] {
                            out.append(LearnedPattern(bins: bins, memory: memory * d, intensityHalfLife: ih * h, fade: fade * h, recent: 0.5 * h))
                        }
                    }
                }
            }
            return out
        }
        for bins in [LearnedPattern.Bins.hourOfDay, .weekdayWeekend, .hourOfWeek] {
            for memory in [7.0, 14, 28, 56] {
                for ih in [6.0, 12, 24, 48] {
                    for fade in [1.0, 2, 4] {
                        out.append(LearnedPattern(bins: bins, memory: memory * d, intensityHalfLife: ih * h, fade: fade * h, recent: h))
                    }
                }
            }
        }
        return out
    }

    /// The estimator the app uses for each window length, picked by backtesting (`--backtest`):
    /// weekly windows follow your usual hours of the day over the last two weeks, at up to twice the
    /// usual rate when this window runs busier, with bursts fading over ~2 hours (and the last 6 hours
    /// kept out of the learned pattern); 5-hour windows blend that pattern with a recent pace fading
    /// over an hour.
    public static func chosen(minutes: Int) -> any UsageEstimator {
        let h = 3600.0, d = 86400.0
        if minutes <= 24 * 60 {
            return Blend(LearnedPattern(bins: .hourOfDay, memory: 14 * d, intensityHalfLife: h, fade: h, recent: 0.5 * h,
                                        holdOut: 2 * h, maxIntensity: 2),
                         FadingPace(recent: 0.5 * h, baseHalfLife: 2 * h, fade: h), weight: 0.5)
        }
        return LearnedPattern(bins: .hourOfDay, memory: 14 * d, intensityHalfLife: 24 * h, fade: 2 * h, recent: h,
                              holdOut: 6 * h, maxIntensity: 2)
    }

    /// The estimators the backtest compares.
    public static func candidates(minutes: Int) -> [any UsageEstimator] {
        let short = minutes <= 24 * 60
        let h = 3600.0
        if short {
            let pattern = LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h, intensityHalfLife: h, fade: h, recent: 0.5 * h)
            if ProcessInfo.processInfo.environment["BT_ROBUST"] != nil {
                return [0.0, 1, 2].flatMap { holdOut in [1000.0, 3, 2].map { cap in
                    Blend(LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h, intensityHalfLife: h, fade: h, recent: 0.5 * h,
                                         holdOut: holdOut * h, maxIntensity: cap),
                          FadingPace(recent: 0.5 * h, baseHalfLife: 2 * h, fade: h), weight: 0.5) as any UsageEstimator
                } }
            }
            return [
                Blend(pattern, LinearPace(lookback: h), weight: 0.5),
                Blend(pattern, LinearPace(lookback: h), weight: 0.3),
                Blend(pattern, LinearPace(lookback: 0.5 * h), weight: 0.5),
                Blend(pattern, FadingPace(recent: 0.5 * h, baseHalfLife: 2 * h, fade: h), weight: 0.5),
                pattern,
                LinearPace(lookback: h),
                LinearPace(lookback: 0.5 * h),
                WeightedPace(halfLife: 0.5 * h),
                WeightedPace(halfLife: h),
                FadingPace(recent: 0.5 * h, baseHalfLife: 2 * h, fade: 0.5 * h),
                FadingPace(recent: 0.5 * h, baseHalfLife: 2 * h, fade: h),
                LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h, intensityHalfLife: h),
                LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h, intensityHalfLife: h, fade: 0.5 * h, recent: 0.5 * h),
                LearnedPattern(bins: .weekdayWeekend, memory: 21 * 24 * h, intensityHalfLife: h, fade: 0.5 * h, recent: 0.5 * h),
            ]
        }
        let week = LearnedPattern(bins: .hourOfWeek, memory: 7 * 24 * h, intensityHalfLife: 6 * h, fade: 2 * h, recent: h)
        var variants: [any UsageEstimator] = []
        for holdOut in [0.0, 6, 24] {
            for cap in [1000.0, 3, 2] {
                variants.append(LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h, intensityHalfLife: 24 * h, fade: 2 * h, recent: h,
                                               holdOut: holdOut * h, maxIntensity: cap))
            }
        }
        if ProcessInfo.processInfo.environment["BT_ROBUST"] != nil { return variants }
        return [
            week,
            Blend(week, LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h, fade: 2 * h), weight: 0.5),
            Blend(week, FadingPace(recent: h, baseHalfLife: 24 * h, fade: 2 * h), weight: 0.7),
            Blend(week, LinearPace(lookback: 6 * h), weight: 0.7),
            LinearPace(lookback: 6 * h),
            LinearPace(lookback: 24 * h),
            WeightedPace(halfLife: 6 * h),
            WeightedPace(halfLife: 24 * h),
            FadingPace(recent: 3 * h, baseHalfLife: 24 * h, fade: 3 * h),
            FadingPace(recent: 1 * h, baseHalfLife: 24 * h, fade: 2 * h),
            FadingPace(recent: 3 * h, baseHalfLife: 48 * h, fade: 6 * h),
            LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h),
            LearnedPattern(bins: .hourOfWeek, memory: 28 * 24 * h),
            LearnedPattern(bins: .weekdayWeekend, memory: 21 * 24 * h),
            LearnedPattern(bins: .hourOfDay, memory: 14 * 24 * h, fade: 2 * h),
            LearnedPattern(bins: .weekdayWeekend, memory: 21 * 24 * h, fade: 2 * h),
            LearnedPattern(bins: .weekdayWeekend, memory: 21 * 24 * h, intensityHalfLife: 12 * h, fade: 2 * h),
        ]
    }
}
