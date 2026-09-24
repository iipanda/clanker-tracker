import Foundation

/// Replays past limit windows: at each sample time an estimator sees only the readings up to then,
/// and its predictions are compared with what actually happened.
public struct Backtest: Sendable {
    public struct Config: Sendable {
        /// Horizons to score, in seconds after the sample time.
        public var horizons: [TimeInterval]
        /// Time between sample points.
        public var every: TimeInterval
        /// Skip the first part of each window (too little data to judge).
        public var warmup: TimeInterval
        /// Usage from which a window counts as having run out. Codex tends to reset a window early
        /// once it's in the high 90s, so a window that reached 95% had effectively run out.
        public var ranOutAt = 95.0
        /// Limit what estimators may learn from to this much past history (nil: everything before).
        public var historyLimit: TimeInterval?

        public static let weekly = Config(horizons: [1, 3, 6, 12, 24].map { $0 * 3600 }, every: 3600, warmup: 3600)
        public static let fiveHour = Config(horizons: [15, 30, 60, 120].map { $0 * 60 }, every: 600, warmup: 600)
    }

    public struct HorizonScore: Sendable {
        public var horizon: TimeInterval
        public var samples = 0
        public var absError = 0.0
        public var error = 0.0
        /// Samples where usage actually grew within the horizon.
        public var activeSamples = 0
        public var activeAbsError = 0.0

        public var mae: Double { samples > 0 ? absError / Double(samples) : 0 }
        public var bias: Double { samples > 0 ? error / Double(samples) : 0 }
        public var activeMAE: Double { activeSamples > 0 ? activeAbsError / Double(activeSamples) : 0 }
    }

    public struct Score: Sendable {
        public var name: String
        public var horizons: [HorizonScore]
        /// "Runs out before the window ends" warnings against windows that really ran out (see `ranOutAt`).
        public var truePositives = 0, falsePositives = 0, falseNegatives = 0, trueNegatives = 0
        /// For windows that ran out: |predicted − actual| time of running out, from samples within the
        /// last 24 hours (or 2 hours for short windows) before it happened, in hours.
        public var runoutErrors: [Double] = []
        /// Active-sample absolute error at the longest horizon, by weeks of history before the sample.
        public var byHistory: [Int: (n: Int, err: Double)] = [:]

        public var precision: Double { truePositives + falsePositives > 0 ? Double(truePositives) / Double(truePositives + falsePositives) : 0 }
        public var recall: Double { truePositives + falseNegatives > 0 ? Double(truePositives) / Double(truePositives + falseNegatives) : 0 }
        public var f1: Double { precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0 }
        public var medianRunoutError: Double {
            let s = runoutErrors.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
    }

    public let windows: [(window: LimitWindow, end: Date)]
    let series: [WindowSeries]
    public let config: Config

    /// Windows of one tool and length, oldest first, with when each actually ended.
    public init(history: UsageHistory, tool: Tool, minutes: Int, config: Config, minReadings: Int = 3) {
        windows = history.windows(for: tool)
            .filter { $0.minutes == minutes && $0.points.count >= minReadings }
            .map { ($0, history.effectiveEnd(of: $0)) }
        series = windows.map { WindowSeries($0.window, end: $0.end) }
        self.config = config
    }

    /// - Parameter spikeLookback: also count a warning when the pace over this lookback would run the
    ///   window out (the "if you keep this pace" alert), for scoring warnings.
    public func run(_ estimator: any UsageEstimator, spikeLookback: TimeInterval? = nil) -> Score {
        var score = Score(name: estimator.name + (spikeLookback.map { " + spike \(Estimators.duration($0))" } ?? ""),
                          horizons: config.horizons.map { HorizonScore(horizon: $0) })
        for (i, item) in windows.enumerated() {
            let w = item.window, end = item.end
            let hitAt = w.points.first { $0.pct >= config.ranOutAt }?.t
            var t = w.start.addingTimeInterval(config.warmup)
            while t < end {
                defer { t = t.addingTimeInterval(config.every) }
                if let hitAt, t >= hitAt { break }
                let visible = LimitWindow(tool: w.tool, minutes: w.minutes, resetsAt: w.resetsAt, points: w.points.filter { $0.t <= t })
                let oldest = config.historyLimit.map { t.addingTimeInterval(-$0) } ?? .distantPast
                let past = windows.indices.prefix(i).filter { windows[$0].end <= t && windows[$0].end > oldest }.map { series[$0] }
                let input = EstimationInput(window: visible, now: t, past: past)
                let projection = estimator.project(input)
                let usedNow = input.used

                for (h, horizon) in config.horizons.enumerated() where t.addingTimeInterval(horizon) <= end {
                    let at = t.addingTimeInterval(horizon)
                    let actual = EstimationInput.value(w.points, at: at)
                    let predicted = projection.value(at: at)
                    score.horizons[h].samples += 1
                    score.horizons[h].absError += abs(predicted - actual)
                    score.horizons[h].error += predicted - actual
                    if actual > usedNow {
                        score.horizons[h].activeSamples += 1
                        score.horizons[h].activeAbsError += abs(predicted - actual)
                        if h == config.horizons.count - 1 {
                            let weeks = min(8, Int(t.timeIntervalSince(windows[0].window.start) / (7 * 86400)))
                            let bucket = weeks < 2 ? 0 : weeks < 4 ? 2 : weeks < 8 ? 4 : 8
                            let prev = score.byHistory[bucket] ?? (0, 0)
                            score.byHistory[bucket] = (prev.n + 1, prev.err + abs(predicted - actual))
                        }
                    }
                }

                // A warning can only be checked up to when the window really ended (Codex often resets early).
                let predictedRunout = projection.runout(before: end)
                    ?? spikeLookback.flatMap { LinearPace(lookback: $0).project(input).runout(before: end) }
                switch (predictedRunout != nil, hitAt != nil) {
                case (true, true): score.truePositives += 1
                case (true, false): score.falsePositives += 1
                case (false, true): score.falseNegatives += 1
                case (false, false): score.trueNegatives += 1
                }
                let lead: TimeInterval = w.isShort ? 2 * 3600 : 24 * 3600
                if let hitAt, hitAt.timeIntervalSince(t) <= lead {
                    let predicted = predictedRunout ?? end
                    score.runoutErrors.append(abs(predicted.timeIntervalSince(hitAt)) / 3600)
                }
            }
        }
        return score
    }

    /// One number to rank estimators by (lower is better): mean active-use error over the horizons,
    /// relative to `baseline`, plus how often run-out warnings are wrong or missing.
    public static func objective(_ s: Score, baseline: Score) -> Double {
        let rel = zip(s.horizons, baseline.horizons).map { $0.activeMAE / max(0.01, $1.activeMAE) }
        return rel.reduce(0, +) / Double(rel.count) + (1 - s.f1)
    }

    /// A plain-text table comparing estimators.
    public static func table(_ scores: [Score], config: Config) -> String {
        func h(_ s: TimeInterval) -> String { s >= 3600 ? "\(Int(s / 3600))h" : "\(Int(s / 60))m" }
        var out = "Estimator".padding(toLength: 44, withPad: " ", startingAt: 0)
        out += config.horizons.map { ("MAE " + h($0)).leftPad(9) }.joined()
        out += config.horizons.map { ("act " + h($0)).leftPad(9) }.joined()
        out += "  bias\(h(config.horizons.last!))".leftPad(10) + "  prec  recall   F1  runoutErr\n"
        for s in scores {
            out += s.name.padding(toLength: 44, withPad: " ", startingAt: 0)
            out += s.horizons.map { String(format: "%9.2f", $0.mae) }.joined()
            out += s.horizons.map { String(format: "%9.2f", $0.activeMAE) }.joined()
            out += String(format: "%10.2f", s.horizons.last!.bias)
            out += String(format: "  %.2f  %.2f  %.2f  %6.1fh", s.precision, s.recall, s.f1, s.medianRunoutError)
            out += "\n"
        }
        return out
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
