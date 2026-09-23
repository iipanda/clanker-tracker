import Foundation

/// Tokens of one kind of work, split the way API prices are.
public struct TokenCounts: Codable, Sendable, Hashable {
    /// Input read at the full price (excludes cache reads and writes).
    public var input: Int = 0
    public var cacheWrite5m: Int = 0
    public var cacheWrite1h: Int = 0
    public var cacheRead: Int = 0
    /// Output, including reasoning/thinking tokens.
    public var output: Int = 0
    /// Of `output`, how many were reasoning (for display; already priced as output).
    public var reasoning: Int = 0

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
        self.reasoning = reasoning
    }

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    public var total: Int { input + cacheWrite + cacheRead + output }
    public var isZero: Bool { total == 0 }

    public static func += (a: inout TokenCounts, b: TokenCounts) {
        a.input += b.input
        a.cacheWrite5m += b.cacheWrite5m
        a.cacheWrite1h += b.cacheWrite1h
        a.cacheRead += b.cacheRead
        a.output += b.output
        a.reasoning += b.reasoning
    }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        var c = a
        c += b
        return c
    }
}

/// How big a request's prompt was, in the bands where API prices change.
public enum ContextSize: Int, Codable, Sendable, Hashable, CaseIterable {
    /// Under 200k tokens.
    case standard = 0
    /// 200k–272k tokens: long-context rates for models that switch at 200k.
    case over200k = 1
    /// 272k tokens and up: long-context rates for models that switch at 272k (OpenAI) too.
    case over272k = 2

    public init(promptTokens: Int) {
        self = promptTokens >= 272_000 ? .over272k : promptTokens >= 200_000 ? .over200k : .standard
    }

    var lowerBound: Int { [0, 200_000, 272_000][rawValue] }
}

/// API list prices for one model, in dollars per token.
public struct ModelPrice: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double?
    public var cacheWrite1h: Double?
    public var cacheRead: Double?
    /// Prompt size (tokens) from which the long-context rates apply, if the model has them.
    public var longContextFrom: Int?
    public var longInput: Double?
    public var longOutput: Double?
    public var longCacheWrite5m: Double?
    public var longCacheRead: Double?

    public init(input: Double, output: Double, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil, cacheRead: Double? = nil,
                longContextFrom: Int? = nil, longInput: Double? = nil, longOutput: Double? = nil,
                longCacheWrite5m: Double? = nil, longCacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.longContextFrom = longContextFrom
        self.longInput = longInput
        self.longOutput = longOutput
        self.longCacheWrite5m = longCacheWrite5m
        self.longCacheRead = longCacheRead
    }

    /// Missing cache rates fall back to the usual multipliers of the input price.
    public func cost(_ t: TokenCounts, context: ContextSize = .standard) -> Double {
        let long = longContextFrom.map { context.lowerBound >= $0 } ?? false
        let inRate = long ? longInput ?? input : input
        let outRate = long ? longOutput ?? output : output
        let write5m = (long ? longCacheWrite5m : nil) ?? cacheWrite5m.map { long ? $0 * inRate / input : $0 } ?? inRate * 1.25
        let write1h = cacheWrite1h.map { long ? $0 * inRate / input : $0 } ?? write5m * 1.6
        let read = (long ? longCacheRead : nil) ?? cacheRead.map { long ? $0 * inRate / input : $0 } ?? inRate * 0.1
        return Double(t.input) * inRate + Double(t.cacheWrite5m) * write5m + Double(t.cacheWrite1h) * write1h
            + Double(t.cacheRead) * read + Double(t.output) * outRate
    }
}

/// Model prices, from LiteLLM's public table (the source ccusage uses): fetched daily, with a copy
/// built into the app for offline use.
public struct PriceTable: Codable, Sendable, Equatable {
    public var models: [String: ModelPrice]
    /// When this table was downloaded; nil for the built-in copy.
    public var fetchedAt: Date?

    public init(models: [String: ModelPrice], fetchedAt: Date? = nil) {
        self.models = models
        self.fetchedAt = fetchedAt
    }

    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let providers: Set<String> = ["anthropic", "openai"]
    /// Models the table has no entry for, priced as another model (the same aliases ccusage uses).
    public static let aliases = ["codex-auto-review": "gpt-5.6-luna"]

    /// The built-in copy, generated by scripts/update-prices.py.
    public static let bundled: PriceTable = {
        let data = Data(BundledPrices.json.utf8)
        return (try? JSONDecoder().decode([String: ModelPrice].self, from: data)).map { PriceTable(models: $0) } ?? PriceTable(models: [:])
    }()

    /// Newer prices win; models missing from `newer` keep their older price.
    public func overlaid(with newer: PriceTable) -> PriceTable {
        PriceTable(models: models.merging(newer.models) { _, new in new }, fetchedAt: newer.fetchedAt ?? fetchedAt)
    }

    /// Parses LiteLLM's model_prices_and_context_window.json, keeping Anthropic and OpenAI models.
    public static func parseLiteLLM(_ data: Data, fetchedAt: Date? = nil) -> PriceTable? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var models: [String: ModelPrice] = [:]
        for (key, value) in root {
            guard let e = value as? [String: Any],
                  let provider = e["litellm_provider"] as? String, providers.contains(provider),
                  let input = (e["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let output = (e["output_cost_per_token"] as? NSNumber)?.doubleValue
            else { continue }
            func rate(_ k: String) -> Double? { (e[k] as? NSNumber)?.doubleValue }
            // Long-context rates are keyed like "input_cost_per_token_above_272k_tokens".
            let threshold = e.keys.compactMap { k -> Int? in
                guard k.hasPrefix("input_cost_per_token_above_"), k.hasSuffix("k_tokens") else { return nil }
                return Int(k.dropFirst("input_cost_per_token_above_".count).dropLast("k_tokens".count)).map { $0 * 1000 }
            }.min()
            let tier = threshold.map { "_above_\($0 / 1000)k_tokens" }
            let name = key.split(separator: "/").last.map(String.init) ?? key
            models[name.lowercased()] = ModelPrice(
                input: input, output: output,
                cacheWrite5m: rate("cache_creation_input_token_cost"),
                cacheWrite1h: rate("cache_creation_input_token_cost_above_1hr"),
                cacheRead: rate("cache_read_input_token_cost"),
                longContextFrom: threshold,
                longInput: tier.flatMap { rate("input_cost_per_token" + $0) },
                longOutput: tier.flatMap { rate("output_cost_per_token" + $0) },
                longCacheWrite5m: tier.flatMap { rate("cache_creation_input_token_cost" + $0) },
                longCacheRead: tier.flatMap { rate("cache_read_input_token_cost" + $0) }
            )
        }
        return models.isEmpty ? nil : PriceTable(models: models, fetchedAt: fetchedAt)
    }

    /// Finds a model's price, tolerating Claude Code's "[1m]" suffix and dated model ids.
    public func price(for model: String) -> ModelPrice? {
        var id = model.lowercased()
        if let alias = Self.aliases[id] { id = alias }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if let p = models[id] { return p }
        // "claude-haiku-4-5-20251001" ↔ "claude-haiku-4-5"
        if let range = id.range(of: #"-20\d{6}$"#, options: .regularExpression), let p = models[String(id[..<range.lowerBound])] { return p }
        return models.first { $0.key.hasPrefix(id + "-20") }?.value
    }
}
