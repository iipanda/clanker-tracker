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

    /// The `count` most recent periods, oldest first, ending with the current one. Weeks follow the
    /// weekly limit's resets (split where it reset early): the tool's, or Claude Code's for both tools.
    /// Calendar weeks until a tool has weekly windows.
    func recent(now: Date, history: UsageHistory, tool: Tool?, count: Int? = nil) -> [DateInterval] {
        let count = count ?? self.count
        if self == .week, let periods = (tool.map { [$0] } ?? Tool.allCases).lazy
            .compactMap({ WeeklyPeriods.recent(history, tool: $0, now: now, count: count) }).first {
            return periods
        }
        var out: [DateInterval] = [interval(containing: now)]
        while out.count < count, let prev = Calendar.current.date(byAdding: component, value: -1, to: out[0].start) {
            out.insert(interval(containing: prev), at: 0)
        }
        return out
    }

    /// "Today", "This week", "Sep 21–27", "September"
    func name(_ i: DateInterval, now: Date) -> String {
        if i.start <= now && now < i.end { return self == .day ? "Today" : "This \(rawValue)" }
        switch self {
        case .day: return i.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            let last = i.end.addingTimeInterval(-1)
            // A window reset early can start and end on the same day.
            if Calendar.current.isDate(i.start, inSameDayAs: last) { return "\(Fmt.monthDay(i.start)), \(Fmt.clock(i.start))–\(Fmt.clock(i.end))" }
            return "\(Fmt.monthDay(i.start))–\(Fmt.monthDay(last))"
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
            case .both: "All tools"
            case .icon: "Icon only"
            }
        }
    }

    private let defaults: UserDefaults

    var menuBarMode: MenuBarMode { didSet { defaults.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    var notifyRunout: Bool { didSet { defaults.set(notifyRunout, forKey: "notifyRunout") } }
    var notifyThreshold: Bool { didSet { defaults.set(notifyThreshold, forKey: "notifyThreshold") } }
    var threshold: Int { didSet { defaults.set(threshold, forKey: "threshold") } }
    var notifyReset: Bool { didSet { defaults.set(notifyReset, forKey: "notifyReset") } }
    var notifySpikes: Bool { didSet { defaults.set(notifySpikes, forKey: "notifySpikes") } }
    var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }
    var claudeEnabled: Bool { didSet { defaults.set(claudeEnabled, forKey: "claudeEnabled") } }
    var codexEnabled: Bool { didSet { defaults.set(codexEnabled, forKey: "codexEnabled") } }
    var cursorEnabled: Bool { didSet { defaults.set(cursorEnabled, forKey: "cursorEnabled") } }
    /// On by default: check limits with Anthropic using Claude Code's login (for Fable and when Claude Code is idle).
    var checkUsage: Bool { didSet { defaults.set(checkUsage, forKey: "checkUsage") } }
    /// On by default: check Cursor Agent plan usage and spend using the agent CLI login from the Keychain.
    var checkCursorUsage: Bool { didSet { defaults.set(checkCursorUsage, forKey: "checkCursorUsage") } }
    /// Opt-in: the Grok Bot weekly limit, and Grok Bot requests in spend.
    var trackGrokBot: Bool { didSet { defaults.set(trackGrokBot, forKey: "trackGrokBot") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migrate the old Cursor opt-out once; later API-check changes are independent.
        if defaults.object(forKey: "cursorEnabled") == nil {
            defaults.set(defaults.object(forKey: "checkCursorUsage") as? Bool ?? true, forKey: "cursorEnabled")
        }
        defaults.register(defaults: [
            "menuBarMode": MenuBarMode.tightest.rawValue, "notifyRunout": true, "notifyThreshold": true,
            "threshold": 80, "notifyReset": false, "notifySpikes": true, "refreshSeconds": 60,
            "claudeEnabled": true, "codexEnabled": true,
            "checkUsage": true, "checkCursorUsage": true, "trackGrokBot": false,
        ])
        menuBarMode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .tightest
        notifyRunout = defaults.bool(forKey: "notifyRunout")
        notifyThreshold = defaults.bool(forKey: "notifyThreshold")
        threshold = defaults.integer(forKey: "threshold")
        notifyReset = defaults.bool(forKey: "notifyReset")
        notifySpikes = defaults.bool(forKey: "notifySpikes")
        refreshSeconds = max(15, defaults.integer(forKey: "refreshSeconds"))
        claudeEnabled = defaults.bool(forKey: "claudeEnabled")
        codexEnabled = defaults.bool(forKey: "codexEnabled")
        cursorEnabled = defaults.bool(forKey: "cursorEnabled")
        checkUsage = defaults.bool(forKey: "checkUsage")
        checkCursorUsage = defaults.bool(forKey: "checkCursorUsage")
        trackGrokBot = defaults.bool(forKey: "trackGrokBot")
    }

    func isEnabled(_ tool: Tool) -> Bool {
        switch tool {
        case .claude: claudeEnabled
        case .codex: codexEnabled
        case .cursor: cursorEnabled
        }
    }

    func setEnabled(_ enabled: Bool, for tool: Tool) {
        switch tool {
        case .claude: claudeEnabled = enabled
        case .codex: codexEnabled = enabled
        case .cursor: cursorEnabled = enabled
        }
    }

    var notificationPrefs: NotificationPrefs {
        NotificationPrefs(runout: notifyRunout, threshold: notifyThreshold ? Double(threshold) : nil, reset: notifyReset, spikes: notifySpikes)
    }
}

/// Everything the UI shows. Forecasts are recomputed from the history on every tick; they're cheap.
@Observable
final class AppModel {
    /// Limit history as the engine recorded it, plus estimates for scoped limits (Fable) between their
    /// reported readings (see `ScopedEstimate`).
    private(set) var history = UsageHistory()
    @ObservationIgnored private var recorded = UsageHistory()
    /// As the engine has them, before leaving out what isn't tracked (Grok Bot).
    @ObservationIgnored private var engineHistory = UsageHistory()
    @ObservationIgnored private var engineSpend = SpendLedger()
    @ObservationIgnored private var estimatedAt = Date.distantPast
    private(set) var usageCheck: UsageCheck?
    private(set) var cursorUsageCheck: UsageCheck?
    private(set) var backfill: BackfillProgress?
    private(set) var spend = SpendLedger()
    private(set) var prices = PriceTable.bundled
    private(set) var hasLoaded = false
    private(set) var collector: ClaudeCollector.State = .canCreate
    private(set) var hookError: String?
    var now = Date()
    var pane: Pane? = .overview
    /// The ended window each tool's card shows instead of the current one, by window id.
    var browsing: [Tool: String] = [:]
    let settings: AppSettings
    let isDemo: Bool
    private(set) var installedTools: Set<Tool>
    @ObservationIgnored private let detectAgents: () -> Set<Tool>

    @ObservationIgnored let engine: Engine
    @ObservationIgnored var onUpdate: ((_ isInitialLoad: Bool) -> Void)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(engine: Engine = Engine(), demo: Bool = false, settings: AppSettings = AppSettings(), detectAgents: (() -> Set<Tool>)? = nil) {
        self.engine = engine
        isDemo = demo
        self.settings = settings
        let detector = detectAgents ?? (demo ? { Set(Tool.allCases) } : { InstalledAgents.detect() })
        self.detectAgents = detector
        installedTools = detector()
    }

    func start() {
        refreshHookState()
        if isDemo {
            engineHistory = DemoData.history(now: now)
            engineSpend = DemoData.spend(now: now)
            applyTracking()
            hasLoaded = true
            return
        }
        tasks.append(Task { [weak self, engine] in
            for await update in engine.updates {
                guard let self else { return }
                self.engineHistory = update.history
                self.engineSpend = update.spend
                self.backfill = update.backfill
                self.prices = update.prices
                self.usageCheck = update.usageCheck
                self.cursorUsageCheck = update.cursorUsageCheck
                self.hasLoaded = true
                self.now = Date()
                self.applyTracking()
                self.onUpdate?(update.backfill != nil)
            }
        })
        let checkUsage = shouldCheckUsage
        let checkCursor = shouldCheckCursor
        let grokBot = settings.trackGrokBot
        tasks.append(Task { [engine] in
            await engine.start()
            await engine.setUsageChecks(enabled: checkUsage)
            await engine.setCursorChecks(enabled: checkCursor, grokBot: grokBot)
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
                if let self, self.now.timeIntervalSince(self.estimatedAt) > 60 { self.updateEstimates() }
            }
        })
        tasks.append(Task { [weak self, engine] in
            while !Task.isCancelled {
                let seconds = self?.settings.refreshSeconds ?? 60
                try? await Task.sleep(for: .seconds(seconds))
                self?.refreshInstalledAgents()
                await engine.refresh()
                self?.refreshHookState()
            }
        })
    }

    private var shouldCheckUsage: Bool { trackedTools.contains(.claude) && settings.checkUsage }
    private var shouldCheckCursor: Bool { trackedTools.contains(.cursor) && settings.checkCursorUsage }

    private func syncUsageChecks() {
        guard !isDemo else { return }
        Task { [weak self, engine] in
            guard let self else { return }
            await engine.setUsageChecks(enabled: self.shouldCheckUsage)
            await engine.setCursorChecks(enabled: self.shouldCheckCursor, grokBot: self.settings.trackGrokBot)
        }
    }

    func setProviderEnabled(_ enabled: Bool, for tool: Tool) {
        settings.setEnabled(enabled, for: tool)
        applyTracking()
        syncUsageChecks()
    }

    func refreshInstalledAgents() {
        let detected = detectAgents()
        guard detected != installedTools else { return }
        installedTools = detected
        applyTracking()
        syncUsageChecks()
    }

    func setUsageChecks(_ enabled: Bool) {
        settings.checkUsage = enabled
        syncUsageChecks()
    }

    func setCursorChecks(_ enabled: Bool) {
        settings.checkCursorUsage = enabled
        syncUsageChecks()
    }

    func setTrackGrokBot(_ enabled: Bool) {
        settings.trackGrokBot = enabled
        if let id = browsing[.cursor], history.windows.contains(where: { $0.id == id && $0.scope == CursorUsageAPI.grokBotScope }) {
            browsing[.cursor] = nil
        }
        applyTracking()
        guard !isDemo else { return }
        syncUsageChecks()
    }

    /// Keep disabled sources out of the UI and alerts while preserving their recorded data.
    private func applyTracking() {
        recorded = engineHistory
        spend = engineSpend
        let tools = Set(trackedTools)
        recorded.windows.removeAll { !tools.contains($0.tool) }
        recorded.plans = recorded.plans.filter { key, _ in Tool(rawValue: key).map { tools.contains($0) } ?? false }
        recorded.heartbeats = recorded.heartbeats.filter { key, _ in Tool(rawValue: key).map { tools.contains($0) } ?? false }
        spend = spend.filter { tools.contains($0.tool) }
        browsing = browsing.filter { tools.contains($0.key) }
        if case .tool(let tool) = pane, !tools.contains(tool) { pane = .overview }
        if !settings.trackGrokBot {
            recorded.windows.removeAll { $0.tool == .cursor && $0.scope == CursorUsageAPI.grokBotScope }
            spend = spend.filter { !($0.tool == .cursor && CursorUsageAPI.isGrokBotModel($0.model)) }
        }
        updateEstimates()
    }

    private func updateEstimates() {
        estimatedAt = now
        history = ScopedEstimate.apply(to: recorded, spend: spend, prices: prices, now: now)
    }

    func refresh() {
        refreshInstalledAgents()
        refreshHookState()
        guard !isDemo else { now = Date(); return }
        Task { [engine] in await engine.refresh() }
    }

    func flush() async {
        guard !isDemo else { return }
        await engine.flush()
    }

    // MARK: Derived

    var trackedTools: [Tool] { Tool.allCases.filter { settings.isEnabled($0) && installedTools.contains($0) } }

    func forecasts(_ tool: Tool) -> [Forecast] { history.currentForecasts(for: tool, now: now) }
    var allForecasts: [Forecast] { history.currentForecasts(now: now) }
    var tightest: Forecast? { Tightest.pick(allForecasts) }
    func tightest(_ tool: Tool) -> Forecast? { Tightest.pick(forecasts(tool)) }
    func pastWeeks(_ tool: Tool, scope: String? = nil) -> [WeekBar] { PastWeeks.bars(history, tool: tool, scope: scope, now: now) }
    /// Ended windows of a limit kind, oldest first, for browsing past usage.
    func endedWindows(_ w: LimitWindow) -> [EndedWindow] {
        history.endedWindows(tool: w.tool, minutes: w.minutes, scope: w.scope, now: now)
    }

    /// The ended window a tool's card is showing, if any.
    func browsedWindow(_ tool: Tool) -> EndedWindow? {
        guard let id = browsing[tool], let w = history.windows.first(where: { $0.id == id }) else { return nil }
        return endedWindows(w).first { $0.id == id }
    }

    /// Scoped weekly limits a tool has (e.g. ["fable"]).
    func scopes(_ tool: Tool) -> [String] {
        history.kinds(for: tool, now: now).compactMap(\.scope)
    }

    // MARK: Spend

    func spendRows(tool: Tool? = nil, _ interval: DateInterval) -> [ModelSpend] {
        spend.totals(tool: tool, from: interval.start, to: interval.end)
    }

    func spendSummary(tool: Tool? = nil, _ interval: DateInterval) -> SpendSummary {
        SpendSummary(spendRows(tool: tool, interval), prices: prices)
    }

    /// API-equivalent cost of a limit window so far (hour resolution); for a scoped limit, just its models.
    /// How much of a scoped limit (Fable) a dollar of its usage takes, for the estimate.
    func calibration(_ tool: Tool, scope: String) -> ScopedEstimate.Calibration? {
        ScopedEstimate.calibration(history: recorded, spend: spend, prices: prices, tool: tool, scope: scope, now: now)
    }

    func windowSpend(_ tool: Tool, scope: String? = nil, from start: Date, to end: Date) -> SpendSummary {
        let rows = spendRows(tool: tool, DateInterval(start: start, end: max(start, min(end, now.addingTimeInterval(3600)))))
        let filtered = rows.filter { row in
            guard let scope else { return true }
            if tool == .cursor {
                switch scope {
                case "auto": return CursorUsageAPI.isAutoModel(row.model, autoModels: recorded.cursorAutoModels)
                case "other": return !CursorUsageAPI.isAutoModel(row.model, autoModels: recorded.cursorAutoModels)
                    && !CursorUsageAPI.isGrokBotModel(row.model)
                case CursorUsageAPI.grokBotScope: return CursorUsageAPI.isGrokBotModel(row.model)
                default: break
                }
            }
            return row.model.lowercased().contains(scope)
        }
        return SpendSummary(filtered, prices: prices)
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
