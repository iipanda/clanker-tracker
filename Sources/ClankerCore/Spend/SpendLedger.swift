import Foundation

/// Tokens used by one model response, as read from a tool's logs.
public struct UsageEvent: Sendable, Hashable {
    public var tool: Tool
    public var model: String
    public var t: Date
    public var tokens: TokenCounts
    /// Claude Code fast mode, billed at twice the standard rate.
    public var fast: Bool
    /// The request's prompt size band, for long-context pricing.
    public var context: ContextSize
    /// Identifies the response so a copy of it in another log file isn't counted twice.
    public var dedupeKey: UInt64

    public init(tool: Tool, model: String, t: Date, tokens: TokenCounts, fast: Bool = false, context: ContextSize = .standard, dedupeKey: UInt64) {
        self.tool = tool
        self.model = model
        self.t = t
        self.tokens = tokens
        self.fast = fast
        self.context = context
        self.dedupeKey = dedupeKey
    }

    /// FNV-1a, stable across launches (Swift's Hasher isn't).
    public static func key(_ parts: String...) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part.utf8 {
                h ^= UInt64(byte)
                h &*= 0x100_0000_01b3
            }
            h ^= 0x1f
            h &*= 0x100_0000_01b3
        }
        return h
    }
}

/// Token totals per tool, model and hour, kept for good so periods can be compared.
/// Costs are computed when shown, from the current prices.
public struct SpendLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Hashable {
        public var tool: Tool
        public var model: String
        public var fast: Bool
        public var context: ContextSize
        /// Hours since 1970 (UTC).
        public var hour: Int
        public var tokens: TokenCounts

        public var start: Date { Date(timeIntervalSince1970: TimeInterval(hour) * 3600) }
    }

    struct Key: Hashable {
        let tool: Tool
        let model: String
        let fast: Bool
        let context: ContextSize
        let hour: Int
    }

    public var schemaVersion = 1
    public private(set) var entries: [Entry] = []
    private var index: [Key: Int] = [:]

    enum CodingKeys: String, CodingKey { case schemaVersion, entries }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        entries = try c.decode([Entry].self, forKey: .entries)
        for (i, e) in entries.enumerated() { index[Key(tool: e.tool, model: e.model, fast: e.fast, context: e.context, hour: e.hour)] = i }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(entries, forKey: .entries)
    }

    public static func == (a: SpendLedger, b: SpendLedger) -> Bool { a.entries == b.entries }

    public mutating func add(_ e: UsageEvent) {
        let hour = Int((e.t.timeIntervalSince1970 / 3600).rounded(.down))
        let key = Key(tool: e.tool, model: e.model, fast: e.fast, context: e.context, hour: hour)
        if let i = index[key] {
            entries[i].tokens += e.tokens
        } else {
            index[key] = entries.count
            entries.append(Entry(tool: e.tool, model: e.model, fast: e.fast, context: e.context, hour: hour, tokens: e.tokens))
        }
    }

    public var firstDate: Date? { entries.map(\.hour).min().map { Date(timeIntervalSince1970: TimeInterval($0) * 3600) } }

    /// Totals per model for hours starting in [from, to).
    public func totals(tool: Tool? = nil, from: Date, to: Date) -> [ModelSpend] {
        let lo = Int((from.timeIntervalSince1970 / 3600).rounded(.down)), hi = Int((to.timeIntervalSince1970 / 3600).rounded(.up))
        var out: [String: ModelSpend] = [:]
        for e in entries where e.hour >= lo && e.hour < hi && (tool == nil || e.tool == tool) {
            let id = "\(e.tool.rawValue).\(e.model).\(e.fast)"
            var row = out[id] ?? ModelSpend(tool: e.tool, model: e.model, fast: e.fast)
            row.add(e.tokens, context: e.context)
            out[id] = row
        }
        return Array(out.values)
    }
}

/// One model's tokens over a period, and what they'd cost at API prices.
public struct ModelSpend: Sendable, Hashable, Identifiable {
    public let tool: Tool
    public let model: String
    public let fast: Bool
    /// Tokens per prompt-size band; long-context requests can cost more.
    public private(set) var byContext: [ContextSize: TokenCounts] = [:]

    public init(tool: Tool, model: String, fast: Bool) {
        self.tool = tool
        self.model = model
        self.fast = fast
    }

    public var id: String { "\(tool.rawValue).\(model).\(fast)" }
    public var tokens: TokenCounts { byContext.values.reduce(TokenCounts(), +) }

    mutating func add(_ t: TokenCounts, context: ContextSize) {
        byContext[context, default: TokenCounts()] += t
    }

    /// nil when the price table has no price for the model.
    public func cost(_ prices: PriceTable) -> Double? {
        guard let price = prices.price(for: model) else { return nil }
        return byContext.reduce(0) { $0 + price.cost($1.value, context: $1.key) } * (fast ? 2 : 1)
    }
}

public struct SpendSummary: Sendable, Equatable {
    public var usd: Double = 0
    public var tokens = TokenCounts()
    /// Tokens of models the price table doesn't cover.
    public var unpricedTokens = 0

    public init() {}

    public init(_ rows: [ModelSpend], prices: PriceTable) {
        for r in rows {
            tokens += r.tokens
            if let c = r.cost(prices) { usd += c } else { unpricedTokens += r.tokens.total }
        }
    }
}
