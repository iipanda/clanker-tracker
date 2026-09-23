import Foundation

/// Installs a small block into the user's Claude Code status line script that saves `rate_limits`
/// for the app. The block runs in the background with all output discarded, so the status line
/// itself prints exactly what it did before.
public enum StatusLineHook {
    public static let begin = "# >>> clanker-tracker >>>"
    public static let end = "# <<< clanker-tracker <<<"
    /// The block goes right after the line where the script reads Claude Code's JSON.
    public static let anchor = "input=$(cat)"

    public static let block = #"""
    # >>> clanker-tracker >>>
    # Saves Claude Code usage limits for Clanker Tracker. Delete this block to stop.
    ( d="${CLANKER_TRACKER_DIR:-$HOME/Library/Application Support/ClankerTracker}/claude"
      [ -d "$d" ] || exit 0
      rl=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null); [ -n "$rl" ] || exit 0
      if [ "$rl" = "$(cat "$d/latest.json" 2>/dev/null)" ]; then touch "$d/latest.json"; exit 0; fi
      printf '%s\n' "$rl" > "$d/.latest.$$" && mv -f "$d/.latest.$$" "$d/latest.json"
      printf '{"ts":%s,"rate_limits":%s}\n' "$(date +%s)" "$rl" >> "$d/history.jsonl"
    ) </dev/null >/dev/null 2>&1 &
    # <<< clanker-tracker <<<
    """#

    public enum State: Sendable, Equatable {
        case installed(URL)
        case notInstalled(URL)
        /// The script doesn't read stdin with `input=$(cat)`; the user has to add the block by hand.
        case anchorMissing(URL)
        /// The file can't be read.
        case noScript
    }

    public enum HookError: Error { case noScript, anchorMissing }

    /// The script file named by `statusLine.command` in Claude Code's settings.json.
    public static func scriptURL(settings: URL) -> URL? {
        guard let data = try? Data(contentsOf: settings),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String
        else { return nil }
        return scriptPath(in: command)
    }

    /// The shell script a status line command runs, if it's a plain `sh path/to/script.sh`-style command.
    public static func scriptPath(in command: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for token in command.split(separator: " ").reversed() {
            var path = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
            path = path.replacingOccurrences(of: "$HOME", with: home)
            var isDir: ObjCBool = false
            if path.contains("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    public static func state(script: URL) -> State {
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return .noScript }
        if text.contains(begin) { return .installed(script) }
        return anchorIndex(in: lines(text)) == nil ? .anchorMissing(script) : .notInstalled(script)
    }

    /// Inserts the block after the anchor line. Keeps a copy of the original next to the script.
    public static func install(script: URL) throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        if text.contains(begin) { return }
        var ls = lines(text)
        guard let i = anchorIndex(in: ls) else { throw HookError.anchorMissing }
        try text.write(to: script.appendingPathExtension("clanker-backup"), atomically: true, encoding: .utf8)
        ls.insert(contentsOf: lines(block), at: i + 1)
        try write(ls.joined(separator: "\n"), to: script)
    }

    public static func uninstall(script: URL) throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        var out: [String] = []
        var inside = false
        for line in lines(text) {
            if line.trimmingCharacters(in: .whitespaces) == begin { inside = true; continue }
            if inside {
                if line.trimmingCharacters(in: .whitespaces) == end { inside = false }
                continue
            }
            out.append(line)
        }
        try write(out.joined(separator: "\n"), to: script)
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func anchorIndex(in lines: [String]) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == anchor }
    }

    /// Replaces the file's contents in place so its permissions and any symlink stay as they were.
    static func write(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }
}
