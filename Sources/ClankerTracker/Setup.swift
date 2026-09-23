import AppKit
import ClankerCore
import Foundation

/// `ClankerTracker --setup [--no-open-at-login]`: everything after copying the app into place.
/// Reports Codex tracking, sets up the Claude Code collector, adds the login item, and (re)starts the app.
/// This is what the README's agent prompt runs.
enum Setup {
    static func run(openAtLogin: Bool) -> Int32 {
        var failed = false
        let paths = AppPaths.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        print("Clanker Tracker \(version) · \(tilde(Bundle.main.bundlePath))")

        // Codex needs nothing: the app reads its session logs.
        let sessions = paths.codexSessions
        if let e = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) {
            let count = e.reduce(0) { n, item in n + ((item as? URL)?.pathExtension == "jsonl" ? 1 : 0) }
            print("Codex: tracking from \(count) session logs in \(tilde(sessions.path)). No setup needed.")
        } else {
            print("Codex: no sessions on this Mac yet. Tracking starts with your first Codex session.")
        }

        // Claude Code reports limits only to its status line.
        if !hasJQ {
            print("Claude Code: skipped, the collector needs jq (brew install jq). Run --setup again afterwards.")
            failed = true
        } else {
            failed = !setUpClaude(paths) || failed
        }

        if openAtLogin {
            do {
                try LoginItem.set(true)
                print("Open at login: \(LoginItem.isEnabled ? "on" : "off")")
            } catch {
                print("Open at login: couldn't turn it on (\(error.localizedDescription)). Use Settings → General.")
                failed = true
            }
        }

        if relaunch() {
            print("App: running. Click the ring in the menu bar to see your limits, and allow notifications when macOS asks.")
        } else {
            print("App: not started (run it from ClankerTracker.app).")
        }
        print("Undo: --remove-collector (Claude Code), --open-at-login off (login item).")
        return failed ? 1 : 0
    }

    private static func setUpClaude(_ paths: AppPaths) -> Bool {
        let (settings, managed) = (paths.claudeSettings, paths.claudeManagedScript)
        let before = ClaudeCollector.state(settings: settings, managedScript: managed)
        if before.isInstalled {
            print("Claude Code: already set up.")
            return true
        }
        let change = ClaudeCollector.plannedChange(settings: settings, managedScript: managed)
        do {
            try FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
            try ClaudeCollector.install(settings: settings, managedScript: managed)
        } catch {
            print("Claude Code: \(error.localizedDescription)")
            return false
        }
        switch ClaudeCollector.state(settings: settings, managedScript: managed) {
        case .inScript(let script):
            print("Claude Code: added a block to \(tilde(script.path)) that saves your limits. Your status line looks the same; backup at \(script.lastPathComponent).clanker-backup.")
        case .managed(let previous?):
            print("Claude Code: your status line (`\(previous)`) now runs through \(tilde(managed.path)), which saves your limits first and prints the same thing.")
        case .managed(nil):
            print("Claude Code: set up a status line (folder · model · 5h and 7d usage) that saves your limits.")
        default:
            print("Claude Code: setup didn't take effect. Open Settings → Data sources.")
            return false
        }
        if let change {
            print("  statusLine in \(tilde(settings.path)) (backup: settings.json.clanker-backup)")
            print("    was: \(change.before ?? "not set")")
            print("    now: \(change.after)")
        }
        print("  Applies to new Claude Code sessions.")
        return true
    }

    /// Quits any running copy (it may be an older version that was just replaced) and opens this one.
    private static func relaunch() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        others.forEach { $0.terminate() }
        for _ in 0..<50 where others.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [bundle.path]
        guard (try? open.run()) != nil else { return false }
        open.waitUntilExit()
        return open.terminationStatus == 0
    }

    private static var hasJQ: Bool {
        ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
