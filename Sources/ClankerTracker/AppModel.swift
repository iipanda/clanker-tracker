import ClankerCore
import Foundation
import Observation

enum Pane: Hashable {
    case overview
    case tool(Tool)
    case spend
    case settings
}

/// A calendar period for comparing spend: today, this week, this month, and the ones before.
enum SpendPeriod: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// How many periods the chart shows.
    var count: Int { self == .day ? 30 : 12 }

    func interval(containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 86400)
    }

    /// The `count` most recent periods, oldest first, ending with the current one.
    func recent(now: Date) -> [DateInterval] {
        var out: [DateInterval] = [interval(containing: now)]
        while out.count < count, let prev = Calendar.current.date(byAdding: component, value: -1, to: out[0].start) {
            out.insert(interval(containing: prev), at: 0)
        }
        return out
    }

    /// "Today", "This week", "Sep 21–27", "September"
    func name(_ i: DateInterval, now: Date) -> String {
        if i.contains(now) { return self == .day ? "Today" : "This \(rawValue)" }
        switch self {
        case .day: return i.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: return "Week of \(Fmt.monthDay(i.start))"
        case .month: return i.start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// Short label under a chart bar.
    func axisLabel(_ i: DateInterval) -> String {
        switch self {
        case .day: i.start.formatted(.dateTime.day())
        case .week: Fmt.monthDay(i.start)
        case .month: i.start.formatted(.dateTime.month(.abbreviated))
        }
    }
}

@Observable
final class AppSettings {
    enum MenuBarMode: String, CaseIterable, Identifiable {
        case tightest, both, icon
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tightest: "Tightest limit"
            case .both: "Both tools"
            case .icon: "Icon only"
            }
        }
    }

    private let defaults = UserDefaults.standard

    var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    var notifyRunout: Bool { didSet { defaults.set(notifyRunout, forKey: "notifyRunout") } }
    var notifyThreshold: Bool { didSet { defaults.set(notifyThreshold, forKey: "notifyThreshold") } }
    var threshold: Int { didSet { defaults.set(threshold, forKey: "threshold") } }
    var notifyReset: Bool { didSet { defaults.set(notifyReset, forKey: "notifyReset") } }
    var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }

    init() {
        defaults.register(defaults: [
            "menuBarMode": MenuBarMode.tightest.rawValue, "notifyRunout": true, "notifyThreshold": true,
            "threshold": 80, "notifyReset": false, "refreshSeconds": 60,
        ])
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .tightest
        notifyRunout = defaults.bool(forKey: "notifyRunout")
        notifyThreshold = defaults.bool(forKey: "notifyThreshold")
        threshold = defaults.integer(forKey: "threshold")
        notifyReset = defaults.bool(forKey: "notifyReset")
        refreshSeconds = max(15, defaults.integer(forKey: "refreshSeconds"))
    }

    var notificationPrefs: NotificationPrefs {
        NotificationPrefs(runout: notifyRunout, threshold: notifyThreshold ? Double(threshold) : nil, reset: notifyReset)
    }
}

/// Everything the UI shows. Forecasts are recomputed from the history on every tick; they're cheap.
@Observable
final class AppModel {
    private(set) var history = UsageHistory()
    private(set) var backfill: BackfillProgress?
    private(set) var spend = SpendLedger()
    private(set) var prices = PriceTable.bundled
    private(set) var hasLoaded = false
    private(set) var collector: ClaudeCollector.State = .canCreate
    private(set) var hookError: String?
    var now = Date()
    var pane: Pane? = .overview
    let settings = AppSettings()
    let isDemo: Bool

    @ObservationIgnored let engine: Engine
    @ObservationIgnored var onUpdate: ((_ isInitialLoad: Bool) -> Void)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(engine: Engine = Engine(), demo: Bool = false) {
        self.engine = engine
        isDemo = demo
    }

    func start() {
        refreshHookState()
        if isDemo {
            history = DemoData.history(now: now)
            spend = DemoData.spend(now: now)
            hasLoaded = true
            return
        }
        tasks.append(Task { [weak self, engine] in
            for await update in engine.updates {
                guard let self else { return }
                self.history = update.history
                self.backfill = update.backfill
                self.spend = update.spend
                self.prices = update.prices
                self.hasLoaded = true
                self.now = Date()
                self.onUpdate?(update.backfill != nil)
            }
        })
        tasks.append(Task { [engine] in await engine.start() })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        })
        tasks.append(Task { [weak self, engine] in
            while !Task.isCancelled {
                let seconds = self?.settings.refreshSeconds ?? 60
                try? await Task.sleep(for: .seconds(seconds))
                await engine.refresh()
                self?.refreshHookState()
            }
        })
    }

    func refresh() {
        refreshHookState()
        guard !isDemo else { now = Date(); return }
        Task { [engine] in await engine.refresh() }
    }

    func flush() async {
        guard !isDemo else { return }
        await engine.flush()
    }

    // MARK: Derived

    func forecasts(_ tool: Tool) -> [Forecast] { history.currentForecasts(for: tool, now: now) }
    var allForecasts: [Forecast] { history.currentForecasts(now: now) }
    var tightest: Forecast? { Tightest.pick(allForecasts) }
    func tightest(_ tool: Tool) -> Forecast? { Tightest.pick(forecasts(tool)) }
    func pastWeeks(_ tool: Tool) -> [WeekBar] { PastWeeks.bars(history, tool: tool, now: now) }

    // MARK: Spend

    func spendRows(tool: Tool? = nil, _ interval: DateInterval) -> [ModelSpend] {
        spend.totals(tool: tool, from: interval.start, to: interval.end)
    }

    func spendSummary(tool: Tool? = nil, _ interval: DateInterval) -> SpendSummary {
        SpendSummary(spendRows(tool: tool, interval), prices: prices)
    }

    /// API-equivalent cost of a limit window so far (hour resolution).
    func windowSpend(_ tool: Tool, from start: Date, to end: Date) -> SpendSummary {
        spendSummary(tool: tool, DateInterval(start: start, end: max(start, min(end, now.addingTimeInterval(3600)))))
    }
    func plan(_ tool: Tool) -> String? { history.plan(for: tool).map { "\($0.capitalized) plan" } }
    func lastSeen(_ tool: Tool) -> Date? { history.lastSeen(tool) }

    var lastReading: Date? { Tool.allCases.compactMap { lastSeen($0) }.max() }

    var updatedText: String {
        if isDemo { return "Updated 38s ago · sample data" }
        guard let last = lastReading else { return hasLoaded ? "No readings yet" : "Loading…" }
        return "Updated \(Fmt.ago(now.timeIntervalSince(last)))"
    }

    // MARK: Claude collector

    /// The `statusLine` entry before and after installing, when installing edits settings.json.
    var plannedCollectorChange: (before: String?, after: String)? {
        ClaudeCollector.plannedChange(settings: engine.paths.claudeSettings, managedScript: engine.paths.claudeManagedScript)
    }

    func refreshHookState() {
        collector = ClaudeCollector.state(settings: engine.paths.claudeSettings, managedScript: engine.paths.claudeManagedScript)
    }

    func installHook() {
        do {
            try FileManager.default.createDirectory(at: engine.paths.claudeDir, withIntermediateDirectories: true)
            try ClaudeCollector.install(settings: engine.paths.claudeSettings, managedScript: engine.paths.claudeManagedScript)
            hookError = nil
        } catch {
            hookError = "Couldn't set up the collector: \(error.localizedDescription)"
        }
        refreshHookState()
    }

    func uninstallHook() {
        do {
            try ClaudeCollector.uninstall(settings: engine.paths.claudeSettings, managedScript: engine.paths.claudeManagedScript)
            hookError = nil
        } catch {
            hookError = "Couldn't remove the collector: \(error.localizedDescription)"
        }
        refreshHookState()
    }
}
