import Foundation
import Testing
@testable import ClankerCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

/// The shape of Claude Code's usage response (cache in ~/.claude.json, or /api/oauth/usage).
private func usageJSON(session: Double = 5, weekly: Double = 6, fable: Double = 49, at t: Date = now) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    return [
        "five_hour": ["utilization": session, "resets_at": iso.string(from: t.addingTimeInterval(3 * 3600))],
        "seven_day": ["utilization": weekly, "resets_at": iso.string(from: t.addingTimeInterval(3 * 86400))],
        "seven_day_opus": NSNull(),
        "limits": [
            ["kind": "session", "group": "session", "percent": session, "resets_at": iso.string(from: t.addingTimeInterval(3 * 3600)), "scope": NSNull()],
            ["kind": "weekly_all", "group": "weekly", "percent": weekly, "resets_at": iso.string(from: t.addingTimeInterval(3 * 86400)), "scope": NSNull()],
            ["kind": "weekly_scoped", "group": "weekly", "percent": fable, "resets_at": iso.string(from: t.addingTimeInterval(3 * 86400)),
             "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]],
        ],
    ]
}

@Suite struct ScopedLimitTests {
    @Test func parsesTheLimitsListIncludingFable() {
        let samples = ClaudeParser.samples(usage: usageJSON(), at: now)
        #expect(samples.map(\.minutes) == [300, 10080, 10080])
        #expect(samples.map(\.scope) == [nil, nil, "fable"])
        #expect(samples.map(\.reading.pct) == [5, 6, 49])
    }

    @Test func statusLineModelKeysBecomeScopes() {
        let samples = ClaudeParser.samples(rateLimits: ["seven_day_opus": ["used_percentage": 12, "resets_at": now.timeIntervalSince1970 + 86400]],
                                           at: now, percentKey: "used_percentage")
        #expect(samples.map(\.scope) == ["opus"])
    }

    @Test func olderHistoryWithoutScopesStillLoads() throws {
        let json = #"{"schemaVersion":1,"plans":{},"heartbeats":{},"windows":[{"tool":"claude","minutes":10080,"resetsAt":1790200000,"lastSeen":1789999000,"points":[{"t":1789999000,"pct":12}]}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let h = try decoder.decode(UsageHistory.self, from: Data(json.utf8))
        #expect(h.windows.first?.scope == nil && h.windows.first?.points.first?.isEstimated == false)
    }

    @Test func fableIsItsOwnLimitNextToTheSharedWeekly() {
        var h = UsageHistory()
        h.add(contentsOf: ClaudeParser.samples(usage: usageJSON(), at: now))
        #expect(h.windows.count == 3)
        let kinds = h.currentForecasts(for: .claude, now: now).map { $0.window.label }
        #expect(kinds == ["5-hour", "Weekly", "Fable weekly"])
        let fable = h.currentForecasts(for: .claude, now: now).last
        #expect(fable?.window.id.hasPrefix("claude.fable.10080.") == true)
        #expect(fable?.window.shortLabel == "Fable")
    }
}

@Suite struct ScopedEstimateTests {
    let prices = PriceTable(models: ["claude-fable-5-1": ModelPrice(input: 1e-5, output: 5e-5)])

    /// $1 of Fable is 100,000 input tokens at $10 per million.
    func fableUsage(_ dollars: Double, at t: Date) -> UsageEvent {
        UsageEvent(tool: .claude, model: "claude-fable-5-1", t: t, tokens: TokenCounts(input: Int(dollars * 100_000)), dedupeKey: 0)
    }

    func history(fable: [(Date, Double)], resetsAt: Date = now.addingTimeInterval(3 * 86400)) -> UsageHistory {
        var h = UsageHistory()
        for (t, pct) in fable { h.add(Sample(tool: .claude, minutes: 10080, resetsAt: resetsAt, reading: Reading(t: t, pct: pct), scope: "fable")) }
        return h
    }

    @Test func continuesFromTheLastReadingWithFableUsage() throws {
        var spend = SpendLedger()
        spend.add(fableUsage(175, at: now.addingTimeInterval(-3 * 86400)))
        spend.add(fableUsage(17.9, at: now.addingTimeInterval(-3600)))
        let h = history(fable: [(now.addingTimeInterval(-2 * 3600), 49)])

        let k = try #require(ScopedEstimate.percentPerDollar(history: h, spend: spend, prices: prices, tool: .claude, scope: "fable", now: now))
        #expect(abs(k - 0.28) < 1e-9)
        let f = try #require(ScopedEstimate.apply(to: h, spend: spend, prices: prices, now: now).currentForecasts(for: .claude, now: now).first)
        #expect(f.isEstimated)
        #expect(abs(f.used - (49 + 0.28 * 17.9)) < 0.01)
        #expect(f.lastReported?.pct == 49)
    }

    @Test func aReportedReadingReplacesTheEstimate() throws {
        var spend = SpendLedger()
        spend.add(fableUsage(175, at: now.addingTimeInterval(-3 * 86400)))
        spend.add(fableUsage(17.9, at: now.addingTimeInterval(-3600)))
        let h = history(fable: [(now.addingTimeInterval(-2 * 3600), 49), (now.addingTimeInterval(-600), 57)])
        let f = try #require(ScopedEstimate.apply(to: h, spend: spend, prices: prices, now: now).currentForecasts(for: .claude, now: now).first)
        #expect(!f.isEstimated && f.used == 57)
    }

    @Test func afterAResetTheNextWindowIsEstimatedFromZero() throws {
        var spend = SpendLedger()
        spend.add(fableUsage(175, at: now.addingTimeInterval(-7.5 * 86400)))
        spend.add(fableUsage(10, at: now.addingTimeInterval(-3600)))
        var h = history(fable: [(now.addingTimeInterval(-7 * 86400), 49)], resetsAt: now.addingTimeInterval(-86400))
        // The shared weekly window that's running now.
        h.add(Sample(tool: .claude, minutes: 10080, resetsAt: now.addingTimeInterval(6 * 86400), reading: Reading(t: now.addingTimeInterval(-7200), pct: 4)))

        let estimated = ScopedEstimate.apply(to: h, spend: spend, prices: prices, now: now)
        let fable = try #require(estimated.currentForecasts(for: .claude, now: now).first { $0.window.scope == "fable" })
        #expect(fable.window.resetsAt == now.addingTimeInterval(6 * 86400))
        #expect(fable.isEstimated && abs(fable.used - 2.8) < 0.01)
        #expect(estimated.windows.count == h.windows.count + 1)
    }

    @Test func noEstimateWithoutACalibratingReading() {
        var spend = SpendLedger()
        spend.add(fableUsage(1, at: now.addingTimeInterval(-3600)))
        let h = history(fable: [(now.addingTimeInterval(-2 * 3600), 1)])
        #expect(ScopedEstimate.apply(to: h, spend: spend, prices: prices, now: now) == h)
    }
}

@Suite struct UsageCheckTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func hit() { lock.withLock { n += 1 } }
    }

    func api(expires: Date?, status: Int = 200, calls: Calls) -> ClaudeUsageAPI {
        ClaudeUsageAPI(
            credentials: { .init(accessToken: "test-token", expiresAt: expires) },
            transport: { request in
                calls.hit()
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
                let body = try JSONSerialization.data(withJSONObject: usageJSON(at: Date()))
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        )
    }

    @Test func readsLimitsFromTheResponse() async {
        let calls = Calls()
        let (outcome, samples) = await api(expires: Date().addingTimeInterval(3600), calls: calls).fetch()
        #expect(outcome == .updated(readings: 3))
        #expect(samples.contains { $0.scope == "fable" && $0.reading.pct == 49 })
    }

    @Test func anExpiredLoginIsLeftAlone() async {
        let calls = Calls()
        let (outcome, samples) = await api(expires: Date().addingTimeInterval(-60), calls: calls).fetch()
        #expect(outcome == .loginExpired && samples.isEmpty && calls.count == 0)
    }

    @Test func errorsBackOff() async {
        let calls = Calls()
        let (outcome, _) = await api(expires: nil, status: 429, calls: calls).fetch()
        #expect(outcome == .failed(status: 429))
        #expect(ClaudeUsageAPI.backoff(after: outcome) == 7200)
        #expect(ClaudeUsageAPI.backoff(after: .updated(readings: 1)) == nil)
    }

    @Test func checksAtMostEveryThirtyMinutesAndOnlyWhenUseful() {
        let m = 60.0
        func should(lastCheck: Double?, activity: Double?, scoped: Double?, backoff: Double? = nil) -> Bool {
            ClaudeUsageAPI.shouldCheck(now: now, lastCheck: lastCheck.map { now.addingTimeInterval(-$0 * m) },
                                       lastClaudeActivity: activity.map { now.addingTimeInterval(-$0 * m) },
                                       newestScopedReading: scoped.map { now.addingTimeInterval(-$0 * m) },
                                       backoffUntil: backoff.map { now.addingTimeInterval($0 * m) })
        }
        #expect(!should(lastCheck: 10, activity: 1, scoped: 600))
        #expect(should(lastCheck: 40, activity: 5, scoped: 60))
        #expect(!should(lastCheck: 40, activity: 120, scoped: 60))
        #expect(should(lastCheck: 40, activity: 120, scoped: 7 * 60))
        #expect(should(lastCheck: nil, activity: nil, scoped: nil))
        #expect(!should(lastCheck: nil, activity: 1, scoped: nil, backoff: 30))
    }

    @Test func theEngineChecksOnceWhenEnabled() async throws {
        let root = try tempDir()
        let paths = AppPaths(support: root.appending(path: "data"), codexHome: root.appending(path: "codex"),
                             claudeHome: root.appending(path: "claude"), claudeJSON: root.appending(path: "none.json"))
        let calls = Calls()
        let engine = Engine(paths: paths, downloadsPrices: false, usageAPI: api(expires: nil, calls: calls))
        await engine.start(watch: false)
        #expect(calls.count == 0)
        await engine.setUsageChecks(enabled: true)
        await engine.checkUsageIfDue()
        #expect(calls.count == 1)
        let history = await engine.currentHistory()
        #expect(history.windows.contains { $0.scope == "fable" })
    }
}
