import Foundation
import Testing
@testable import ClankerCore

@Suite struct CursorUsageAPITests {
    @Test func parseModelStripsFastSuffix() {
        #expect(CursorUsageAPI.parseModel("grok-4.7-high-fast") == ("grok-4.7-high", true))
        #expect(CursorUsageAPI.parseModel("composer-2.5-fast") == ("composer-2.5", true))
        #expect(CursorUsageAPI.parseModel("claude-opus-5-5-medium") == ("claude-opus-5-5-medium", false))
        #expect(CursorUsageAPI.parseModel("default") == ("default", false))
        #expect(CursorUsageAPI.parseModel("fast") == ("fast", false))
    }

    @Test func eventUsesChargedCentsAndFastFlag() throws {
        let row: [String: Any] = [
            "timestamp": "1791122311311",
            "model": "grok-4.7-high-fast",
            "chargedCents": 3846.9432,
            "conversationId": "abc",
            "tokenUsage": [
                "inputTokens": 1000,
                "outputTokens": 200,
                "cacheReadTokens": 5000,
                "totalCents": 3846.9432,
            ],
        ]
        let e = try #require(CursorUsageAPI.event(from: row))
        #expect(e.tool == .cursor)
        #expect(e.model == "grok-4.7-high")
        #expect(e.fast == true)
        #expect(e.tokens.input == 1000)
        #expect(e.tokens.output == 200)
        #expect(e.tokens.cacheRead == 5000)
        #expect(abs((e.billedUSD ?? 0) - 38.469432) < 1e-9)
        #expect(e.t == Date(timeIntervalSince1970: 1_791_122_311.311))
    }

    @Test func eventFallsBackToTokenUsageCents() throws {
        let row: [String: Any] = [
            "timestamp": 1_700_000_000_000,
            "model": "default",
            "tokenUsage": [
                "inputTokens": 10,
                "outputTokens": 5,
                "totalCents": 12.5,
            ],
        ]
        let e = try #require(CursorUsageAPI.event(from: row))
        #expect(e.fast == false)
        #expect(e.model == "default")
        #expect(abs((e.billedUSD ?? 0) - 0.125) < 1e-9)
    }

    @Test func eventSkipsEmptyRows() {
        #expect(CursorUsageAPI.event(from: ["timestamp": "1", "model": "x"]) == nil)
        #expect(CursorUsageAPI.event(from: ["model": "x", "chargedCents": 1]) == nil)
    }

    @Test func fetchMapsPeriodAndSpend() async throws {
        let now = Date(timeIntervalSince1970: 1_791_200_000)
        let api = CursorUsageAPI(
            credentials: { CursorUsageAPI.Credentials(accessToken: "test") },
            transport: { request in
                let path = request.url?.lastPathComponent ?? ""
                let json: [String: Any]
                switch path {
                case "GetCurrentPeriodUsage":
                    json = [
                        "billingCycleStart": "1790938143000",
                        "billingCycleEnd": "1793616543000",
                        "planUsage": [
                            "totalPercentUsed": 54.9,
                            "autoPercentUsed": 60.5,
                            "apiPercentUsed": 75.1,
                        ],
                        "autoBucketModels": ["default", "composer-2.5", "composer-2.5-fast"],
                    ]
                case "GetPlanInfo":
                    json = ["planInfo": ["planName": "Pro", "billingCycleEnd": "1793616543000"]]
                case "GetFilteredUsageEvents":
                    json = [
                        "totalUsageEventsCount": 1,
                        "usageEventsDisplay": [[
                            "timestamp": "1791122311311",
                            "model": "grok-4.7-high-fast",
                            "chargedCents": 100.0,
                            "conversationId": "c1",
                            "tokenUsage": ["inputTokens": 1, "outputTokens": 1, "totalCents": 100.0],
                        ]],
                    ]
                default:
                    Issue.record("Unexpected path \(path)")
                    json = [:]
                }
                let data = try JSONSerialization.data(withJSONObject: json)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        )
        let response = await api.fetch(now: now, spendFrom: nil)
        guard case .updated(let readings, let events) = response.outcome else {
            Issue.record("expected updated, got \(response.outcome)")
            return
        }
        #expect(readings == 2)
        #expect(events == 1)
        #expect(response.plan == "Pro")
        #expect(response.autoModels.contains("default"))
        let byScope = Dictionary(uniqueKeysWithValues: response.samples.map { ($0.scope ?? "", $0) })
        #expect(Set(byScope.keys) == ["auto", "other"])
        #expect(abs((byScope["auto"]?.reading.pct ?? 0) - 60.5) < 1e-9)
        #expect(abs((byScope["other"]?.reading.pct ?? 0) - 75.1) < 1e-9)
        #expect(byScope["auto"]?.minutes == 31 * 24 * 60)
        let event = try #require(response.events.first)
        #expect(event.fast == true)
        #expect(abs((event.billedUSD ?? 0) - 1.0) < 1e-9)
    }

    @Test func grokBotLimitFromSandUsageStatus() throws {
        let now = Date(timeIntervalSince1970: 1_791_200_000)
        let s = try #require(CursorUsageAPI.grokBotSample([
            "currentPeriodStart": "2026-10-02T18:03:21.985Z",
            "nextResetTimestampUtc": "2026-10-09T10:50:20.874Z",
            "usagePercent": 37.933182,
        ], now: now))
        #expect(s.tool == .cursor)
        #expect(s.scope == CursorUsageAPI.grokBotScope)
        #expect(s.minutes == 9646)
        #expect(abs(s.resetsAt.timeIntervalSince1970 - 1_791_543_020.874) < 1e-3)
        #expect(abs(s.reading.pct - 37.933182) < 1e-9)
        #expect(CursorUsageAPI.grokBotSample(["usagePercent": 10], now: now) == nil)
        let w = LimitWindow(tool: .cursor, minutes: s.minutes, resetsAt: s.resetsAt, scope: s.scope)
        #expect(w.label == "Grok Bot weekly")
    }

    @Test func grokBotModelsAndLedgerFilter() {
        #expect(CursorUsageAPI.isGrokBotModel("grok-bot-default"))
        #expect(CursorUsageAPI.isGrokBotModel("grok-bot-automation"))
        #expect(!CursorUsageAPI.isGrokBotModel("grok-4.7-high"))
        var ledger = SpendLedger()
        for (i, model) in ["grok-bot-default", "grok-4.7-high", "grok-bot-cua"].enumerated() {
            ledger.add(UsageEvent(tool: .cursor, model: model, t: Date(timeIntervalSince1970: 3600),
                                  tokens: TokenCounts(input: 10), dedupeKey: UInt64(i), billedUSD: 1))
        }
        var kept = ledger.filter { !CursorUsageAPI.isGrokBotModel($0.model) }
        #expect(kept.entries.map(\.model) == ["grok-4.7-high"])
        kept.add(UsageEvent(tool: .cursor, model: "grok-4.7-high", t: Date(timeIntervalSince1970: 3600),
                            tokens: TokenCounts(input: 5), dedupeKey: 9))
        #expect(kept.entries.count == 1)
        #expect(kept.entries.first?.tokens.input == 15)
    }

    @Test func autoModelBucketMatching() {
        let auto = ["default", "composer-2.5", "composer-2.5-fast", "grok-4.5"]
        #expect(CursorUsageAPI.isAutoModel("default", autoModels: auto))
        #expect(CursorUsageAPI.isAutoModel("composer-2.5", autoModels: auto))
        #expect(CursorUsageAPI.isAutoModel("grok-4.5", autoModels: auto))
        #expect(!CursorUsageAPI.isAutoModel("grok-4.7-high", autoModels: auto))
        #expect(!CursorUsageAPI.isAutoModel("claude-opus-5-5-medium", autoModels: auto))
    }

    @Test func billedSpendDoesNotDoubleFast() {
        var ledger = SpendLedger()
        ledger.add(UsageEvent(tool: .cursor, model: "grok-4.7-high", t: Date(timeIntervalSince1970: 3600),
                              tokens: TokenCounts(input: 1000, output: 100), fast: true, dedupeKey: 1,
                              billedUSD: 2.5))
        let row = try! #require(ledger.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 7200)).first)
        #expect(row.fast == true)
        #expect(abs((row.cost(PriceTable(models: [:])) ?? -1) - 2.5) < 1e-9)
    }
}
