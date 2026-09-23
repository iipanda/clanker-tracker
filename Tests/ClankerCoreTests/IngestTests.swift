import Foundation
import Testing
@testable import ClankerCore

func fixture(_ name: String) throws -> URL {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    return try #require(Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures"))
}

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "clanker-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct CodexParserTests {
    @Test func readsOnlyTheMainLimit() throws {
        var records: [CodexParser.Record] = []
        let cursor = FileTail.read(path: try fixture("codex-rollout.jsonl").path, cursor: nil) { CodexParser.scan($0, into: &records) }
        #expect(cursor != nil)
        #expect(records.count == 2)
        #expect(records.flatMap(\.samples).map(\.reading.pct) == [30, 31])
        #expect(records.allSatisfy { $0.plan == "pro" })
        let s = try #require(records.last?.samples.first)
        #expect(s.minutes == 10080)
        #expect(s.resetsAt == Date(timeIntervalSince1970: 1_790_754_726))
        #expect(abs(s.reading.t.timeIntervalSince1970 - 1_790_181_235.729) < 0.001)
    }

    @Test func readsBothWindowsOfOldPairs() throws {
        var records: [CodexParser.Record] = []
        _ = FileTail.read(path: try fixture("codex-old-pair.jsonl").path, cursor: nil) { CodexParser.scan($0, into: &records) }
        #expect(records.flatMap(\.samples).map(\.minutes) == [300, 10080])
    }

    @Test func isoTimestamps() throws {
        let f = ISO8601DateFormatter()
        #expect(ISOTime.parse("2026-09-23T16:33:55Z") == f.date(from: "2026-09-23T16:33:55Z"))
        let frac = try #require(ISOTime.parse("2026-09-19T08:20:00.963880+00:00"))
        #expect(abs(frac.timeIntervalSince(try #require(f.date(from: "2026-09-19T08:20:00Z"))) - 0.96388) < 1e-6)
        #expect(ISOTime.parse("2026-09-19T10:20:00+02:00") == f.date(from: "2026-09-19T08:20:00Z"))
        #expect(ISOTime.parse("2024-02-29T00:00:00Z") == f.date(from: "2024-02-29T00:00:00Z"))
        #expect(ISOTime.parse("not a date") == nil)
    }
}

@Suite struct ClaudeParserTests {
    @Test func historyLines() throws {
        var samples: [Sample] = []
        _ = FileTail.read(path: try fixture("claude-history.jsonl").path, cursor: nil) { ClaudeParser.scan($0, into: &samples) }
        #expect(samples.map(\.minutes) == [300, 10080, 10080])
        #expect(samples.map(\.reading.pct) == [12, 40.5, 41])
        #expect(samples[0].resetsAt == Date(timeIntervalSince1970: 1_790_010_000))
    }

    @Test func bootstrapFromCachedUsage() throws {
        let (samples, at) = try #require(ClaudeParser.bootstrap(claudeJSON: Data(contentsOf: fixture("claude-json.json"))))
        #expect(at == Date(timeIntervalSince1970: 1_789_789_588.968))
        #expect(samples.map(\.reading.pct) == [5, 25])
        #expect(samples.map(\.minutes) == [300, 10080])
    }
}

@Suite struct ScannerTests {
    @Test func stopsBeforePartialLine() {
        let bytes = Array("a tok 1\nnothing here\nb tok 2\nc tok".utf8)
        var lines: [String] = []
        let used = bytes.withUnsafeBytes { buf in
            LineScanner.scan(buf, needle: Array("tok".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        }
        #expect(lines == ["a tok 1", "b tok 2"])
        #expect(used == bytes.count - "c tok".utf8.count)
    }

    @Test func tailResumesAndRestarts() throws {
        let url = try tempDir().appending(path: "log.jsonl")
        try Data("one tok\ntwo t".utf8).write(to: url)
        var seen: [String] = []
        let read = { (cursor: FileCursor?) in
            FileTail.read(path: url.path, cursor: cursor) { buf in
                LineScanner.scan(buf, needle: Array("tok".utf8)) { seen.append(String(decoding: $0, as: UTF8.self)) }
            }
        }
        var cursor = try #require(read(nil))
        #expect(seen == ["one tok"])
        #expect(cursor.offset == 8)

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("ok\n".utf8))
        try h.close()
        cursor = try #require(read(cursor))
        #expect(seen == ["one tok", "two tok"])

        // A replaced file (new inode) is read from the start.
        try FileManager.default.removeItem(at: url)
        try Data("three tok\n".utf8).write(to: url)
        _ = read(cursor)
        #expect(seen.last == "three tok")
    }
}

@Suite struct PlannerTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func hot() -> Forecast {
        let start = now.addingTimeInterval(-3 * 3600)
        let w = LimitWindow(tool: .claude, minutes: 300, resetsAt: start.addingTimeInterval(5 * 3600),
                            points: [Reading(t: now.addingTimeInterval(-3600), pct: 50), Reading(t: now, pct: 85)])
        return Forecast(w, now: now)
    }

    @Test func firesOncePerWindow() {
        var ledger: [String: Date] = [:]
        let prefs = NotificationPrefs(runout: true, threshold: 80, reset: false)
        let first = NotificationPlanner.plan([hot()], prefs: prefs, ledger: &ledger, now: now, deliver: true)
        #expect(first.count == 2)
        #expect(first[0].title.hasPrefix("Claude Code 5-hour limit runs out around"))
        #expect(NotificationPlanner.plan([hot()], prefs: prefs, ledger: &ledger, now: now, deliver: true).isEmpty)
    }

    @Test func seedingRecordsWithoutSending() {
        var ledger: [String: Date] = [:]
        let prefs = NotificationPrefs(runout: true, threshold: 80, reset: false)
        #expect(NotificationPlanner.plan([hot()], prefs: prefs, ledger: &ledger, now: now, deliver: false).isEmpty)
        #expect(ledger.count == 2)
        #expect(NotificationPlanner.plan([hot()], prefs: prefs, ledger: &ledger, now: now, deliver: true).isEmpty)
    }

    @Test func resetFiresShortlyAfterTheEnd() {
        var ledger: [String: Date] = [:]
        let later = now.addingTimeInterval(2 * 3600 + 120)
        let f = Forecast(hot().window, now: later)
        let prefs = NotificationPrefs(runout: true, threshold: 80, reset: true)
        let out = NotificationPlanner.plan([f], prefs: prefs, ledger: &ledger, now: later, deliver: true)
        #expect(out.map(\.title) == ["Claude Code 5-hour limit has reset"])
    }

    @Test func staleReadingsAreIgnored() {
        var ledger: [String: Date] = [:]
        let f = Forecast(hot().window, now: now.addingTimeInterval(20 * 60))
        let prefs = NotificationPrefs(runout: true, threshold: 80, reset: false)
        #expect(NotificationPlanner.plan([f], prefs: prefs, ledger: &ledger, now: f.now, deliver: true).isEmpty)
    }
}
