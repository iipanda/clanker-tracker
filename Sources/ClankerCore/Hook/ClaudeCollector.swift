import Foundation

/// Gets Claude Code's `rate_limits` saved for the app, whatever the user's status line looks like:
/// - a shell script that reads `input=$(cat)` gets the collector block added in place (`StatusLineHook`);
/// - any other status line command is wrapped: a managed script saves the limits, then runs the
///   original command with the same input and prints its output unchanged;
/// - no status line at all gets a managed script that saves the limits and prints a simple one.
///
/// Only the `statusLine` entry of settings.json is ever edited. The managed script remembers the
/// previous entry so removing the collector puts it back exactly.
public enum ClaudeCollector {
    public static let managedScriptName = "clanker-statusline.sh"

    public enum State: Sendable, Equatable {
        /// The block is in the user's own script.
        case inScript(URL)
        /// The managed script is the status line, wrapping the user's previous command (nil: none before).
        case managed(wrapping: String?)
        /// Not installed; the user's script can take the block.
        case canPatchScript(URL)
        /// Not installed; the current status line command will be wrapped.
        case canWrap(command: String)
        /// Not installed; there's no status line yet.
        case canCreate
        /// settings.json exists but can't be read or isn't a JSON object.
        case settingsUnreadable

        public var isInstalled: Bool {
            switch self {
            case .inScript, .managed: true
            default: false
            }
        }
    }

    public enum CollectorError: Error, LocalizedError {
        case unreadableSettings
        case unknownPrevious

        public var errorDescription: String? {
            switch self {
            case .unreadableSettings: "Claude Code's settings.json isn't valid JSON, so it wasn't changed."
            case .unknownPrevious: "The previous status line setting wasn't found in \(ClaudeCollector.managedScriptName); edit \"statusLine\" in ~/.claude/settings.json by hand."
            }
        }
    }

    // MARK: State

    public static func state(settings: URL, managedScript: URL) -> State {
        guard let text = settingsText(settings) else { return .settingsUnreadable }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(normalized(text).utf8))) as? [String: Any] else { return .settingsUnreadable }
        guard let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .canCreate }

        if command.contains(managedScriptName) {
            let previous = previousEntry(inScript: managedScript) ?? nil
            return .managed(wrapping: previous.flatMap(commandOf))
        }
        if let script = StatusLineHook.scriptPath(in: command) {
            switch StatusLineHook.state(script: script) {
            case .installed: return .inScript(script)
            case .notInstalled: return .canPatchScript(script)
            default: break
            }
        }
        return .canWrap(command: command)
    }

    /// The `statusLine` entry before and after installing, for showing the user what will change.
    public static func plannedChange(settings: URL, managedScript: URL) -> (before: String?, after: String)? {
        switch state(settings: settings, managedScript: managedScript) {
        case .canWrap, .canCreate:
            guard let text = settingsText(settings) else { return nil }
            let before = JSONText.value(of: "statusLine", in: normalized(text))
            return (before, newEntry(replacing: before, managedScript: managedScript))
        default:
            return nil
        }
    }

    // MARK: Install / uninstall

    public static func install(settings: URL, managedScript: URL) throws {
        switch state(settings: settings, managedScript: managedScript) {
        case .canPatchScript(let script):
            try StatusLineHook.install(script: script)
        case .canWrap, .canCreate:
            try installManaged(settings: settings, managedScript: managedScript)
        case .settingsUnreadable:
            throw CollectorError.unreadableSettings
        case .inScript, .managed:
            return
        }
    }

    public static func uninstall(settings: URL, managedScript: URL) throws {
        switch state(settings: settings, managedScript: managedScript) {
        case .inScript(let script):
            try StatusLineHook.uninstall(script: script)
        case .managed:
            guard let text = settingsText(settings) else { throw CollectorError.unreadableSettings }
            guard let previous = previousEntry(inScript: managedScript) else { throw CollectorError.unknownPrevious }
            let restored = try previous.map { try JSONText.setting("statusLine", to: $0, in: text) }
                ?? JSONText.removing("statusLine", in: text)
            try write(restored, to: settings)
            try? FileManager.default.removeItem(at: managedScript)
        default:
            return
        }
    }

    private static func installManaged(settings: URL, managedScript: URL) throws {
        guard let raw = settingsText(settings) else { throw CollectorError.unreadableSettings }
        let text = normalized(raw)
        let previous = JSONText.value(of: "statusLine", in: text)
        let updated = try JSONText.setting("statusLine", to: newEntry(replacing: previous, managedScript: managedScript), in: text)

        try FileManager.default.createDirectory(at: managedScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(managedScriptText(previousEntry: previous).utf8).write(to: managedScript, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedScript.path)

        if FileManager.default.fileExists(atPath: settings.path) {
            try raw.write(to: settings.appendingPathExtension("clanker-backup"), atomically: true, encoding: .utf8)
        }
        try write(updated, to: settings)
    }

    // MARK: The managed script

    static let previousMarker = "# clanker-previous: "

    /// The script Claude Code runs as its status line once the collector is managed by the app.
    static func managedScriptText(previousEntry: String?) -> String {
        let previousCommand = previousEntry.flatMap(commandOf) ?? ""
        let encoded = previousEntry.map { Data($0.utf8).base64EncodedString() } ?? "none"
        return """
        #!/bin/sh
        # Claude Code status line set up by Clanker Tracker. It saves your usage limits for the app,
        # then prints your status line. To undo, use Clanker Tracker → Settings → Data sources → Remove,
        # which restores your previous "statusLine" setting (kept below, base64-encoded).
        \(previousMarker)\(encoded)

        input=$(cat)
        \(StatusLineHook.block)

        previous=\(shellQuoted(previousCommand))
        if [ -n "$previous" ]; then
          printf '%s' "$input" | /bin/sh -c "$previous"
          exit $?
        fi

        # No status line before: show folder · model · limits.
        dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""' 2>/dev/null)
        model=$(printf '%s' "$input" | jq -r '.model.display_name // ""' 2>/dev/null)
        limits=$(printf '%s' "$input" | jq -r '[(.rate_limits.five_hour.used_percentage // empty | "5h \\(floor)%"), (.rate_limits.seven_day.used_percentage // empty | "7d \\(floor)%")] | join(" · ")' 2>/dev/null)
        line=${dir##*/}
        [ -n "$model" ] && line="${line:+$line · }$model"
        [ -n "$limits" ] && line="${line:+$line · }$limits"
        printf '%s' "$line"

        """
    }

    /// The previous `statusLine` entry saved in the managed script: `.some(nil)` if there was none,
    /// nil if the script or its marker is missing.
    static func previousEntry(inScript url: URL) -> String?? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix(previousMarker) })
        else { return nil }
        let value = line.dropFirst(previousMarker.count).trimmingCharacters(in: .whitespaces)
        if value == "none" { return .some(nil) }
        guard let data = Data(base64Encoded: value) else { return nil }
        return .some(String(decoding: data, as: UTF8.self))
    }

    static func newEntry(replacing previous: String?, managedScript: URL) -> String {
        var entry = previous.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
        entry["type"] = "command"
        entry["command"] = "sh \(shellQuoted(managedScript.path))"
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func commandOf(_ entry: String) -> String? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(entry.utf8))) as? [String: Any]
        return (obj?["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Files

    /// settings.json contents; "" when the file doesn't exist yet, nil when it can't be read.
    private static func settingsText(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : text
    }

    /// Writes in place so a symlinked settings.json (e.g. from a dotfiles repo) stays a symlink.
    private static func write(_ text: String, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try StatusLineHook.write(text, to: url)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }
}
