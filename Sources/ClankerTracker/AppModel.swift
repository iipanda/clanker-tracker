import ClankerCore
import Foundation
import Observation

enum Pane: Hashable {
    case overview
    case tool(Tool)
    case settings
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
    private(set) var hasLoaded = false
    private(set) var hookState: StatusLineHook.State = .noScript
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
            hasLoaded = true
            return
        }
        tasks.append(Task { [weak self, engine] in
            for await update in engine.updates {
                guard let self else { return }
                self.history = update.history
                self.backfill = update.backfill
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
    func plan(_ tool: Tool) -> String? { history.plan(for: tool).map { "\($0.capitalized) plan" } }
    func lastSeen(_ tool: Tool) -> Date? { history.lastSeen(tool) }

    var lastReading: Date? { Tool.allCases.compactMap { lastSeen($0) }.max() }

    var updatedText: String {
        if isDemo { return "Updated 38s ago · sample data" }
        guard let last = lastReading else { return hasLoaded ? "No readings yet" : "Loading…" }
        return "Updated \(Fmt.ago(now.timeIntervalSince(last)))"
    }

    // MARK: Claude collector

    var claudeScript: URL? {
        switch hookState {
        case .installed(let u), .notInstalled(let u), .anchorMissing(let u): u
        case .noScript: nil
        }
    }

    func refreshHookState() {
        hookState = StatusLineHook.state(settings: engine.paths.claudeSettings)
    }

    func installHook() {
        guard case .notInstalled(let url) = hookState else { return }
        do {
            try FileManager.default.createDirectory(at: engine.paths.claudeDir, withIntermediateDirectories: true)
            try StatusLineHook.install(script: url)
            hookError = nil
        } catch {
            hookError = "Couldn't update \(url.lastPathComponent): \(error.localizedDescription)"
        }
        refreshHookState()
    }

    func uninstallHook() {
        guard case .installed(let url) = hookState else { return }
        do {
            try StatusLineHook.uninstall(script: url)
            hookError = nil
        } catch {
            hookError = "Couldn't update \(url.lastPathComponent): \(error.localizedDescription)"
        }
        refreshHookState()
    }
}
