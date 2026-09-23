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

if arguments.contains("--install-collector") || arguments.contains("--remove-collector") {
    // Same as Install / Remove in Settings → Data sources.
    let paths = AppPaths.standard
    let (settings, managed) = (paths.claudeSettings, paths.claudeManagedScript)
    do {
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
