import Foundation
import os

public struct BackfillProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
}

public struct EngineUpdate: Sendable {
    public var history: UsageHistory
    /// Set while the first read of existing Codex logs is running.
    public var backfill: BackfillProgress?
}

struct EngineState: Codable, Sendable {
    var schemaVersion = 1
    var codexCursors: [String: FileCursor] = [:]
    var claudeCursor: FileCursor?
    var backfillCompletedAt: Date?
    var claudeBootstrapAt: Date?
}

/// Owns the usage history: reads Codex logs and the Claude collector's files, watches them, and saves.
public actor Engine {
    public nonisolated let updates: AsyncStream<EngineUpdate>
    private let continuation: AsyncStream<EngineUpdate>.Continuation
    public nonisolated let paths: AppPaths

    private var history: UsageHistory
    private var state: EngineState
    private var backfill: BackfillProgress?
    private var saveTask: Task<Void, Never>?
    private var watchers: [FileWatcher] = []
    private let log = Logger(subsystem: "io.github.iipanda.clankertracker", category: "engine")

    /// How far back the first run reads Codex logs; enough for eight past weeks.
    public static let backfillWindow: TimeInterval = 63 * 24 * 3600
    /// History older than this is dropped.
    public static let retention: TimeInterval = 10 * 7 * 24 * 3600

    public init(paths: AppPaths = .standard) {
        self.paths = paths
        (updates, continuation) = AsyncStream.makeStream(of: EngineUpdate.self, bufferingPolicy: .bufferingNewest(1))
        history = AtomicJSON.read(UsageHistory.self, from: paths.historyFile) ?? UsageHistory()
        state = AtomicJSON.read(EngineState.self, from: paths.stateFile) ?? EngineState()
    }

    public func start(watch: Bool = true) async {
        try? FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
        publish()
        bootstrapClaude()
        readClaude()
        publish()
        if state.backfillCompletedAt == nil {
            await runBackfill()
        } else {
            refreshCodex(changed: nil)
        }
        publish()
        scheduleSave()
        if watch { startWatchers() }
    }

    /// Re-reads everything that changed since the last read.
    public func refresh() {
        refreshCodex(changed: nil)
        bootstrapClaude()
        readClaude()
        publish()
        scheduleSave()
    }

    public func currentHistory() -> UsageHistory { history }

    public func flush() {
        saveTask?.cancel()
        saveNow()
    }

    // MARK: Codex

    private func runBackfill() async {
        let started = Date()
        let cutoff = started.addingTimeInterval(-Self.backfillWindow)
        let files = Self.codexFiles(in: [paths.codexSessions, paths.codexArchived])
            .filter { $0.modified >= cutoff }
            .sorted { $0.modified > $1.modified }
        log.info("Backfill: \(files.count) Codex files")
        backfill = BackfillProgress(done: 0, total: files.count)
        publish()

        await withTaskGroup(of: (String, FileCursor?, [CodexParser.Record]).self) { group in
            var next = 0
            func enqueue() {
                guard next < files.count else { return }
                let path = files[next].path
                next += 1
                group.addTask {
                    var records: [CodexParser.Record] = []
                    let cursor = FileTail.read(path: path, cursor: nil) { CodexParser.scan($0, into: &records) }
                    return (path, cursor, records)
                }
            }
            for _ in 0..<4 { enqueue() }
            var lastPublish = Date.distantPast
            while let (path, cursor, records) = await group.next() {
                apply(records)
                if let cursor { state.codexCursors[path] = cursor }
                backfill?.done += 1
                if Date().timeIntervalSince(lastPublish) > 0.5 {
                    publish()
                    lastPublish = Date()
                }
                enqueue()
            }
        }

        backfill = nil
        state.backfillCompletedAt = Date()
        log.info("Backfill done in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
    }

    /// Reads new lines from Codex logs: the given changed paths, or every log that grew.
    private func refreshCodex(changed: [String]?) {
        let cutoff = Date().addingTimeInterval(-Self.backfillWindow)
        let targets: [String]
        if let changed {
            targets = changed.filter { $0.hasSuffix(".jsonl") }
        } else {
            targets = Self.codexFiles(in: [paths.codexSessions]).compactMap { f in
                if let c = state.codexCursors[f.path] { return c.offset == f.size ? nil : f.path }
                return f.modified >= cutoff ? f.path : nil
            }
        }
        for path in targets {
            var records: [CodexParser.Record] = []
            if let cursor = FileTail.read(path: path, cursor: state.codexCursors[path], consume: { CodexParser.scan($0, into: &records) }) {
                state.codexCursors[path] = cursor
            }
            apply(records)
        }
    }

    private func apply(_ records: [CodexParser.Record]) {
        for r in records {
            history.add(contentsOf: r.samples)
        }
        if let plan = records.last(where: { $0.plan != nil })?.plan { history.setPlan(plan, for: .codex) }
    }

    struct LogFile {
        let path: String
        let modified: Date
        let size: Int64
    }

    static func codexFiles(in roots: [URL]) -> [LogFile] {
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

    /// Seeds Claude data from the usage response Claude Code caches in ~/.claude.json.
    private func bootstrapClaude() {
        guard let data = try? Data(contentsOf: paths.claudeJSON),
              let (samples, fetchedAt) = ClaudeParser.bootstrap(claudeJSON: data),
              fetchedAt > (state.claudeBootstrapAt ?? .distantPast)
        else { return }
        history.add(contentsOf: samples)
        state.claudeBootstrapAt = fetchedAt
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
        codex.start()
        claude.start()
        watchers = [codex, claude]
    }

    private func codexChanged(_ changed: [String]) {
        refreshCodex(changed: changed)
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
        continuation.yield(EngineUpdate(history: history, backfill: backfill))
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
        history.prune(before: Date().addingTimeInterval(-Self.retention))
        do {
            try AtomicJSON.write(history, to: paths.historyFile)
            try AtomicJSON.write(state, to: paths.stateFile)
        } catch {
            log.error("Save failed: \(error.localizedDescription)")
        }
    }
}
