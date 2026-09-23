import Foundation

/// Reads limit snapshots from Codex session logs (`~/.codex/sessions/**/rollout-*.jsonl`).
/// Each model response writes an `event_msg` of type `token_count` carrying `rate_limits`.
public enum CodexParser {
    public static let needle = Array(#""type":"token_count""#.utf8)
    /// Only the main Codex limit; `codex_bengalfox` (Spark) and `premium` are ignored by choice.
    public static let trackedLimitID = "codex"

    public struct Record: Sendable, Equatable {
        public var samples: [Sample]
        public var plan: String?
    }

    struct Line: Decodable {
        let timestamp: String?
        let payload: Payload?
    }

    struct Payload: Decodable {
        let type: String?
        let rate_limits: RateLimits?
    }

    struct RateLimits: Decodable {
        let limit_id: String?
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }

    struct Window: Decodable {
        let used_percent: Double
        let window_minutes: Int
        let resets_at: Double
    }

    public static func parse(line: UnsafeRawBufferPointer) -> Record? {
        parse(line: Data(line))
    }

    public static func parse(line: Data) -> Record? {
        guard let decoded = try? JSONDecoder().decode(Line.self, from: line),
              let payload = decoded.payload, payload.type == "token_count",
              let limits = payload.rate_limits,
              (limits.limit_id ?? trackedLimitID) == trackedLimitID,
              let ts = decoded.timestamp, let t = ISOTime.parse(ts)
        else { return nil }

        let samples = [limits.primary, limits.secondary].compactMap { w -> Sample? in
            guard let w, w.window_minutes > 0 else { return nil }
            let resetsAt = Date(timeIntervalSince1970: w.resets_at)
            guard resetsAt > t.addingTimeInterval(-60) else { return nil }
            return Sample(tool: .codex, minutes: w.window_minutes, resetsAt: resetsAt, reading: Reading(t: t, pct: w.used_percent))
        }
        return samples.isEmpty ? nil : Record(samples: samples, plan: limits.plan_type)
    }

    /// All records in a chunk of log bytes; returns bytes consumed (through the last newline).
    public static func scan(_ buf: UnsafeRawBufferPointer, into records: inout [Record]) -> Int {
        var out: [Record] = []
        let used = LineScanner.scan(buf, needle: needle) { line in
            if let r = parse(line: line) { out.append(r) }
        }
        records.append(contentsOf: out)
        return used
    }
}
