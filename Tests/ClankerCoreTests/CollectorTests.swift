import Foundation
import Testing
@testable import ClankerCore

@Suite struct JSONTextTests {
    let pretty = """
    {
      "model": "opus",
      "env": { "A": "has } and \\" inside" },
      "enabledPlugins": {
        "x@y": true
      }
    }

    """

    @Test func insertThenRemoveRestoresPrettyFile() throws {
        let added = try JSONText.setting("statusLine", to: #"{"command":"sh 'a.sh'","type":"command"}"#, in: pretty)
        #expect(added.hasPrefix("{\n  \"statusLine\": {\"command\":\"sh 'a.sh'\",\"type\":\"command\"},\n  \"model\""))
        #expect(try JSONText.removing("statusLine", in: added) == pretty)
    }

    @Test func insertThenRemoveRestoresOneLineFile() throws {
        let text = #"{"a": 1, "b": [1, {"c": "}"}]}"#
        let added = try JSONText.setting("statusLine", to: "{}", in: text)
        #expect(added == #"{"statusLine": {}, "a": 1, "b": [1, {"c": "}"}]}"#)
        #expect(try JSONText.removing("statusLine", in: added) == text)
    }

    @Test func insertIntoEmptyObject() throws {
        let added = try JSONText.setting("statusLine", to: #"{"type":"command"}"#, in: "{}\n")
        #expect(added == "{\n  \"statusLine\": {\"type\":\"command\"}\n}\n")
        #expect(try JSONText.removing("statusLine", in: added) == "{}\n")
    }

    @Test func replaceKeepsEveryOtherByte() throws {
        let text = """
        {
          "statusLine": {
            "type": "command",
            "command": "npx ccstatusline"
          },
          "model": "opus"
        }
        """
        let replaced = try JSONText.setting("statusLine", to: #"{"x":1}"#, in: text)
        #expect(replaced == "{\n  \"statusLine\": {\"x\":1},\n  \"model\": \"opus\"\n}")
        #expect(JSONText.value(of: "statusLine", in: text)?.contains("npx ccstatusline") == true)
    }

    @Test func removeLastMember() throws {
        #expect(try JSONText.removing("b", in: #"{"a": 1, "b": 2}"#) == #"{"a": 1}"#)
        #expect(try JSONText.removing("zzz", in: #"{"a": 1}"#) == #"{"a": 1}"#)
    }

    @Test func rejectsNonObjects() {
        #expect(throws: JSONText.EditError.self) { try JSONText.setting("a", to: "1", in: "[1, 2]") }
    }
}

@Suite struct CollectorTests {
    struct Home {
        let dir: URL
        var settings: URL { dir.appending(path: "settings.json") }
        var managed: URL { dir.appending(path: ClaudeCollector.managedScriptName) }
        var state: ClaudeCollector.State { ClaudeCollector.state(settings: settings, managedScript: managed) }

        init() throws { dir = try tempDir() }

        func writeSettings(_ text: String) throws { try text.write(to: settings, atomically: true, encoding: .utf8) }
        func readSettings() throws -> String { try String(contentsOf: settings, encoding: .utf8) }
        func install() throws { try ClaudeCollector.install(settings: settings, managedScript: managed) }
        func uninstall() throws { try ClaudeCollector.uninstall(settings: settings, managedScript: managed) }

        /// Runs the status line exactly as Claude Code does: the configured command, JSON on stdin.
        func runStatusLine(input: String, dataDir: URL) throws -> String {
            let root = try #require((try JSONSerialization.jsonObject(with: Data(readSettings().utf8))) as? [String: Any])
            let command = try #require((root["statusLine"] as? [String: Any])?["command"] as? String)
            return try shell(command, input: input, dataDir: dataDir)
        }
    }

    let input: String = {
        let t = Int(Date().timeIntervalSince1970)
        return #"{"workspace":{"current_dir":"/Users/me/Projects/clanker"},"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":12.7,"resets_at":\#(t + 3600)},"seven_day":{"used_percentage":40,"resets_at":\#(t + 86400)}}}"#
    }()

    @Test func detectsEachSetup() throws {
        let home = try Home()
        #expect(home.state == .canCreate)
        try home.writeSettings(#"{"model": "opus"}"#)
        #expect(home.state == .canCreate)
        try home.writeSettings(#"{"statusLine": {"type": "command", "command": "npx -y ccstatusline@latest"}}"#)
        #expect(home.state == .canWrap(command: "npx -y ccstatusline@latest"))

        let python = home.dir.appending(path: "status.py")
        try "import sys, json\nprint(json.load(sys.stdin)['model']['display_name'])\n".write(to: python, atomically: true, encoding: .utf8)
        try home.writeSettings(#"{"statusLine": {"type": "command", "command": "python3 \#(python.path)"}}"#)
        #expect(home.state == .canWrap(command: "python3 \(python.path)"))

        let sh = home.dir.appending(path: "status.sh")
        try "#!/bin/sh\ninput=$(cat)\necho hi\n".write(to: sh, atomically: true, encoding: .utf8)
        try home.writeSettings(#"{"statusLine": {"type": "command", "command": "sh \#(sh.path)"}}"#)
        #expect(home.state == .canPatchScript(sh))
        try home.install()
        #expect(home.state == .inScript(sh))

        try home.writeSettings("{ not json")
        #expect(home.state == .settingsUnreadable)
        #expect(throws: ClaudeCollector.CollectorError.self) { try home.install() }
    }

    @Test func wrapsAndRestoresAnExistingCommand() throws {
        let home = try Home()
        let original = """
        {
          "model": "opus",
          "statusLine": {
            "type": "command",
            "command": "jq -r '.model.display_name'",
            "padding": 0
          },
          "enabledPlugins": { "a@b": true }
        }

        """
        try home.writeSettings(original)
        try home.install()

        #expect(home.state == .managed(wrapping: "jq -r '.model.display_name'"))
        let edited = try home.readSettings()
        #expect(edited.hasPrefix("{\n  \"model\": \"opus\",\n  \"statusLine\": {"))
        #expect(edited.hasSuffix("},\n  \"enabledPlugins\": { \"a@b\": true }\n}\n"))
        #expect(edited.contains(#""padding":0"#))
        #expect(try String(contentsOf: home.settings.appendingPathExtension("clanker-backup"), encoding: .utf8) == original)

        try home.uninstall()
        #expect(try home.readSettings() == original)
        #expect(!FileManager.default.fileExists(atPath: home.managed.path))
        #expect(home.state == .canWrap(command: "jq -r '.model.display_name'"))
    }

    @Test func createsAndRemovesAStatusLine() throws {
        let home = try Home()
        let original = "{\n  \"model\": \"opus\"\n}\n"
        try home.writeSettings(original)
        let change = try #require(ClaudeCollector.plannedChange(settings: home.settings, managedScript: home.managed))
        #expect(change.before == nil)
        #expect(change.after.contains(ClaudeCollector.managedScriptName))

        try home.install()
        #expect(home.state == .managed(wrapping: nil))
        try home.uninstall()
        #expect(try home.readSettings() == original)
        #expect(home.state == .canCreate)
    }

    @Test func worksWithoutASettingsFile() throws {
        let home = try Home()
        try home.install()
        #expect(home.state == .managed(wrapping: nil))
        try home.uninstall()
        #expect(home.state == .canCreate)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func wrappedCommandPrintsTheSameAndSaves() async throws {
        let home = try Home()
        let command = "jq -r '\"\\(.model.display_name) in \\(.workspace.current_dir)\"'"
        let entry = try JSONSerialization.data(withJSONObject: ["type": "command", "command": command])
        try home.writeSettings(#"{"statusLine": \#(String(decoding: entry, as: UTF8.self))}"#)
        let data = try tempDir()
        try FileManager.default.createDirectory(at: data.appending(path: "claude"), withIntermediateDirectories: true)

        let before = try home.runStatusLine(input: input, dataDir: data)
        try home.install()
        let after = try home.runStatusLine(input: input, dataDir: data)
        #expect(before == "Opus in /Users/me/Projects/clanker\n")
        #expect(after == before)
        #expect(try await savedPercents(in: data) == [12.7, 40])
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/jq")))
    func createdStatusLineShowsFolderModelAndLimits() async throws {
        let home = try Home()
        let data = try tempDir()
        try FileManager.default.createDirectory(at: data.appending(path: "claude"), withIntermediateDirectories: true)
        try home.install()
        #expect(try home.runStatusLine(input: input, dataDir: data) == "clanker · Opus · 5h 12% · 7d 40%")
        #expect(try await savedPercents(in: data) == [12.7, 40])
        #expect(try home.runStatusLine(input: #"{"model":{"display_name":"Opus"}}"#, dataDir: data) == "Opus")
    }

    func savedPercents(in data: URL) async throws -> [Double] {
        let history = data.appending(path: "claude/history.jsonl")
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: history.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        var samples: [Sample] = []
        _ = FileTail.read(path: history.path, cursor: nil) { ClaudeParser.scan($0, into: &samples) }
        return samples.map(\.reading.pct)
    }
}

func shell(_ command: String, input: String, dataDir: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
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
