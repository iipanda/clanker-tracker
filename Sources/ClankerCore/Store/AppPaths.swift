import Foundation

public struct AppPaths: Sendable {
    /// `~/Library/Application Support/ClankerTracker` (override with `CLANKER_TRACKER_DIR`).
    public var support: URL
    public var codexSessions: URL
    public var codexArchived: URL
    /// `~/.claude.json`, holds a cached copy of the last usage response.
    public var claudeJSON: URL
    /// `~/.claude`
    public var claudeHome: URL
    /// `~/.claude/settings.json`, names the status line command.
    public var claudeSettings: URL { claudeHome.appending(path: "settings.json") }
    /// The status line script the app installs when it can't add its block to the user's own script.
    public var claudeManagedScript: URL { claudeHome.appending(path: ClaudeCollector.managedScriptName) }

    public var claudeDir: URL { support.appending(path: "claude", directoryHint: .isDirectory) }
    public var claudeHistory: URL { claudeDir.appending(path: "history.jsonl") }
    public var claudeLatest: URL { claudeDir.appending(path: "latest.json") }
    public var historyFile: URL { support.appending(path: "history.json") }
    public var spendFile: URL { support.appending(path: "spend.json") }
    public var seenFile: URL { support.appending(path: "spend-seen.bin") }
    public var pricesFile: URL { support.appending(path: "prices.json") }
    /// Claude Code transcripts, read for token usage.
    public var claudeProjects: URL { claudeHome.appending(path: "projects", directoryHint: .isDirectory) }
    public var stateFile: URL { support.appending(path: "state.json") }

    public init(support: URL, codexHome: URL, claudeHome: URL, claudeJSON: URL) {
        self.support = support
        codexSessions = codexHome.appending(path: "sessions", directoryHint: .isDirectory)
        codexArchived = codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory)
        self.claudeJSON = claudeJSON
        self.claudeHome = claudeHome
    }

    public static var standard: AppPaths {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = env["CLANKER_TRACKER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appending(path: "ClankerTracker", directoryHint: .isDirectory)
        let codex = env["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: ".codex", directoryHint: .isDirectory)
        let claude = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: ".claude", directoryHint: .isDirectory)
        return AppPaths(support: support, codexHome: codex, claudeHome: claude, claudeJSON: home.appending(path: ".claude.json"))
    }
}

enum AtomicJSON {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
