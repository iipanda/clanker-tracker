import Foundation

/// Asks Cursor for plan usage and per-request spend, the way the agent CLI / dashboard do, using the
/// Cursor Agent login from the Keychain (`cursor-access-token`). On by default (see Settings). Cursor does not
/// write rate limits into local session logs, so this is the only source for Cursor Agent.
public struct CursorUsageAPI: Sendable {
    public struct Credentials: Sendable {
        public var accessToken: String
        public init(accessToken: String) { self.accessToken = accessToken }
    }

    public enum Outcome: Sendable, Equatable {
        case updated(readings: Int, events: Int)
        case noLogin
        case loginExpired
        case failed(status: Int?)
    }

    public struct Response: Sendable {
        public var outcome: Outcome
        public var samples: [Sample] = []
        public var events: [UsageEvent] = []
        public var plan: String?
        /// Start of the billing cycle that `samples` belong to, when known.
        public var billingCycleStart: Date?
        /// Model ids that count toward Auto / "Cursor Models" (Composer, Cursor Grok, …).
        public var autoModels: [String] = []
        public var retryAfter: TimeInterval?
    }

    public static let baseURL = URL(string: "https://api2.cursor.sh")!
    public static let keychainService = "cursor-access-token"
    public static let keychainAccount = "cursor-user"
    public static let pageSize = 200

    let credentials: @Sendable () async -> Credentials?
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(credentials: @escaping @Sendable () async -> Credentials? = CursorUsageAPI.cursorCredentials,
                transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.credentials = credentials
        self.transport = transport
    }

    /// Scope of the Grok Bot weekly limit, which is separate from Cursor Agent's Auto and Other.
    public static let grokBotScope = "grok"

    /// Grok Bot requests in the spend events (`grok-bot-default`, `grok-bot-automation`, …).
    public static func isGrokBotModel(_ model: String) -> Bool { model.lowercased().hasPrefix("grok-bot") }

    /// Plan usage plus spend events from `spendFrom` (inclusive) through `now`; with `grokBot`, also
    /// the Grok Bot weekly limit.
    public func fetch(now: Date = Date(), spendFrom: Date?, grokBot: Bool = false) async -> Response {
        guard let creds = await credentials() else { return Response(outcome: .noLogin) }
        var period: Period
        do {
            period = try await fetchPeriod(token: creds.accessToken, now: now)
            if grokBot, let sample = try? await fetchGrokBot(token: creds.accessToken, now: now) {
                period.samples.append(sample)
            }
        } catch let error as HTTPError {
            return Response(outcome: error.status == 401 ? .loginExpired : .failed(status: error.status), retryAfter: error.retryAfter)
        } catch {
            return Response(outcome: .failed(status: nil))
        }

        let from = spendFrom ?? period.billingCycleStart ?? now.addingTimeInterval(-7 * 24 * 3600)
        let events: [UsageEvent]
        do {
            events = try await fetchSpend(token: creds.accessToken, from: from, to: now)
        } catch let error as HTTPError {
            // Limits still apply when spend paging fails.
            return Response(outcome: error.status == 401 ? .loginExpired : .failed(status: error.status),
                            samples: period.samples, plan: period.plan, billingCycleStart: period.billingCycleStart,
                            autoModels: period.autoModels, retryAfter: error.retryAfter)
        } catch {
            return Response(outcome: .failed(status: nil), samples: period.samples, plan: period.plan,
                            billingCycleStart: period.billingCycleStart, autoModels: period.autoModels)
        }

        return Response(outcome: .updated(readings: period.samples.count, events: events.count),
                        samples: period.samples, events: events, plan: period.plan,
                        billingCycleStart: period.billingCycleStart, autoModels: period.autoModels)
    }

    // MARK: Period usage

    struct Period {
        var samples: [Sample]
        var plan: String?
        var billingCycleStart: Date?
        var autoModels: [String] = []
    }

    private func fetchPeriod(token: String, now: Date) async throws -> Period {
        async let usageJSON = post("aiserver.v1.DashboardService/GetCurrentPeriodUsage", body: [:], token: token)
        async let planJSON = post("aiserver.v1.DashboardService/GetPlanInfo", body: [:], token: token)
        let usage = try await usageJSON
        let planRoot = try? await planJSON

        let start = Self.date(usage["billingCycleStart"])
        let end = Self.date(usage["billingCycleEnd"]) ?? Self.date((planRoot?["planInfo"] as? [String: Any])?["billingCycleEnd"])
        let planName = (planRoot?["planInfo"] as? [String: Any])?["planName"] as? String
        let autoModels = (usage["autoBucketModels"] as? [String]) ?? []
        var samples: [Sample] = []

        if let end, let planUsage = usage["planUsage"] as? [String: Any] {
            let minutes: Int
            if let start {
                minutes = max(1, Int(end.timeIntervalSince(start) / 60))
            } else {
                minutes = 30 * 24 * 60
            }
            // Match Cursor's dashboard: Auto ("Cursor Models") and Other Models. Grok Bot is separate (`fetchGrokBot`).
            if let pct = Self.double(planUsage["autoPercentUsed"]) {
                samples.append(Sample(tool: .cursor, minutes: minutes, resetsAt: end,
                                      reading: Reading(t: now, pct: pct), scope: "auto"))
            }
            if let pct = Self.double(planUsage["apiPercentUsed"]) {
                samples.append(Sample(tool: .cursor, minutes: minutes, resetsAt: end,
                                      reading: Reading(t: now, pct: pct), scope: "other"))
            }
        }

        return Period(samples: samples, plan: planName, billingCycleStart: start, autoModels: autoModels)
    }

    private func fetchGrokBot(token: String, now: Date) async throws -> Sample? {
        Self.grokBotSample(try await post("aiserver.v1.DashboardService/GetSandUsageStatus", body: [:], token: token), now: now)
    }

    /// `GetSandUsageStatus` → the Grok Bot weekly limit (its window is ~6.7 days, not exactly 7).
    static func grokBotSample(_ root: [String: Any], now: Date) -> Sample? {
        guard let pct = double(root["usagePercent"]), let end = date(root["nextResetTimestampUtc"]) else { return nil }
        let minutes = date(root["currentPeriodStart"]).map { max(1, Int(end.timeIntervalSince($0) / 60)) } ?? 7 * 24 * 60
        return Sample(tool: .cursor, minutes: minutes, resetsAt: end, reading: Reading(t: now, pct: pct), scope: grokBotScope)
    }

    // MARK: Spend

    private func fetchSpend(token: String, from: Date, to: Date) async throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        var page = 1
        let totalHint: Int? = nil
        while true {
            let root = try await post("aiserver.v1.DashboardService/GetFilteredUsageEvents", body: [
                "startDate": Int64(from.timeIntervalSince1970 * 1000),
                "endDate": Int64(to.timeIntervalSince1970 * 1000),
                "page": page,
                "pageSize": Self.pageSize,
            ], token: token)
            let rows = (root["usageEventsDisplay"] as? [[String: Any]]) ?? []
            for row in rows {
                if let e = Self.event(from: row) { events.append(e) }
            }
            let total = (root["totalUsageEventsCount"] as? NSNumber)?.intValue ?? totalHint
            if rows.count < Self.pageSize { break }
            if let total, events.count >= total { break }
            page += 1
            // Hard stop so a bad total can't loop forever (~100k events).
            if page > 500 { break }
        }
        return events
    }

    /// One dashboard usage row → a spend event. Fast mode is encoded in the model id (`*-fast`);
    /// Cursor's `chargedCents` already includes that premium, so we store it as `billedUSD` and do not
    /// apply LiteLLM's ×2 again.
    public static func event(from row: [String: Any]) -> UsageEvent? {
        guard let t = date(row["timestamp"]) else { return nil }
        let rawModel = (row["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawModel.isEmpty else { return nil }
        let (model, fast) = parseModel(rawModel)
        let tu = row["tokenUsage"] as? [String: Any]
        let tokens = TokenCounts(
            input: int(tu?["inputTokens"]),
            cacheWrite5m: int(tu?["cacheWriteTokens"]),
            cacheRead: int(tu?["cacheReadTokens"]),
            output: int(tu?["outputTokens"])
        )
        let cents = double(row["chargedCents"]) ?? double(tu?["totalCents"])
        guard tokens.total > 0 || (cents ?? 0) > 0 else { return nil }
        let conversation = (row["conversationId"] as? String) ?? ""
        let key = UsageEvent.key("cursor", "\(Int(t.timeIntervalSince1970 * 1000))", rawModel, conversation,
                                 String(format: "%.4f", cents ?? 0))
        let prompt = tokens.input + tokens.cacheWrite + tokens.cacheRead
        return UsageEvent(tool: .cursor, model: model, t: t, tokens: tokens, fast: fast,
                          context: ContextSize(promptTokens: prompt), dedupeKey: key,
                          billedUSD: cents.map { $0 / 100 })
    }

    /// `"grok-4.7-high-fast"` → (`grok-4.7-high`, true).
    public static func parseModel(_ raw: String) -> (model: String, fast: Bool) {
        if raw.hasSuffix("-fast"), raw.count > 5 {
            return (String(raw.dropLast(5)), true)
        }
        return (raw, false)
    }

    // MARK: Transport

    struct HTTPError: Error {
        var status: Int?
        var retryAfter: TimeInterval?
    }

    private func post(_ path: String, body: [String: Any], token: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("cli", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("cli-clanker-tracker", forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("clanker-tracker", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw HTTPError(status: nil)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode
        guard status == 200 else {
            let retry = ClaudeUsageAPI.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"), now: Date())
            throw HTTPError(status: status, retryAfter: retry)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HTTPError(status: status)
        }
        return root
    }

    public static let cursorCredentials: @Sendable () async -> Credentials? = {
        if let data = await ClaudeUsageAPI.run("/usr/bin/security",
                                               ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"]),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return Credentials(accessToken: token)
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cursor/auth.json")
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = root["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return Credentials(accessToken: token)
    }

    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        if let s = value as? String, let v = Double(s) {
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        if let s = value as? String {
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
        }
        return nil
    }

    /// Whether a spend model counts toward Cursor's Auto / "Cursor Models" bucket.
    public static func isAutoModel(_ model: String, autoModels: [String]) -> Bool {
        guard !autoModels.isEmpty else { return false }
        let lower = model.lowercased()
        let bucket = Set(autoModels.map { $0.lowercased() })
        if bucket.contains(lower) || bucket.contains(lower + "-fast") { return true }
        let stripped = Set(autoModels.map { parseModel($0.lowercased()).model })
        return stripped.contains(lower) || stripped.contains(parseModel(lower).model)
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let v = Int(s) { return v }
        if let d = double(value) { return Int(d) }
        return 0
    }

    /// How long to wait after an outcome before trying again.
    public static func backoff(after response: Response) -> TimeInterval? {
        switch response.outcome {
        case .updated: nil
        case .loginExpired: nil
        case .noLogin: 3600
        case .failed(let status) where status == 429: min(24 * 3600, response.retryAfter ?? 3600)
        case .failed: max(3600, response.retryAfter ?? 0)
        }
    }

    /// Every 15 minutes while enabled; sooner only when forced (toggle on).
    public static func shouldCheck(now: Date, lastCheck: Date?, backoffUntil: Date?, force: Bool) -> Bool {
        if let backoffUntil, now < backoffUntil { return false }
        if force { return true }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 15 * 60
    }
}
