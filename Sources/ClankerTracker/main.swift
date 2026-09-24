import AppKit
import ClankerCore
import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--dump") {
    // Headless: read everything once and print the current limits as JSON.
    Task.detached {
        let started = Date()
        let engine = Engine()
        await engine.start(watch: false)
        await engine.flush()
        let history = await engine.currentHistory()
        let spend = await engine.currentSpend()
        let prices = await engine.currentPrices()
        let now = Date()
        let cal = Calendar.current
        func period(_ c: Calendar.Component) -> [String: Any] {
            let start = cal.dateInterval(of: c, for: now)?.start ?? now
            return Dictionary(uniqueKeysWithValues: Tool.allCases.map { tool in
                let s = SpendSummary(spend.totals(tool: tool, from: start, to: now.addingTimeInterval(3600)), prices: prices)
                return (tool.rawValue, ["usd": (s.usd * 100).rounded() / 100, "tokens": s.tokens.total, "unpricedTokens": s.unpricedTokens])
            })
        }
        let byModel = spend.totals(from: .distantPast, to: now.addingTimeInterval(3600))
            .sorted { ($0.cost(prices) ?? -1) > ($1.cost(prices) ?? -1) }
            .map { m -> [String: Any] in
                ["tool": m.tool.rawValue, "model": m.model + (m.fast ? " (fast)" : ""), "tokens": m.tokens.total,
                 "usd": m.cost(prices).map { ($0 * 100).rounded() / 100 } ?? NSNull()]
            }
        let limits = history.currentForecasts(now: now).map { f -> [String: Any] in
            [
                "tool": f.tool.rawValue, "window": f.window.label, "used": f.used,
                "resetsAt": ISO8601DateFormatter().string(from: f.end),
                "pacePerHour": f.pace, "sustainablePerHour": f.sustainable, "projected": f.projected,
                "runsOut": f.runsOut, "runoutAt": f.runoutDate.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "lastReading": ISO8601DateFormatter().string(from: f.lastSeen), "stale": f.isStale,
            ]
        }
        let summary: [String: Any] = [
            "seconds": (now.timeIntervalSince(started) * 10).rounded() / 10,
            "windows": history.windows.count,
            "points": history.windows.reduce(0) { $0 + $1.points.count },
            "plans": history.plans,
            "limits": limits,
            "spend": [
                "today": period(.day), "thisWeek": period(.weekOfYear), "thisMonth": period(.month),
                "since": spend.firstDate.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "byModel": byModel,
                "pricesFetchedAt": prices.fetchedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "bundled",
            ] as [String: Any],
            "pastWeeks": Dictionary(uniqueKeysWithValues: Tool.allCases.map { tool in
                (tool.rawValue, PastWeeks.bars(history, tool: tool, now: now).map { ["ended": $0.isCurrent ? "current" : Fmt.monthDay($0.end), "peak": $0.peak] })
            }),
        ]
        let data = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    dispatchMain()
}

if arguments.contains("--setup") {
    exit(Setup.run(openAtLogin: !arguments.contains("--no-open-at-login")))
}

if let i = arguments.firstIndex(of: "--export-history"), i + 1 < arguments.count {
    // Reads every log once and writes all limit windows (unpruned), for --backtest.
    let out = URL(fileURLWithPath: arguments[i + 1])
    Task.detached {
        let engine = Engine(downloadsPrices: false)
        await engine.start(watch: false)
        let history = await engine.currentHistory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try! encoder.encode(history).write(to: out)
        print("\(history.windows.count) windows → \(out.path)")
        exit(0)
    }
    dispatchMain()
}

if let i = arguments.firstIndex(of: "--backtest"), i + 1 < arguments.count {
    // Replays past Codex windows against each estimator: --backtest <history.json from --export-history>
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let history = try decoder.decode(UsageHistory.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])))
    let sweep = arguments.contains("--sweep")
    if arguments.contains("--spikes") {
        // Forecast warnings plus "if you keep this pace" spike alerts, for 5-hour windows.
        let bt = Backtest(history: history, tool: .codex, minutes: 300, config: .fiveHour)
        let chosen = Estimators.chosen(minutes: 300)
        let scores = [bt.run(LinearPace(lookback: 3600)), bt.run(chosen)] + [0.25, 0.5, 1].map { bt.run(chosen, spikeLookback: $0 * 3600) }
        print(Backtest.table(scores, config: .fiveHour))
        exit(0)
    }
    if arguments.contains("--learning") {
        // How much better predictions get with more past history to learn from.
        for (minutes, base) in [(10080, Backtest.Config.weekly), (300, Backtest.Config.fiveHour)] {
            print("\n== Learning curve, Codex \(minutes == 10080 ? "weekly" : "5-hour"): active-use error at each horizon, by weeks of history")
            let est = Estimators.chosen(minutes: minutes)
            for weeks in [0, 1, 2, 4, 8, 52] {
                var config = base
                config.historyLimit = Double(weeks) * 7 * 86400
                let bt = Backtest(history: history, tool: .codex, minutes: minutes, config: config)
                let s = bt.run(est)
                print(String(format: "  %2d weeks: ", weeks) + s.horizons.map { String(format: "%6.2f", $0.activeMAE) }.joined() + String(format: "   F1 %.2f", s.f1))
            }
        }
        exit(0)
    }
    for (minutes, config) in [(10080, Backtest.Config.weekly), (300, Backtest.Config.fiveHour)] {
        let bt = Backtest(history: history, tool: .codex, minutes: minutes, config: config)
        let hits = bt.windows.filter { $0.window.peak >= config.ranOutAt }.count
        print("\n== Codex \(minutes == 10080 ? "weekly" : "5-hour") windows: \(bt.windows.count) (\(hits) ran out)")
        let estimators = sweep ? Estimators.sweep(minutes: minutes) : Estimators.candidates(minutes: minutes)
        let baseline = bt.run(LinearPace(lookback: minutes <= 1440 ? 3600 : 6 * 3600))
        let scores = estimators.map { bt.run($0) }.sorted { Backtest.objective($0, baseline: baseline) < Backtest.objective($1, baseline: baseline) }
        print(Backtest.table([baseline] + (sweep ? Array(scores.prefix(12)) : scores), config: config))
        for s in [baseline] + scores.prefix(sweep ? 3 : 2) {
            let curve = s.byHistory.keys.sorted().map { k in
                let v = s.byHistory[k]!
                return "\(k == 0 ? "<2" : k == 8 ? "8+" : "\(k)-\(k * 2)")w: \(String(format: "%.2f", v.err / Double(v.n))) (n=\(v.n))"
            }
            print("  error at longest horizon by weeks of history · \(s.name): " + curve.joined(separator: ", "))
        }
    }
    exit(0)
}

if arguments.contains("--explain") {
    // How the current Codex weekly forecast was made, from the app's saved history (read-only).
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let history = try decoder.decode(UsageHistory.self, from: Data(contentsOf: AppPaths.standard.historyFile))
    let now = Date()
    for f in history.currentForecasts(now: now) where !f.isReset {
        print("\n== \(f.tool.displayName) \(f.window.label): \(Fmt.pct(f.used, digits: 1)) used, resets \(Fmt.dateClock(f.end))")
        print("pace last \(Int(f.lookbackHours))h \(Fmt.rate(f.pace))%/h · sustainable \(Fmt.rate(f.sustainable))%/h · learned from \(f.learnedFrom) past windows")
        let input = EstimationInput(window: f.window, now: now, past: history.pastSeries(tool: f.tool, minutes: f.window.minutes, before: now))
        let estimator = Estimators.chosen(minutes: f.window.minutes)
        let pattern = (estimator as? LearnedPattern) ?? ((estimator as? Blend)?.a as? LearnedPattern)
        if let pattern, let e = pattern.explain(input) {
            print(String(format: "usual %.2f%%/h on average · this window %.2fx busier than usual (used: %.2fx) · recent %.2f%%/h fading over %@",
                         e.mean, e.intensity, e.cappedIntensity, e.recentRate, pattern.fade.map { Fmt.duration(hours: $0 / 3600) } ?? "–"))
            let peak = e.usual.max() ?? 1
            for (h, r) in e.usual.enumerated() {
                print(String(format: "  %02d:00  %5.2f%%/h  ", h, r) + String(repeating: "█", count: Int((r / peak * 30).rounded())))
            }
        }
        print("projection (hourly):")
        var t = now, last = f.used
        while t < min(f.end, (f.runoutDate ?? f.end).addingTimeInterval(3600)) {
            t = t.addingTimeInterval(3600)
            let v = f.projection.value(at: t)
            print("  \(Fmt.dayClock(t))  \(Fmt.pct(v, digits: 1))  (+\(String(format: "%.2f", v - last)))")
            last = v
            if v >= 100 { break }
        }
        print("runs out: \(f.runoutDate.map(Fmt.dateClock) ?? "not before reset") · at reset: \(Fmt.pct(f.projected))")
    }
    exit(0)
}

if arguments.contains("--install-collector") || arguments.contains("--remove-collector") {
    // Same as Install / Remove in Settings → Data sources.
    let paths = AppPaths.standard
    let (settings, managed) = (paths.claudeSettings, paths.claudeManagedScript)
    do {
        if let i = arguments.firstIndex(of: "--export-history"), i + 1 < arguments.count {
    // Reads every log once and writes all limit windows (unpruned), for --backtest.
    let out = URL(fileURLWithPath: arguments[i + 1])
    Task.detached {
        let engine = Engine(downloadsPrices: false)
        await engine.start(watch: false)
        let history = await engine.currentHistory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try! encoder.encode(history).write(to: out)
        print("\(history.windows.count) windows → \(out.path)")
        exit(0)
    }
    dispatchMain()
}

if let i = arguments.firstIndex(of: "--backtest"), i + 1 < arguments.count {
    // Replays past Codex windows against each estimator: --backtest <history.json from --export-history>
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let history = try decoder.decode(UsageHistory.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])))
    let sweep = arguments.contains("--sweep")
    if arguments.contains("--spikes") {
        // Forecast warnings plus "if you keep this pace" spike alerts, for 5-hour windows.
        let bt = Backtest(history: history, tool: .codex, minutes: 300, config: .fiveHour)
        let chosen = Estimators.chosen(minutes: 300)
        let scores = [bt.run(LinearPace(lookback: 3600)), bt.run(chosen)] + [0.25, 0.5, 1].map { bt.run(chosen, spikeLookback: $0 * 3600) }
        print(Backtest.table(scores, config: .fiveHour))
        exit(0)
    }
    if arguments.contains("--learning") {
        // How much better predictions get with more past history to learn from.
        for (minutes, base) in [(10080, Backtest.Config.weekly), (300, Backtest.Config.fiveHour)] {
            print("\n== Learning curve, Codex \(minutes == 10080 ? "weekly" : "5-hour"): active-use error at each horizon, by weeks of history")
            let est = Estimators.chosen(minutes: minutes)
            for weeks in [0, 1, 2, 4, 8, 52] {
                var config = base
                config.historyLimit = Double(weeks) * 7 * 86400
                let bt = Backtest(history: history, tool: .codex, minutes: minutes, config: config)
                let s = bt.run(est)
                print(String(format: "  %2d weeks: ", weeks) + s.horizons.map { String(format: "%6.2f", $0.activeMAE) }.joined() + String(format: "   F1 %.2f", s.f1))
            }
        }
        exit(0)
    }
    for (minutes, config) in [(10080, Backtest.Config.weekly), (300, Backtest.Config.fiveHour)] {
        let bt = Backtest(history: history, tool: .codex, minutes: minutes, config: config)
        let hits = bt.windows.filter { $0.window.peak >= config.ranOutAt }.count
        print("\n== Codex \(minutes == 10080 ? "weekly" : "5-hour") windows: \(bt.windows.count) (\(hits) ran out)")
        let estimators = sweep ? Estimators.sweep(minutes: minutes) : Estimators.candidates(minutes: minutes)
        let baseline = bt.run(LinearPace(lookback: minutes <= 1440 ? 3600 : 6 * 3600))
        let scores = estimators.map { bt.run($0) }.sorted { Backtest.objective($0, baseline: baseline) < Backtest.objective($1, baseline: baseline) }
        print(Backtest.table([baseline] + (sweep ? Array(scores.prefix(12)) : scores), config: config))
        for s in [baseline] + scores.prefix(sweep ? 3 : 2) {
            let curve = s.byHistory.keys.sorted().map { k in
                let v = s.byHistory[k]!
                return "\(k == 0 ? "<2" : k == 8 ? "8+" : "\(k)-\(k * 2)")w: \(String(format: "%.2f", v.err / Double(v.n))) (n=\(v.n))"
            }
            print("  error at longest horizon by weeks of history · \(s.name): " + curve.joined(separator: ", "))
        }
    }
    exit(0)
}

if arguments.contains("--explain") {
    // How the current Codex weekly forecast was made, from the app's saved history (read-only).
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let history = try decoder.decode(UsageHistory.self, from: Data(contentsOf: AppPaths.standard.historyFile))
    let now = Date()
    for f in history.currentForecasts(now: now) where !f.isReset {
        print("\n== \(f.tool.displayName) \(f.window.label): \(Fmt.pct(f.used, digits: 1)) used, resets \(Fmt.dateClock(f.end))")
        print("pace last \(Int(f.lookbackHours))h \(Fmt.rate(f.pace))%/h · sustainable \(Fmt.rate(f.sustainable))%/h · learned from \(f.learnedFrom) past windows")
        let input = EstimationInput(window: f.window, now: now, past: history.pastSeries(tool: f.tool, minutes: f.window.minutes, before: now))
        let estimator = Estimators.chosen(minutes: f.window.minutes)
        let pattern = (estimator as? LearnedPattern) ?? ((estimator as? Blend)?.a as? LearnedPattern)
        if let pattern, let e = pattern.explain(input) {
            print(String(format: "usual %.2f%%/h on average · this window %.2fx busier than usual (used: %.2fx) · recent %.2f%%/h fading over %@",
                         e.mean, e.intensity, e.cappedIntensity, e.recentRate, pattern.fade.map { Fmt.duration(hours: $0 / 3600) } ?? "–"))
            let peak = e.usual.max() ?? 1
            for (h, r) in e.usual.enumerated() {
                print(String(format: "  %02d:00  %5.2f%%/h  ", h, r) + String(repeating: "█", count: Int((r / peak * 30).rounded())))
            }
        }
        print("projection (hourly):")
        var t = now, last = f.used
        while t < min(f.end, (f.runoutDate ?? f.end).addingTimeInterval(3600)) {
            t = t.addingTimeInterval(3600)
            let v = f.projection.value(at: t)
            print("  \(Fmt.dayClock(t))  \(Fmt.pct(v, digits: 1))  (+\(String(format: "%.2f", v - last)))")
            last = v
            if v >= 100 { break }
        }
        print("runs out: \(f.runoutDate.map(Fmt.dateClock) ?? "not before reset") · at reset: \(Fmt.pct(f.projected))")
    }
    exit(0)
}

if arguments.contains("--install-collector") {
            if let change = ClaudeCollector.plannedChange(settings: settings, managedScript: managed) {
                print("statusLine in \(settings.path)\n  now:   \(change.before ?? "not set")\n  after: \(change.after)")
            }
            try FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
            try ClaudeCollector.install(settings: settings, managedScript: managed)
        } else {
            try ClaudeCollector.uninstall(settings: settings, managedScript: managed)
        }
        print("Collector: \(ClaudeCollector.state(settings: settings, managedScript: managed))")
        exit(0)
    } catch {
        print("Failed: \(error.localizedDescription)")
        exit(1)
    }
}

if let i = arguments.firstIndex(of: "--open-at-login") {
    // Same as Settings → General → Open at login. `--open-at-login off` turns it off.
    let on = !(i + 1 < arguments.count && arguments[i + 1] == "off")
    do {
        try LoginItem.set(on)
        print("Open at login: \(LoginItem.isEnabled ? "on" : "off")")
        exit(0)
    } catch {
        print("Couldn't change Open at login: \(error.localizedDescription)")
        exit(1)
    }
}

if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Snapshot.run(to: URL(fileURLWithPath: arguments[i + 1]), model: AppModel(demo: arguments.contains("--demo")))
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate(demo: arguments.contains("--demo"))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
