import Foundation
import Testing
@testable import ClankerCore

@Suite struct RefreshTests {
    actor CredentialGate {
        var calls = 0
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        func read() async {
            calls += 1
            // Enabling checks completes normally; the next scheduled check stalls.
            if calls > 1 && !isOpen {
                await withCheckedContinuation { waiters.append($0) }
            }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    actor Completion {
        var done = false
        func finish() { done = true }
    }

    @Test(arguments: [Tool.claude, Tool.cursor])
    func stalledCredentialsDoNotHoldUpLogPolling(stalledProvider: Tool) async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(support: root.appending(path: "data"), codexHome: root.appending(path: "codex"),
                             claudeHome: root.appending(path: "claude"), claudeJSON: root.appending(path: "none.json"))
        try FileManager.default.createDirectory(at: paths.codexSessions, withIntermediateDirectories: true)
        let file = paths.codexSessions.appending(path: "rollout.jsonl")
        try Data().write(to: file)
        let claude = CredentialGate(), cursor = CredentialGate(), completion = Completion()
        let gate = stalledProvider == .claude ? claude : cursor
        let other = stalledProvider == .claude ? cursor : claude
        await other.open()
        let api = ClaudeUsageAPI(credentials: { await claude.read(); return nil })
        let cursorAPI = CursorUsageAPI(credentials: { await cursor.read(); return nil })
        let engine = Engine(paths: paths, downloadsPrices: false, usageAPI: api, cursorAPI: cursorAPI)
        await engine.start(watch: false)
        await engine.setUsageChecks(enabled: true)
        await engine.setCursorChecks(enabled: true, grokBot: false)
        let future = Date().addingTimeInterval(2 * 3600)
        let first = Task {
            await engine.refresh(now: future)
            await completion.finish()
        }
        for _ in 0..<200 {
            if await gate.calls >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.calls == 2)
        for _ in 0..<100 {
            if await completion.done { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await completion.done, "A stalled provider check must not stop the polling loop")

        // No watcher notification: the next poll must discover the appended response itself.
        let lines = [
            #"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"#,
            #"{"timestamp":"2026-10-28T00:25:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100}},"rate_limits":null}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: false, encoding: .utf8)
        let secondCompletion = Completion()
        let second = Task {
            await engine.refresh(now: future.addingTimeInterval(2 * 3600))
            await secondCompletion.finish()
        }
        for _ in 0..<100 {
            if await secondCompletion.done, await other.calls >= 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let spend = await engine.currentSpend()
        #expect(spend.entries.first?.model == "gpt-6-astra")
        #expect(spend.entries.first?.tokens.total == 1100)
        #expect(await secondCompletion.done)
        #expect(await other.calls == 3, "The other provider must keep refreshing independently")
        #expect(await gate.calls == 2, "An in-flight check must not start another credential request")
        await gate.open()
        await first.value
        await second.value
        await engine.flush()
    }
}
