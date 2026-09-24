import Foundation
import Testing
@testable import ClankerCore

@Suite struct PricingTests {
    let opus = ModelPrice(input: 5e-6, output: 25e-6, cacheWrite5m: 6.25e-6, cacheWrite1h: 10e-6, cacheRead: 0.5e-6)

    @Test func costAddsEveryKindOfToken() {
        let t = TokenCounts(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(opus.cost(t) - (5 + 6.25 + 10 + 0.5 + 25)) < 1e-9)
    }

    @Test func missingCacheRatesUseTheUsualMultipliers() {
        let p = ModelPrice(input: 2e-6, output: 8e-6)
        let t = TokenCounts(cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(p.cost(t) - (2.5 + 4 + 0.2)) < 1e-9)
    }

    @Test func longContextRatesApplyFromTheThreshold() {
        let sol = ModelPrice(input: 4e-6, output: 20e-6, cacheRead: 0.4e-6, longContextFrom: 272_000,
                             longInput: 8e-6, longOutput: 30e-6, longCacheRead: 0.8e-6)
        let t = TokenCounts(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(sol.cost(t, context: .over200k) - 24.4) < 1e-9)
        #expect(abs(sol.cost(t, context: .over272k) - 38.8) < 1e-9)
        #expect(ContextSize(promptTokens: 271_999) == .over200k)
        #expect(ContextSize(promptTokens: 272_000) == .over272k)
    }

    @Test func lookupToleratesSuffixesPrefixesAndAliases() {
        let table = PriceTable(models: ["claude-opus-5": opus, "claude-haiku-4-5-20251001": opus, "gpt-5.6-luna": opus])
        #expect(table.price(for: "claude-opus-5[1m]") == opus)
        #expect(table.price(for: "anthropic/claude-opus-5") == opus)
        #expect(table.price(for: "claude-haiku-4-5") == opus)
        #expect(table.price(for: "codex-auto-review") == opus)
        #expect(table.price(for: "gpt-99") == nil)
    }

    @Test func parsesLiteLLMKeepingAnthropicAndOpenAI() throws {
        let json = #"""
        {"sample_spec": {"note": "ignored"},
         "claude-opus-5": {"litellm_provider": "anthropic", "input_cost_per_token": 5e-06, "output_cost_per_token": 2.5e-05,
                           "cache_creation_input_token_cost": 6.25e-06, "cache_creation_input_token_cost_above_1hr": 1e-05,
                           "cache_read_input_token_cost": 5e-07},
         "gpt-5.6-sol": {"litellm_provider": "openai", "input_cost_per_token": 4e-06, "output_cost_per_token": 2e-05,
                         "cache_read_input_token_cost": 4e-07, "input_cost_per_token_above_272k_tokens": 8e-06,
                         "output_cost_per_token_above_272k_tokens": 3e-05, "cache_read_input_token_cost_above_272k_tokens": 8e-07},
         "gemini-3-pro": {"litellm_provider": "vertex_ai", "input_cost_per_token": 1e-06, "output_cost_per_token": 1e-05}}
        """#
        let table = try #require(PriceTable.parseLiteLLM(Data(json.utf8)))
        #expect(Set(table.models.keys) == ["claude-opus-5", "gpt-5.6-sol"])
        #expect(table.models["claude-opus-5"] == opus)
        let sol = try #require(table.models["gpt-5.6-sol"])
        #expect(sol.longContextFrom == 272_000 && sol.longInput == 8e-6 && sol.longCacheRead == 8e-7)
    }

    @Test func bundledPricesCoverTheCurrentModels() {
        for model in ["claude-opus-5", "claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5", "claude-haiku-4-5-20251001", "gpt-5.6-sol", "gpt-6-astra"] {
            #expect(PriceTable.bundled.price(for: model) != nil, "\(model)")
        }
        #expect(PriceTable.bundled.price(for: "claude-fable-5-1")?.cacheRead == 2.5e-7)
    }

    @Test func fetchedPricesOverrideBundled() {
        let newer = PriceTable(models: ["claude-opus-5": ModelPrice(input: 1e-6, output: 1e-6)], fetchedAt: Date(timeIntervalSince1970: 1))
        let merged = PriceTable(models: ["claude-opus-5": opus, "claude-sonnet-5": opus]).overlaid(with: newer)
        #expect(merged.models["claude-opus-5"]?.input == 1e-6)
        #expect(merged.models["claude-sonnet-5"] == opus)
        #expect(merged.fetchedAt == Date(timeIntervalSince1970: 1))
    }
}

@Suite struct LedgerTests {
    func event(_ model: String, hour: Int, input: Int, context: ContextSize = .standard, tool: Tool = .claude) -> UsageEvent {
        UsageEvent(tool: tool, model: model, t: Date(timeIntervalSince1970: TimeInterval(hour) * 3600 + 60),
                   tokens: TokenCounts(input: input), context: context, dedupeKey: UInt64(hour))
    }

    @Test func sumsByPeriodAndKeepsPromptSizesApart() throws {
        var ledger = SpendLedger()
        ledger.add(event("claude-opus-5", hour: 10, input: 100))
        ledger.add(event("claude-opus-5", hour: 10, input: 50))
        ledger.add(event("claude-opus-5", hour: 11, input: 10, context: .over272k))
        ledger.add(event("gpt-5.6-sol", hour: 12, input: 7, tool: .codex))
        #expect(ledger.entries.count == 3)

        let from = Date(timeIntervalSince1970: 10 * 3600), to = Date(timeIntervalSince1970: 12 * 3600)
        let rows = ledger.totals(from: from, to: to)
        #expect(rows.count == 1)
        let opus = try #require(rows.first)
        #expect(opus.tokens.input == 160)
        #expect(opus.byContext[.over272k]?.input == 10)
        #expect(ledger.totals(tool: .codex, from: from, to: to.addingTimeInterval(3600)).map(\.tokens.input) == [7])
    }

    @Test func summaryReportsUnpricedTokens() {
        var ledger = SpendLedger()
        ledger.add(event("claude-opus-5", hour: 1, input: 1_000_000))
        ledger.add(event("mystery-model", hour: 1, input: 42))
        let rows = ledger.totals(from: .distantPast, to: .distantFuture)
        let s = SpendSummary(rows, prices: PriceTable(models: ["claude-opus-5": ModelPrice(input: 5e-6, output: 25e-6)]))
        #expect(abs(s.usd - 5) < 1e-9)
        #expect(s.unpricedTokens == 42)
    }

    @Test func roundTripsThroughJSON() throws {
        var ledger = SpendLedger()
        ledger.add(event("claude-opus-5", hour: 3, input: 5))
        let data = try JSONEncoder().encode(ledger)
        var back = try JSONDecoder().decode(SpendLedger.self, from: data)
        #expect(back == ledger)
        back.add(event("claude-opus-5", hour: 3, input: 5))
        #expect(back.entries.count == 1 && back.entries[0].tokens.input == 10)
    }
}

@Suite struct UsageParserTests {
    static let claudeLines = [
        #"{"type":"user","timestamp":"2026-09-20T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"assistant","timestamp":"2026-09-20T10:00:05.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":3,"cache_creation_input_tokens":300,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"output_tokens":6000,"speed":"standard"}}}"#,
        #"{"type":"assistant","timestamp":"2026-09-20T10:00:06.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":3,"cache_creation_input_tokens":300,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"output_tokens":3}}}"#,
        #"{"type":"assistant","timestamp":"2026-09-20T10:01:00.000Z","requestId":"req_2","message":{"id":"msg_2","model":"claude-opus-5[1m]","usage":{"input_tokens":10,"cache_read_input_tokens":250000,"output_tokens":20,"speed":"fast"}}}"#,
        #"{"type":"assistant","timestamp":"2026-09-20T10:02:00.000Z","message":{"id":"msg_3","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
    ]

    @Test func claudeTranscriptLines() {
        let text = Self.claudeLines.joined(separator: "\n") + "\n"
        var events: [UsageEvent] = []
        _ = Array(text.utf8).withUnsafeBytes { ClaudeUsageParser.scan($0, into: &events) }
        #expect(events.count == 3)
        #expect(events[0].tokens == TokenCounts(input: 3, cacheWrite5m: 100, cacheWrite1h: 200, cacheRead: 1000, output: 6000))
        #expect(events[0].dedupeKey == events[1].dedupeKey)
        #expect(events[2].fast && events[2].context == .over200k)
    }

    static let codexLines = [
        #"{"timestamp":"2026-09-20T10:00:00.000Z","type":"session_meta","payload":{"id":"t1"}}"#,
        #"{"timestamp":"2026-09-20T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"2026-09-20T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"reasoning_output_tokens":40,"total_tokens":1100}},"rate_limits":null}}"#,
        #"{"timestamp":"2026-09-20T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"total_tokens":1100}},"rate_limits":null}}"#,
        #"{"timestamp":"2026-09-20T10:00:04.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6-astra"}}}"#,
        #"{"timestamp":"2026-09-20T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":301600},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":0,"output_tokens":500,"total_tokens":300500}},"rate_limits":null}}"#,
    ]

    @Test func codexSessionLines() {
        let text = Self.codexLines.joined(separator: "\n") + "\n"
        var context = CodexContext(), records: [CodexParser.Record] = [], events: [UsageEvent] = []
        _ = Array(text.utf8).withUnsafeBytes { CodexUsageParser.scan($0, context: &context, records: &records, events: &events) }
        #expect(events.map(\.model) == ["gpt-5.6-sol", "gpt-6-astra"])
        #expect(events[0].tokens == TokenCounts(input: 200, cacheRead: 800, output: 100, reasoning: 40))
        #expect(events[1].context == .over272k)
        #expect(context.model == "gpt-6-astra" && context.lastTotal == 301600 && context.forkedAt == nil)
    }

    @Test func multiNeedleScanKeepsFileOrder() {
        let text = "b 1\na 2\nnone\nb 3\na 4\npartial a"
        var seen: [String] = []
        let used = Array(text.utf8).withUnsafeBytes { buf in
            LineScanner.scan(buf, needles: [Array("a ".utf8), Array("b ".utf8)]) { line, which in
                seen.append("\(which):" + String(decoding: line, as: UTF8.self))
            }
        }
        #expect(seen == ["1:b 1", "0:a 2", "1:b 3", "0:a 4"])
        #expect(used == text.utf8.count - "partial a".utf8.count)
    }
}

@Suite struct EngineSpendTests {
    /// A Codex parent session, a fork that starts with a copy of it, and a Claude transcript with a
    /// repeated response: each response is counted once, at its own time.
    @Test func countsEveryResponseOnce() async throws {
        let root = try tempDir()
        let codex = root.appending(path: "codex/sessions/2026/09/20")
        let claude = root.appending(path: "claude/projects/demo")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        func token(_ ts: String, total: Int, input: Int, output: Int) -> String {
            #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output),"total_tokens":\#(input + output)}},"rate_limits":null}}"#
        }
        let parent = [
            #"{"timestamp":"2026-09-20T10:00:00.000Z","type":"session_meta","payload":{"id":"p"}}"#,
            #"{"timestamp":"2026-09-20T10:00:00.500Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            token("2026-09-20T10:00:01.000Z", total: 110, input: 100, output: 10),
            token("2026-09-20T10:00:02.000Z", total: 330, input: 200, output: 20),
        ]
        let fork = [
            #"{"timestamp":"2026-09-20T11:00:00.000Z","type":"session_meta","payload":{"id":"f","forked_from_id":"p"}}"#,
            #"{"timestamp":"2026-09-20T11:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            // Copied history: one exact copy of the parent's response, one copy with no original on disk.
            token("2026-09-20T11:00:00.000Z", total: 330, input: 200, output: 20),
            token("2026-09-20T11:00:00.000Z", total: 440, input: 100, output: 10),
            // The fork's own work.
            token("2026-09-20T11:05:00.000Z", total: 1000, input: 500, output: 60),
        ]
        try (parent.joined(separator: "\n") + "\n").write(to: codex.appending(path: "rollout-2026-09-20T10-00-00-p.jsonl"), atomically: true, encoding: .utf8)
        try (fork.joined(separator: "\n") + "\n").write(to: codex.appending(path: "rollout-2026-09-20T11-00-00-f.jsonl"), atomically: true, encoding: .utf8)
        try (UsageParserTests.claudeLines.joined(separator: "\n") + "\n").write(to: claude.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)

        let paths = AppPaths(support: root.appending(path: "data"), codexHome: root.appending(path: "codex"),
                             claudeHome: root.appending(path: "claude"), claudeJSON: root.appending(path: "none.json"))
        let engine = Engine(paths: paths, downloadsPrices: false)
        await engine.start(watch: false)
        let spend = await engine.currentSpend()

        let codexTokens = spend.totals(tool: .codex, from: .distantPast, to: .distantFuture).map(\.tokens)
        #expect(codexTokens.map(\.input) == [800])
        #expect(codexTokens.map(\.output) == [90])
        let claudeRows = spend.totals(tool: .claude, from: .distantPast, to: .distantFuture)
        #expect(claudeRows.map(\.tokens.output).reduce(0, +) == 6020)
        #expect(claudeRows.count == 2)

        // Reading again changes nothing.
        await engine.refresh()
        #expect(await engine.currentSpend() == spend)
    }
}

@Suite struct EstimatorTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func seriesSpreadsJumpsAfterGaps() {
        let w = LimitWindow(tool: .codex, minutes: 10080, resetsAt: start.addingTimeInterval(7 * 86400),
                            points: [Reading(t: start.addingTimeInterval(3600 * 10), pct: 30)])
        let series = WindowSeries(w, end: start.addingTimeInterval(24 * 3600))
        #expect(series.increments.count == 24)
        #expect(abs(series.increments.reduce(0, +) - 30) < 1e-9)
        #expect(series.increments[7...9].allSatisfy { abs($0 - 10) < 1e-9 })
    }

    @Test func projectionRunoutAndCap() {
        let p = Projection(now: start, used: 90, step: 3600, increments: [2, 4])
        #expect(p.value(at: start.addingTimeInterval(3600)) == 92)
        #expect(p.value(at: start.addingTimeInterval(3 * 3600)) == 100)
        #expect(p.runout(before: start.addingTimeInterval(86400)) == start.addingTimeInterval(3600 + 2 * 3600))
        #expect(p.runout(before: start.addingTimeInterval(3600)) == nil)
    }

    @Test func backtestScoresAPerfectEstimator() {
        // A steady 1%/h window: linear pace over the last hour is exact.
        var h = UsageHistory()
        let reset = start.addingTimeInterval(7 * 86400)
        for hour in 1...100 {
            h.add(Sample(tool: .codex, minutes: 10080, resetsAt: reset, reading: Reading(t: start.addingTimeInterval(Double(hour) * 3600), pct: Double(hour))))
        }
        let score = Backtest(history: h, tool: .codex, minutes: 10080, config: .weekly).run(LinearPace(lookback: 3600))
        #expect(score.horizons.allSatisfy { $0.samples > 0 && $0.mae < 1e-6 })
        #expect(score.truePositives > 0 && score.falsePositives == 0)
    }
}

@Suite struct FirstWindowTests {
    /// A first window with all its use in the last few hours: with nothing else to learn from, the
    /// forecast keeps that use instead of expecting almost none.
    @Test func firstWindowLearnsFromItsRecentUse() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let start = now.addingTimeInterval(-40 * 3600)
        let w = LimitWindow(tool: .claude, minutes: 10080, resetsAt: start.addingTimeInterval(7 * 86400),
                            points: [Reading(t: now.addingTimeInterval(-5 * 3600), pct: 1), Reading(t: now.addingTimeInterval(-3600), pct: 5)])
        let f = Forecast(w, heartbeat: now, now: now)
        #expect(f.learnedFrom == 0)
        #expect(f.projected > 10)
    }
}

@Suite struct RetentionTests {
    struct Setup {
        let root: URL
        let paths: AppPaths
        var codex: URL { root.appending(path: "codex/sessions/2026") }
        var claude: URL { root.appending(path: "claude/projects/demo") }

        init() throws {
            root = try tempDir()
            paths = AppPaths(support: root.appending(path: "data"), codexHome: root.appending(path: "codex"),
                             claudeHome: root.appending(path: "claude"), claudeJSON: root.appending(path: "none.json"))
            try FileManager.default.createDirectory(at: root.appending(path: "codex/sessions/2026"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appending(path: "claude/projects/demo"), withIntermediateDirectories: true)
        }

        func codexLog(_ name: String, _ ts: String, total: Int, input: Int) throws {
            let lines = [
                #"{"timestamp":"\#(ts)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0,"total_tokens":\#(input)}},"rate_limits":null}}"#,
            ]
            try (lines.joined(separator: "\n") + "\n").write(to: codex.appending(path: name), atomically: true, encoding: .utf8)
        }

        func claudeLog(_ name: String, _ ts: String, id: String, output: Int) throws {
            let line = #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r\#(id)","message":{"id":"m\#(id)","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
            try (line + "\n").write(to: claude.appending(path: name), atomically: true, encoding: .utf8)
        }

        func run() async -> SpendLedger {
            let engine = Engine(paths: paths, downloadsPrices: false)
            await engine.start(watch: false)
            await engine.flush()
            return await engine.currentSpend()
        }

        func outputs(_ ledger: SpendLedger) -> [Int] {
            ledger.entries.sorted { $0.hour < $1.hour }.map { $0.tokens.output + $0.tokens.input }
        }
    }

    @Test func spendSurvivesDeletedLogsAndAReRead() async throws {
        let s = try Setup()
        try s.codexLog("rollout-2026-01-10T10-00-00-a.jsonl", "2026-01-10T10:00:00.000Z", total: 100, input: 100)
        try s.codexLog("rollout-2026-09-20T10-00-00-b.jsonl", "2026-09-20T10:00:00.000Z", total: 200, input: 200)
        try s.claudeLog("old.jsonl", "2026-01-11T10:00:00.000Z", id: "1", output: 10)
        try s.claudeLog("new.jsonl", "2026-09-21T10:00:00.000Z", id: "2", output: 20)
        let first = await s.run()
        #expect(first.entries.count == 4)

        // Re-reading unchanged logs from scratch gives the same ledger (nothing counted twice).
        try FileManager.default.removeItem(at: s.paths.stateFile)
        #expect(await s.run() == first)

        // The tools clean up their old logs, then a full re-read happens: the old hours are kept.
        try FileManager.default.removeItem(at: s.codex.appending(path: "rollout-2026-01-10T10-00-00-a.jsonl"))
        try FileManager.default.removeItem(at: s.claude.appending(path: "old.jsonl"))
        try FileManager.default.removeItem(at: s.paths.stateFile)
        let after = await s.run()
        #expect(s.outputs(after) == s.outputs(first))
        #expect(Set(after.entries.map(\.hour)) == Set(first.entries.map(\.hour)))
    }

    @Test func unreadableFilesAreSetAside() async throws {
        let s = try Setup()
        try FileManager.default.createDirectory(at: s.paths.support, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: s.paths.spendFile)
        _ = await s.run()
        let files = try FileManager.default.contentsOfDirectory(atPath: s.paths.support.path)
        #expect(files.contains { $0.hasPrefix("spend.unreadable-") && $0.hasSuffix(".json") })
    }

    @Test func limitHistoryIsKeptForGood() async throws {
        let s = try Setup()
        var h = UsageHistory()
        let old = Date(timeIntervalSince1970: 1_760_000_000) // about a year earlier
        h.add(Sample(tool: .codex, minutes: 10080, resetsAt: old.addingTimeInterval(86400), reading: Reading(t: old, pct: 42)))
        try AtomicJSON.write(h, to: s.paths.historyFile)
        _ = await s.run()
        let saved = try #require(AtomicJSON.read(UsageHistory.self, from: s.paths.historyFile))
        #expect(saved.windows.contains { $0.peak == 42 })
    }
}
