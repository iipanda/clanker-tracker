import ClankerCore
import Foundation

/// Look for current executables and app bundles, never leftover logs or credentials.
enum InstalledAgents {
    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       executable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
                       appExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/Contents/Info.plist") }) -> Set<Tool> {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".local/bin").path,
               home.appending(path: ".npm-global/bin").path, home.appending(path: ".bun/bin").path]
        let commands: [Tool: [String]] = [.claude: ["claude"], .codex: ["codex"], .cursor: ["agent", "cursor-agent"]]
        let apps: [Tool: [String]] = [.claude: ["Claude.app"], .codex: ["Codex.app"], .cursor: ["Cursor.app"]]
        let appDirectories = ["/Applications", home.appending(path: "Applications").path]
        return Set(Tool.allCases.filter { tool in
            (commands[tool] ?? []).contains { command in
                directories.contains { executable(URL(fileURLWithPath: $0).appending(path: command).path) }
            } || (apps[tool] ?? []).contains { app in
                appDirectories.contains { appExists(URL(fileURLWithPath: $0).appending(path: app).path) }
            }
        })
    }
}
