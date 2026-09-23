import Foundation
import Testing
@testable import ClankerCore

@Suite struct HookTests {
    func scriptCopy() throws -> URL {
        let url = try tempDir().appending(path: "statusline.sh")
        try FileManager.default.copyItem(at: fixture("statusline-sample.sh"), to: url)
        return url
    }

    @Test func installIsIdempotentAndUninstallRestores() throws {
        let url = try scriptCopy()
        let original = try String(contentsOf: url, encoding: .utf8)
        #expect(StatusLineHook.state(script: url) == .notInstalled(url))

        try StatusLineHook.install(script: url)
        try StatusLineHook.install(script: url)
        let installed = try String(contentsOf: url, encoding: .utf8)
        #expect(installed.components(separatedBy: StatusLineHook.begin).count == 2)
        #expect(installed.contains("input=$(cat)\n" + StatusLineHook.begin))
        #expect(StatusLineHook.state(script: url) == .installed(url))
        #expect(FileManager.default.fileExists(atPath: url.path + ".clanker-backup"))

        try StatusLineHook.uninstall(script: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func missingAnchorIsReported() throws {
        let url = try tempDir().appending(path: "other.sh")
        try "#!/bin/sh\necho hi\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(StatusLineHook.state(script: url) == .anchorMissing(url))
        #expect(throws: StatusLineHook.HookError.self) { try StatusLineHook.install(script: url) }
    }

    @Test func findsScriptFromSettings() throws {
        let dir = try tempDir()
        let script = dir.appending(path: "status line.sh")
        try "input=$(cat)\n".write(to: script, atomically: true, encoding: .utf8)
        let simple = dir.appending(path: "s.sh")
        try "input=$(cat)\n".write(to: simple, atomically: true, encoding: .utf8)
        let settings = dir.appending(path: "settings.json")
        try #"{"statusLine":{"type":"command","command":"sh \#(simple.path)"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        #expect(StatusLineHook.scriptURL(settings: settings)?.path == simple.path)
    }

    /// Runs the real script with and without the block: the status line must print the same thing,
    /// and the block must save the limits in the background.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq") || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/jq")))
    func patchedScriptKeepsOutputAndSaves() async throws {
        let original = try scriptCopy()
        let patched = original.deletingLastPathComponent().appending(path: "patched.sh")
        try FileManager.default.copyItem(at: original, to: patched)
        try StatusLineHook.install(script: patched)

        let data = try tempDir()
        let claudeDir = data.appending(path: "claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let t = Int(Date().timeIntervalSince1970)
        let input = #"{"workspace":{"current_dir":"\#(data.path)"},"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":\#(t + 3600)},"seven_day":{"used_percentage":40,"resets_at":\#(t + 86400)}}}"#

        let before = try run(original, input: input, dataDir: data)
        let clock = ContinuousClock()
        var after = ""
        let elapsed = try clock.measure { after = try run(patched, input: input, dataDir: data) }
        #expect(after == before)
        #expect(elapsed < .milliseconds(500))

        let history = claudeDir.appending(path: "history.jsonl")
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: history.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        var samples: [Sample] = []
        _ = FileTail.read(path: history.path, cursor: nil) { ClaudeParser.scan($0, into: &samples) }
        #expect(samples.map(\.reading.pct) == [12.5, 40])

        // Same limits again: no new history line.
        _ = try run(patched, input: input, dataDir: data)
        try await Task.sleep(for: .milliseconds(300))
        let lines = try String(contentsOf: history, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
    }

    @Test func patchedScriptDoesNothingWithoutDataDir() throws {
        let patched = try scriptCopy()
        try StatusLineHook.install(script: patched)
        let missing = FileManager.default.temporaryDirectory.appending(path: "clanker-missing-\(UUID().uuidString)")
        _ = try run(patched, input: #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1790010000}}}"#, dataDir: missing)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    func run(_ script: URL, input: String, dataDir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["CLANKER_TRACKER_DIR"] = dataDir.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }
}
