import ClankerCore
import Foundation
import Testing
@testable import ClankerTracker

@Suite @MainActor struct TrackingTests {
    @Test(arguments: Tool.allCases) func providerSwitchPersistsAndFiltersCachedData(tool: Tool) throws {
        let suite = "ClankerTrackerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, settings: AppSettings(defaults: defaults))
        model.start()
        let original = model.history.windows.filter { $0.tool == tool }
        #expect(!original.isEmpty)
        model.setProviderEnabled(false, for: tool)
        #expect(!model.trackedTools.contains(tool))
        #expect(model.history.windows.allSatisfy { $0.tool != tool })
        #expect(model.spend.totals(tool: tool, from: .distantPast, to: .distantFuture).isEmpty)
        #expect(model.allForecasts.allSatisfy { $0.tool != tool })
        let restarted = AppModel(demo: true, settings: AppSettings(defaults: defaults))
        restarted.start()
        #expect(!restarted.trackedTools.contains(tool))
        #expect(restarted.forecasts(tool).isEmpty)
        model.setProviderEnabled(true, for: tool)
        #expect(model.history.windows.filter { $0.tool == tool } == original)
    }

    @Test func installationChangesHideAndRestoreSavedData() throws {
        let suite = "ClankerTrackerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var agents: Set<Tool> = [.codex]
        let model = AppModel(demo: true, settings: AppSettings(defaults: defaults), detectAgents: { agents })
        model.start()
        #expect(model.trackedTools == [.codex])
        #expect(model.history.windows.allSatisfy { $0.tool == .codex })
        agents = Set(Tool.allCases)
        model.refreshInstalledAgents()
        #expect(model.trackedTools == Tool.allCases)
        #expect(!model.forecasts(.cursor).isEmpty)
        agents = []
        model.pane = .tool(.codex)
        model.refreshInstalledAgents()
        #expect(model.trackedTools.isEmpty)
        #expect(model.allForecasts.isEmpty)
        #expect(model.spend.totals(from: .distantPast, to: .distantFuture).isEmpty)
        #expect(model.pane == .overview)
    }

    @Test func disablingRemoteChecksKeepsEnabledProviderVisible() throws {
        let suite = "ClankerTrackerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, settings: AppSettings(defaults: defaults))
        model.start()
        model.setCursorChecks(false)
        model.setUsageChecks(false)
        #expect(model.trackedTools == Tool.allCases)
        #expect(!model.forecasts(.cursor).isEmpty)
        #expect(!model.forecasts(.claude).isEmpty)
        let restarted = AppModel(demo: true, settings: AppSettings(defaults: defaults))
        restarted.start()
        #expect(restarted.trackedTools == Tool.allCases)
    }

    @Test func disabledCursorHidesCachedUsageAndReenablingRestoresIt() throws {
        let suite = "ClankerTrackerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, settings: AppSettings(defaults: defaults))
        model.start()
        let cursorWindows = model.history.windows.filter { $0.tool == .cursor }
        let interval = DateInterval(start: model.now.addingTimeInterval(-30 * 86400), end: model.now)
        let cursorSpend = model.spendSummary(tool: .cursor, interval).usd
        #expect(!cursorWindows.isEmpty)
        #expect(cursorSpend > 0)

        model.pane = .tool(.cursor)
        model.browsing[.cursor] = cursorWindows.first?.id
        model.setProviderEnabled(false, for: .cursor)
        #expect(model.trackedTools == [.claude, .codex])
        #expect(model.forecasts(.cursor).isEmpty)
        #expect(!model.allForecasts.contains { $0.tool == .cursor })
        #expect(model.history.windows.allSatisfy { $0.tool != .cursor })
        #expect(model.spendRows(tool: .cursor, interval).isEmpty)
        #expect(model.pane == .overview)
        #expect(model.browsing[.cursor] == nil)
        #expect(!model.forecasts(.claude).isEmpty)
        #expect(!model.forecasts(.codex).isEmpty)

        model.setProviderEnabled(true, for: .cursor)
        #expect(model.trackedTools == Tool.allCases)
        #expect(model.history.windows.filter { $0.tool == .cursor } == cursorWindows)
        #expect(model.spendSummary(tool: .cursor, interval).usd == cursorSpend)
    }

    @Test func startupWithCursorDisabledHidesSavedReadings() throws {
        let suite = "ClankerTrackerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "checkCursorUsage")
        defaults.set(true, forKey: "trackGrokBot")
        let model = AppModel(demo: true, settings: AppSettings(defaults: defaults))
        model.start()
        #expect(model.forecasts(.cursor).isEmpty)
        #expect(model.spend.totals(tool: .cursor, from: .distantPast, to: .distantFuture).isEmpty)
        model.setTrackGrokBot(false)
        #expect(model.forecasts(.cursor).isEmpty)
    }
}
