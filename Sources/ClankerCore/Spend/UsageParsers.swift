import Foundation

/// Reads per-response token usage from Claude Code transcripts (`~/.claude/projects/**/*.jsonl`).
/// A response is written as several lines (one per content block) that repeat its usage, sometimes
/// with a different output count, so events are keyed by message id + request id and the largest
/// output count wins.
public enum ClaudeUsageParser {
    public static let needle = Array(#""usage":{"#.utf8)

    struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?
    }

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation: CacheCreation?
        let output_tokens_details: OutputDetails?
        let speed: String?
    }

    struct CacheCreation: Decodable {
        let ephemeral_5m_input_tokens: Int?
        let ephemeral_1h_input_tokens: Int?
    }

    struct OutputDetails: Decodable {
        let thinking_tokens: Int?
    }

    public static func parse(line: UnsafeRawBufferPointer) -> UsageEvent? {
        guard let l = try? JSONDecoder().decode(Line.self, from: Data(line)),
              l.type == "assistant", let m = l.message, let u = m.usage,
              let model = m.model, model != "<synthetic>",
              let ts = l.timestamp, let t = ISOTime.parse(ts)
        else { return nil }
        let write1h = u.cache_creation?.ephemeral_1h_input_tokens ?? 0
        let write5m = u.cache_creation?.ephemeral_5m_input_tokens ?? max(0, (u.cache_creation_input_tokens ?? 0) - write1h)
        let tokens = TokenCounts(
            input: u.input_tokens ?? 0, cacheWrite5m: write5m, cacheWrite1h: write1h,
            cacheRead: u.cache_read_input_tokens ?? 0, output: u.output_tokens ?? 0,
            reasoning: u.output_tokens_details?.thinking_tokens ?? 0
        )
        guard !tokens.isZero else { return nil }
        let key = UsageEvent.key("claude", m.id ?? ts, l.requestId ?? "")
        let prompt = tokens.input + tokens.cacheWrite + tokens.cacheRead
        return UsageEvent(tool: .claude, model: model, t: t, tokens: tokens, fast: u.speed == "fast",
                          context: ContextSize(promptTokens: prompt), dedupeKey: key)
    }

    public static func scan(_ buf: UnsafeRawBufferPointer, into events: inout [UsageEvent]) -> Int {
        var out: [UsageEvent] = []
        let used = LineScanner.scan(buf, needle: needle) { if let e = parse(line: $0) { out.append(e) } }
        events += out
        return used
    }
}

/// What a Codex session log has established so far, carried between reads of the same file.
public struct CodexContext: Codable, Sendable, Hashable {
    /// The model of the latest `turn_context` / `thread_settings_applied` line.
    public var model: String?
    /// The session's running token total at the last counted event.
    public var lastTotal: Int?
    /// For a forked session (e.g. a sub-agent): when the fork was made. The parent's history is
    /// copied into the new log at that moment, so responses stamped with it are copies.
    public var forkedAt: Date?

    public init(model: String? = nil, lastTotal: Int? = nil) {
        self.model = model
        self.lastTotal = lastTotal
    }
}

/// Reads per-response token usage from Codex session logs. Each `token_count` event carries
/// `last_token_usage` (that response) and `total_token_usage` (the session's running total); an
/// event that repeats the previous total is a re-emission and is skipped. A forked session (e.g. a
/// sub-agent) starts with a copy of its parent's history, stamped with the fork's creation time; the
/// engine leaves those out. Other copies are identified by the running total plus their own counts,
/// not their time. The model comes from the most recent `turn_context` line, which Codex writes
/// before every turn.
public enum CodexUsageParser {
    static let modelNeedles = [Array(#""type":"turn_context""#.utf8), Array(#""type":"thread_settings_applied""#.utf8)]
    static let metaNeedle = Array(#""type":"session_meta""#.utf8)

    struct MetaLine: Decodable {
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable { let forked_from_id: String? }
    }

    struct ModelLine: Decodable {
        let payload: Payload?
        struct Payload: Decodable {
            let model: String?
            let thread_settings: Settings?
        }
        struct Settings: Decodable { let model: String? }
    }

    struct TokenLine: Decodable {
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?
            let info: Info?
        }
        struct Info: Decodable {
            let total_token_usage: Usage?
            let last_token_usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let cache_write_input_tokens: Int?
            let output_tokens: Int?
            let reasoning_output_tokens: Int?
            let total_tokens: Int?
        }
    }

    static func model(fromLine data: Data) -> String? {
        guard let l = try? JSONDecoder().decode(ModelLine.self, from: data) else { return nil }
        return l.payload?.model ?? l.payload?.thread_settings?.model
    }

    static func event(fromTokenLine data: Data, context: inout CodexContext) -> UsageEvent? {
        guard let l = try? JSONDecoder().decode(TokenLine.self, from: data),
              l.payload?.type == "token_count", let info = l.payload?.info,
              let last = info.last_token_usage, let total = info.total_token_usage?.total_tokens,
              let ts = l.timestamp, let t = ISOTime.parse(ts)
        else { return nil }
        guard total != context.lastTotal else { return nil }
        context.lastTotal = total
        let input = last.input_tokens ?? 0, cached = last.cached_input_tokens ?? 0, written = last.cache_write_input_tokens ?? 0
        let tokens = TokenCounts(
            input: max(0, input - cached - written), cacheWrite5m: written, cacheRead: cached,
            output: last.output_tokens ?? 0, reasoning: last.reasoning_output_tokens ?? 0
        )
        guard !tokens.isZero else { return nil }
        return UsageEvent(tool: .codex, model: context.model ?? "unknown", t: t, tokens: tokens,
                          context: ContextSize(promptTokens: input),
                          dedupeKey: UsageEvent.key("codex", String(total), String(input), String(cached), String(last.output_tokens ?? 0)))
    }

    /// Reads rate limits and token usage from one chunk of a session log, in order.
    /// Returns bytes consumed (through the last newline).
    public static func scan(_ buf: UnsafeRawBufferPointer, context: inout CodexContext,
                            records: inout [CodexParser.Record], events: inout [UsageEvent]) -> Int {
        var ctx = context
        var outRecords: [CodexParser.Record] = [], outEvents: [UsageEvent] = []
        let used = LineScanner.scan(buf, needles: [CodexParser.needle, metaNeedle] + modelNeedles) { line, which in
            let data = Data(line)
            switch which {
            case 0:
                if let r = CodexParser.parse(line: data) { outRecords.append(r) }
                if let e = event(fromTokenLine: data, context: &ctx) { outEvents.append(e) }
            case 1:
                if ctx.forkedAt == nil, let meta = try? JSONDecoder().decode(MetaLine.self, from: data), meta.payload?.forked_from_id != nil {
                    ctx.forkedAt = meta.timestamp.flatMap(ISOTime.parse)
                }
            default:
                if let m = model(fromLine: data) { ctx.model = m }
            }
        }
        context = ctx
        records += outRecords
        events += outEvents
        return used
    }
}
