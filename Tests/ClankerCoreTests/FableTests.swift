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

    @Test func scopedLimitsMatchByModelAndSkipAllModels() {
        let iso = ISO8601DateFormatter()
        let reset = iso.string(from: now.addingTimeInterval(3 * 86400))
        func scoped(_ pct: Double, id: String?, name: String?, resets: String? = nil) -> [String: Any] {
            let null: (String?) -> Any = { $0.map { $0 as Any } ?? NSNull() }
            return ["kind": "weekly_scoped", "percent": pct, "resets_at": null(resets),
                    "scope": ["model": ["id": null(id), "display_name": null(name)]]]
        }
        let usage: [String: Any] = ["limits": [
            ["kind": "weekly_all", "percent": 6, "resets_at": reset],
            scoped(0, id: "claude-fable-5-1", name: nil),
            scoped(12, id: nil, name: "Fable 5", resets: reset),
            scoped(30, id: nil, name: "All models", resets: reset),
        ]]
        let samples = ClaudeParser.samples(usage: usage, at: now).filter { $0.scope != nil }
        #expect(samples.map(\.scope) == ["fable"])
        #expect(samples.first?.reading.pct == 12)
    }

    @Test func anUnusedScopedLimitReadsZeroUntilTheWeeklyReset() {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86400))
        let usage: [String: Any] = ["limits": [
            ["kind": "weekly_all", "percent": 6, "resets_at": reset],
            ["kind": "weekly_scoped", "percent": 0, "resets_at": NSNull(), "scope": ["model": ["display_name": "Fable"]]],
        ]]
        let fable = ClaudeParser.samples(usage: usage, at: now).first { $0.scope == "fable" }
        #expect(fable?.reading.pct == 0 && fable?.resetsAt == now.addingTimeInterval(3 * 86400))
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

        let k = try #require(ScopedEstimate.calibration(history: h, spend: spend, prices: prices, tool: .claude, scope: "fable", now: now)?.percentPerDollar)
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

    /// Past weekly windows, each with its latest reading after `dollars` of Fable.
    func weeks(_ readings: [(pct: Double, dollars: Double)]) -> (UsageHistory, SpendLedger) {
        var h = UsageHistory(), spend = SpendLedger()
        for (i, r) in readings.enumerated() {
            let end = now.addingTimeInterval(-Double(readings.count - 1 - i) * 7 * 86400 + 86400)
            spend.add(fableUsage(r.dollars, at: end.addingTimeInterval(-3 * 86400)))
            h.add(Sample(tool: .claude, minutes: 10080, resetsAt: end, reading: Reading(t: end.addingTimeInterval(-2 * 86400), pct: r.pct), scope: "fable"))
        }
        return (h, spend)
    }

    @Test func calibratesFromTheMedianOfRecentWeeks() throws {
        let (h, spend) = weeks([(20, 100), (90, 100), (25, 100), (30, 100)])
        let c = try #require(ScopedEstimate.calibration(history: h, spend: spend, prices: prices, tool: .claude, scope: "fable", now: now))
        #expect(abs(c.percentPerDollar - 0.275) < 1e-9 && c.earlier == nil)
    }

    @Test func followsAChangeInTheLimit() throws {
        let (h, spend) = weeks([(25, 100), (28, 100), (60, 100)])
        let c = try #require(ScopedEstimate.calibration(history: h, spend: spend, prices: prices, tool: .claude, scope: "fable", now: now))
        #expect(abs(c.percentPerDollar - 0.6) < 1e-9)
        #expect(abs((c.earlier ?? 0) - 0.265) < 1e-9)
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

    func api(expires: Date?, status: Int = 200, headers: [String: String]? = nil, calls: Calls) -> ClaudeUsageAPI {
        ClaudeUsageAPI(
            credentials: { .init(accessToken: "test-token", expiresAt: expires) },
            transport: { request in
                calls.hit()
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
                let body = try JSONSerialization.data(withJSONObject: usageJSON(at: Date()))
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
            }
        )
    }

    @Test func readsLimitsFromTheResponse() async {
        let calls = Calls()
        let response = await api(expires: Date().addingTimeInterval(3600), calls: calls).fetch()
        #expect(response.outcome == .updated(readings: 3))
        #expect(response.samples.contains { $0.scope == "fable" && $0.reading.pct == 49 })
    }

    @Test func anExpiredLoginIsLeftAlone() async {
        let calls = Calls()
        let response = await api(expires: Date().addingTimeInterval(-60), calls: calls).fetch()
        #expect(response.outcome == .loginExpired && response.samples.isEmpty && calls.count == 0)
    }

    @Test func errorsBackOff() async {
        let calls = Calls()
        let limited = await api(expires: nil, status: 429, calls: calls).fetch()
        #expect(limited.outcome == .failed(status: 429))
        #expect(ClaudeUsageAPI.backoff(after: limited) == 3600)
        let failed = await api(expires: nil, status: 500, calls: calls).fetch()
        #expect(ClaudeUsageAPI.backoff(after: failed) == 3600)
        #expect(ClaudeUsageAPI.backoff(after: .init(outcome: .updated(readings: 1))) == nil)
    }

    @Test func rateLimitsWaitAsLongAsTheServerAsks() async {
        let calls = Calls()
        let response = await api(expires: nil, status: 429, headers: ["Retry-After": "5400"], calls: calls).fetch()
        #expect(response.retryAfter == 5400 && ClaudeUsageAPI.backoff(after: response) == 5400)
        #expect(ClaudeUsageAPI.retryAfter("Thu, 01 Oct 2026 12:00:00 GMT", now: ISOTime.parse("2026-10-01T11:00:00Z")!) == 3600)
        #expect(ClaudeUsageAPI.backoff(after: .init(outcome: .failed(status: 429), retryAfter: 9e9)) == 86400)
    }

    @Test func credentialsNeedAClaudeLogin() {
        let login = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1790000000000}}"#
        #expect(ClaudeUsageAPI.credentials(from: Data(login.utf8))?.expiresAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(ClaudeUsageAPI.credentials(from: Data(#"{"mcpOAuth":{"x":{}}}"#.utf8)) == nil)
    }

    @Test func checksAtMostEveryThirtyMinutesAndOnlyWhenUseful() {
        let m = 60.0
        // Times in minutes ago; activity is reported by the status line at the same moment.
        func should(lastCheck: Double?, activity: Double?, scoped: Double?, backoff: Double? = nil) -> Bool {
            ClaudeUsageAPI.shouldCheck(now: now, lastCheck: lastCheck.map { now.addingTimeInterval(-$0 * m) },
                                       lastResponse: activity.map { now.addingTimeInterval(-$0 * m) },
                                       lastStatusLine: activity.map { now.addingTimeInterval(-$0 * m) },
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

    /// Desktop app, IDE and Agent SDK sessions don't run the status line, and a terminal session doesn't
    /// re-run it while subagents work, so their responses go unreported until the next check.
    @Test func checksEveryFiveMinutesWhileResponsesGoUnreported() {
        let m = 60.0
        func should(lastCheck: Double, response: Double?, statusLine: Double?, backoff: Double? = nil) -> Bool {
            ClaudeUsageAPI.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-lastCheck * m),
                                       lastResponse: response.map { now.addingTimeInterval(-$0 * m) },
                                       lastStatusLine: statusLine.map { now.addingTimeInterval(-$0 * m) },
                                       newestScopedReading: now, backoffUntil: backoff.map { now.addingTimeInterval($0 * m) })
        }
        // No status line at all (e.g. only the desktop app is used).
        #expect(should(lastCheck: 6, response: 1, statusLine: nil))
        #expect(!should(lastCheck: 4, response: 1, statusLine: nil))
        // Subagents answering while the main session's status line last ran 20 minutes ago.
        #expect(should(lastCheck: 6, response: 0.5, statusLine: 20))
        // The status line kept up (within its grace period): back to every 30 minutes.
        #expect(!should(lastCheck: 6, response: 1, statusLine: 1.5))
        #expect(should(lastCheck: 31, response: 1, statusLine: 1.5))
        // Idle for over 30 minutes, or backing off after errors: no quick checks.
        #expect(!should(lastCheck: 6, response: 40, statusLine: nil))
        #expect(!should(lastCheck: 6, response: 1, statusLine: nil, backoff: 30))
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
