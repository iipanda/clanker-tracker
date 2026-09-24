import Foundation
import os

public struct BackfillProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
}

public struct EngineUpdate: Sendable {
    public var history: UsageHistory
    public var spend: SpendLedger
    public var prices: PriceTable
    /// Set while the first full read of existing logs is running.
    public var backfill: BackfillProgress?
}

struct EngineState: Codable, Sendable {
    var schemaVersion = 2
    var codexCursors: [String: FileCursor] = [:]
    var codexContexts: [String: CodexContext] = [:]
    /// The collector's history.jsonl.
    var claudeCursor: FileCursor?
    /// Claude Code transcripts, for token usage.
    var transcriptCursors: [String: FileCursor] = [:]
    var backfillCompletedAt: Date?
    var spendBackfillCompletedAt: Date?
    var claudeBootstrapAt: Date?
    var pricesCheckedAt: Date?

    init() {}

    // Fields added later are optional in older state files.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        codexCursors = try c.decodeIfPresent([String: FileCursor].self, forKey: .codexCursors) ?? [:]
        codexContexts = try c.decodeIfPresent([String: CodexContext].self, forKey: .codexContexts) ?? [:]
        claudeCursor = try c.decodeIfPresent(FileCursor.self, forKey: .claudeCursor)
        transcriptCursors = try c.decodeIfPresent([String: FileCursor].self, forKey: .transcriptCursors) ?? [:]
        backfillCompletedAt = try c.decodeIfPresent(Date.self, forKey: .backfillCompletedAt)
        spendBackfillCompletedAt = try c.decodeIfPresent(Date.self, forKey: .spendBackfillCompletedAt)
        claudeBootstrapAt = try c.decodeIfPresent(Date.self, forKey: .claudeBootstrapAt)
        pricesCheckedAt = try c.decodeIfPresent(Date.self, forKey: .pricesCheckedAt)
    }
}

/// Owns the usage history and the spend ledger: reads Codex logs, Claude Code transcripts and the
/// Claude collector's files, watches them, keeps prices current, and saves.
public actor Engine {
    public nonisolated let updates: AsyncStream<EngineUpdate>
    private let continuation: AsyncStream<EngineUpdate>.Continuation
    public nonisolated let paths: AppPaths

    private var history: UsageHistory
    private var spend: SpendLedger
    private var prices: PriceTable
    /// Responses already counted in `spend` (with the output tokens counted for them), so a copy in
    /// another file isn't counted twice and a later, larger output count only adds the difference.
    private var seen: [UInt64: UInt32]
    private var state: EngineState
    private var backfill: BackfillProgress?
    private var saveTask: Task<Void, Never>?
    private var watchers: [FileWatcher] = []
    private let log = Logger(subsystem: "io.github.iipanda.clankertracker", category: "engine")

    /// How often prices are downloaded.
    public static let priceRefresh: TimeInterval = 24 * 3600

    /// Whether to download prices (off in tests and headless runs).
    private let downloadsPrices: Bool

    public init(paths: AppPaths = .standard, downloadsPrices: Bool = true) {
        self.paths = paths
        self.downloadsPrices = downloadsPrices
        (updates, continuation) = AsyncStream.makeStream(of: EngineUpdate.self, bufferingPolicy: .bufferingNewest(1))
        // History and spend are the app's own record, kept after the tools delete old logs: a file
        // that can't be read is set aside rather than overwritten.
        history = AtomicJSON.readKeepingUnreadable(UsageHistory.self, from: paths.historyFile) ?? UsageHistory()
        state = AtomicJSON.read(EngineState.self, from: paths.stateFile) ?? EngineState()
        spend = AtomicJSON.readKeepingUnreadable(SpendLedger.self, from: paths.spendFile) ?? SpendLedger()
        seen = Self.readSeen(paths.seenFile)
        let fetched = AtomicJSON.read(PriceTable.self, from: paths.pricesFile)
        prices = fetched.map { PriceTable.bundled.overlaid(with: $0) } ?? .bundled
    }

    public func start(watch: Bool = true) async {
        try? FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
        publish()
        bootstrapClaude()
        readClaude()
        publish()
        if state.backfillCompletedAt == nil || state.spendBackfillCompletedAt == nil {
            await runBackfill()
        } else {
            refreshCodex(changed: nil)
            refreshTranscripts(changed: nil)
        }
        publish()
        scheduleSave()
        if watch {
            startWatchers()
            await refreshPricesIfNeeded()
        }
    }

    /// Re-reads everything that changed since the last read.
    public func refresh() async {
        refreshCodex(changed: nil)
        refreshTranscripts(changed: nil)
        bootstrapClaude()
        readClaude()
        publish()
        scheduleSave()
        await refreshPricesIfNeeded()
    }

    public func currentHistory() -> UsageHistory { history }
    public func currentSpend() -> SpendLedger { spend }
    public func currentPrices() -> PriceTable { prices }

    public func flush() {
        saveTask?.cancel()
        saveNow()
    }

    // MARK: First read

    private enum FileResult: Sendable {
        case codex(path: String, cursor: FileCursor?, context: CodexContext, records: [CodexParser.Record], events: [UsageEvent])
        case transcript(path: String, cursor: FileCursor?, events: [UsageEvent])
    }

    /// Reads every existing log once: Codex sessions (limits and tokens) and Claude Code transcripts (tokens).
    private func runBackfill() async {
        let started = Date()
        // Spend needs every file from the start, including ones an earlier version already read for limits.
        state.codexCursors = [:]
        state.codexContexts = [:]
        state.transcriptCursors = [:]
        // Rebuilt from the logs that still exist; older hours come back from the saved ledger at the end.
        let saved = spend
        spend = SpendLedger()
        seen = [:]

        // Oldest sessions first, so when a forked or resumed session repeats its parent's responses the
        // parent's copy (with the original time) is the one counted. Codex names logs by start time.
        let codex = Self.logFiles(in: [paths.codexSessions, paths.codexArchived])
            .sorted { ($0.path as NSString).lastPathComponent < ($1.path as NSString).lastPathComponent }
        let transcripts = Self.logFiles(in: [paths.claudeProjects]).sorted { $0.modified < $1.modified }
        let jobs = codex.map { (path: $0.path, codex: true) } + transcripts.map { (path: $0.path, codex: false) }
        log.info("Backfill: \(codex.count) Codex logs, \(transcripts.count) Claude Code transcripts")
        backfill = BackfillProgress(done: 0, total: jobs.count)
        publish()

        await withTaskGroup(of: (Int, FileResult).self) { group in
            var next = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next], index = next
                next += 1
                group.addTask {
                    (index, Self.read(job))
                }
            }
            for _ in 0..<4 { enqueue() }
            // Results arrive out of order; apply them in file order.
            var pending: [Int: FileResult] = [:], applied = 0
            var lastPublish = Date.distantPast
            while let (index, result) = await group.next() {
                pending[index] = result
                while let r = pending.removeValue(forKey: applied) {
                    apply(r)
                    applied += 1
                    backfill?.done = applied
                }
                if Date().timeIntervalSince(lastPublish) > 0.5 {
                    publish()
                    lastPublish = Date()
                }
                enqueue()
            }
        }

        spend = spend.keeping(saved)
        backfill = nil
        state.backfillCompletedAt = Date()
        state.spendBackfillCompletedAt = Date()
        log.info("Backfill done in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
    }

    private nonisolated static func read(_ job: (path: String, codex: Bool)) -> FileResult {
        if job.codex {
            var context = CodexContext(), records: [CodexParser.Record] = [], events: [UsageEvent] = []
            let cursor = FileTail.read(path: job.path, cursor: nil) {
                CodexUsageParser.scan($0, context: &context, records: &records, events: &events)
            }
            return .codex(path: job.path, cursor: cursor, context: context, records: records, events: events)
        }
        var events: [UsageEvent] = []
        let cursor = FileTail.read(path: job.path, cursor: nil) { ClaudeUsageParser.scan($0, into: &events) }
        return .transcript(path: job.path, cursor: cursor, events: events)
    }

    private func apply(_ result: FileResult) {
        switch result {
        case let .codex(path, cursor, context, records, events):
            var context = context
            apply(records)
            countCodex(events, context: &context)
            if let cursor { state.codexCursors[path] = cursor }
            state.codexContexts[path] = context
        case let .transcript(path, cursor, events):
            count(events)
            if let cursor { state.transcriptCursors[path] = cursor }
        }
    }

    // MARK: Codex

    /// Reads new lines from Codex logs: the given changed paths, or every log that grew.
    private func refreshCodex(changed: [String]?) {
        let targets = changed?.filter { $0.hasSuffix(".jsonl") } ?? Self.logFiles(in: [paths.codexSessions]).compactMap { f in
            state.codexCursors[f.path]?.offset == f.size ? nil : f.path
        }
        for path in targets {
            // A replaced or truncated file is read again from the start, with a fresh context.
            let restarted = state.codexCursors[path].map { Self.restarts(path: path, cursor: $0) } ?? true
            var context = restarted ? CodexContext() : state.codexContexts[path] ?? CodexContext()
            var records: [CodexParser.Record] = [], events: [UsageEvent] = []
            let cursor = FileTail.read(path: path, cursor: state.codexCursors[path]) {
                CodexUsageParser.scan($0, context: &context, records: &records, events: &events)
            }
            guard let cursor else { continue }
            state.codexCursors[path] = cursor
            apply(records)
            countCodex(events, context: &context)
            state.codexContexts[path] = context
        }
    }

    /// Whether `FileTail` will read this file from the start (it was replaced or truncated).
    static func restarts(path: String, cursor: FileCursor) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return true }
        return UInt64(st.st_ino) != cursor.inode || Int64(st.st_size) < cursor.offset
    }

    private func apply(_ records: [CodexParser.Record]) {
        for r in records {
            history.add(contentsOf: r.samples)
        }
        if let plan = records.last(where: { $0.plan != nil })?.plan { history.setPlan(plan, for: .codex) }
    }

    /// Counts a Codex log's events, leaving out a forked session's copy of its parent's history:
    /// the responses written the moment the fork was created (ccusage leaves them out as well).
    private func countCodex(_ events: [UsageEvent], context: inout CodexContext) {
        count(events.filter { context.forkedAt == nil || $0.t != context.forkedAt })
    }

    private func count(_ events: [UsageEvent]) {
        for var e in events {
            let output = UInt32(clamping: e.tokens.output)
            guard let counted = seen[e.dedupeKey] else {
                seen[e.dedupeKey] = output
                spend.add(e)
                continue
            }
            // Claude Code repeats a response's usage on several lines; only the output count changes.
            guard e.tool == .claude, output > counted else { continue }
            seen[e.dedupeKey] = output
            e.tokens = TokenCounts(output: Int(output - counted))
            spend.add(e)
        }
    }

    struct LogFile {
        let path: String
        let modified: Date
        let size: Int64
    }

    static func logFiles(in roots: [URL]) -> [LogFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var out: [LogFile] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                out.append(LogFile(path: url.path, modified: v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0)))
            }
        }
        return out
    }

    // MARK: Claude

    /// Token usage from Claude Code transcripts: the given changed paths, or every transcript that grew.
    private func refreshTranscripts(changed: [String]?) {
        let targets = changed?.filter { $0.hasSuffix(".jsonl") } ?? Self.logFiles(in: [paths.claudeProjects]).compactMap { f in
            state.transcriptCursors[f.path]?.offset == f.size ? nil : f.path
        }
        for path in targets {
            var events: [UsageEvent] = []
            if let cursor = FileTail.read(path: path, cursor: state.transcriptCursors[path], consume: { ClaudeUsageParser.scan($0, into: &events) }) {
                state.transcriptCursors[path] = cursor
            }
            count(events)
        }
    }

    /// Limits saved by the status line collector.
    private func readClaude() {
        var samples: [Sample] = []
        let path = paths.claudeHistory.path
        if let cursor = FileTail.read(path: path, cursor: state.claudeCursor, consume: { ClaudeParser.scan($0, into: &samples) }) {
            state.claudeCursor = cursor
        }
        history.add(contentsOf: samples)
        if let m = (try? paths.claudeLatest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            history.heartbeat(.claude, at: m)
        }
    }

    /// Seeds Claude limits from the usage response Claude Code caches in ~/.claude.json.
    private func bootstrapClaude() {
        guard let data = try? Data(contentsOf: paths.claudeJSON),
              let (samples, fetchedAt) = ClaudeParser.bootstrap(claudeJSON: data),
              fetchedAt > (state.claudeBootstrapAt ?? .distantPast)
        else { return }
        history.add(contentsOf: samples)
        state.claudeBootstrapAt = fetchedAt
    }

    // MARK: Prices

    /// Downloads LiteLLM's price table at most once a day (retrying hourly after a failure).
    private func refreshPricesIfNeeded() async {
        guard downloadsPrices else { return }
        if let checked = state.pricesCheckedAt, Date().timeIntervalSince(checked) < Self.priceRefresh { return }
        state.pricesCheckedAt = Date()
        var request = URLRequest(url: PriceTable.sourceURL, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let fetched = PriceTable.parseLiteLLM(data, fetchedAt: Date())
            else { throw URLError(.badServerResponse) }
            try AtomicJSON.write(fetched, to: paths.pricesFile)
            prices = PriceTable.bundled.overlaid(with: fetched)
            log.info("Prices updated: \(fetched.models.count) models")
            publish()
        } catch {
            state.pricesCheckedAt = Date().addingTimeInterval(3600 - Self.priceRefresh)
            log.error("Price download failed: \(error.localizedDescription)")
        }
        scheduleSave()
    }

    // MARK: Watching

    private func startWatchers() {
        guard watchers.isEmpty else { return }
        let codex = FileWatcher(paths: [paths.codexSessions.path]) { [weak self] changed in
            Task { await self?.codexChanged(changed) }
        }
        let claude = FileWatcher(paths: [paths.claudeDir.path, paths.claudeJSON.deletingLastPathComponent().path], latency: 0.5) { [weak self] changed in
            Task { await self?.claudeChanged(changed) }
        }
        let transcripts = FileWatcher(paths: [paths.claudeProjects.path], latency: 2) { [weak self] changed in
            Task { await self?.transcriptsChanged(changed) }
        }
        [codex, claude, transcripts].forEach { $0.start() }
        watchers = [codex, claude, transcripts]
    }

    private func codexChanged(_ changed: [String]) {
        refreshCodex(changed: changed)
        publish()
        scheduleSave()
    }

    private func transcriptsChanged(_ changed: [String]) {
        refreshTranscripts(changed: changed)
        publish()
        scheduleSave()
    }

    private func claudeChanged(_ changed: [String]) {
        let claudeJSON = paths.claudeJSON.path
        let relevant = changed.filter { $0.hasPrefix(paths.claudeDir.path) || $0 == claudeJSON }
        guard !relevant.isEmpty else { return }
        if relevant.contains(claudeJSON) { bootstrapClaude() }
        readClaude()
        publish()
        scheduleSave()
    }

    // MARK: Output

    private func publish() {
        continuation.yield(EngineUpdate(history: history, spend: spend, prices: prices, backfill: backfill))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func saveNow() {
        do {
            // Limit history is kept for good (it's small); forecasts learn from the recent part.
            try AtomicJSON.write(history, to: paths.historyFile)
            // Mid re-read the ledger is incomplete: keep the saved one until the re-read finishes.
            guard backfill == nil else { return }
            try AtomicJSON.write(spend, to: paths.spendFile)
            try Self.writeSeen(seen, to: paths.seenFile)
            try AtomicJSON.write(state, to: paths.stateFile)
        } catch {
            log.error("Save failed: \(error.localizedDescription)")
        }
    }

    /// 12-byte records: response key, then output tokens counted for it.
    static func readSeen(_ url: URL) -> [UInt64: UInt32] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var out: [UInt64: UInt32] = [:]
        data.withUnsafeBytes { raw in
            out.reserveCapacity(raw.count / 12)
            for o in stride(from: 0, to: raw.count - 11, by: 12) {
                out[raw.loadUnaligned(fromByteOffset: o, as: UInt64.self)] = raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self)
            }
        }
        return out
    }

    static func writeSeen(_ seen: [UInt64: UInt32], to url: URL) throws {
        var data = Data(capacity: seen.count * 12)
        for (k, v) in seen {
            var key = k, value = v
            withUnsafeBytes(of: &key) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
    }
}
