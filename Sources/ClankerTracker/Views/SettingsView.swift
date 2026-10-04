import ClankerCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let notifier: Notifier = .shared
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var showChange = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Menu bar") {
                Picker("Show next to the icon", selection: $settings.menuBarMode) {
                    ForEach(AppSettings.MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Notifications") {
                Toggle(isOn: $settings.notifyRunout) {
                    Text("When a limit will run out before it resets")
                    Text("Once per window, based on your current pace")
                }
                Toggle(isOn: $settings.notifySpikes) {
                    Text("When a spike would run out a 5-hour limit")
                    Text("\"Runs out at 15:40 if you keep this pace\"; alerts again after the spike calms down")
                }
                HStack {
                    Toggle("When usage passes", isOn: $settings.notifyThreshold)
                    Spacer()
                    Picker("Threshold", selection: $settings.threshold) {
                        ForEach([50, 75, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!settings.notifyThreshold)
                }
                Toggle("When a limit resets", isOn: $settings.notifyReset)
                if notifier.authorization == .denied {
                    Text("Notifications are turned off for Clanker Tracker in System Settings → Notifications.")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                }
                Button("Send a test notification") { notifier.sendTest() }
            }

            Section {
                LabeledContent("Session logs", value: tilde(model.engine.paths.codexSessions.path))
            } header: {
                sourceHeader(.codex, waiting: "No readings yet")
            }
            Section {
                claudeSource
            } header: {
                sourceHeader(.claude, waiting: "Waiting for Claude Code")
            }
            Section {
                cursorSource
            } header: {
                sourceHeader(.cursor, waiting: model.settings.checkCursorUsage ? "Waiting for Cursor" : "Checks off")
            }

            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do { try LoginItem.set(on); loginError = nil } catch {
                            loginError = error.localizedDescription
                            openAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Palette.warn)
                }
                Picker("Check for new usage", selection: $settings.refreshSeconds) {
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .onAppear {
            model.refreshHookState()
            openAtLogin = LoginItem.isEnabled
            Task { await notifier.refreshAuthorization() }
        }
    }

    @ViewBuilder private var claudeSource: some View {
        let paths = model.engine.paths
        switch model.collector {
        case .inScript(let script):
            installed("Saving limits from \(tilde(script.path)).")
        case .managed(let previous?):
            installed("`\(previous)` runs through \(tilde(paths.claudeManagedScript.path)), which saves the limits first. Remove restores it.")
        case .managed(nil):
            installed("Clanker Tracker provides your status line (folder · model · 5h and 7d usage).")
        case .canPatchScript(let script):
            setup("Claude Code reports limits only to its status line. This adds a small block to \(tilde(script.path)) that saves them; your status line looks the same.")
        case .canWrap(let command):
            setup("Claude Code reports limits only to its status line. `\(command)` keeps working, run through a small script that saves the limits first.")
        case .canCreate:
            setup("Claude Code reports limits only to its status line, and you don't have one yet. This sets up a simple one (folder · model · 5h and 7d usage).")
        case .settingsUnreadable:
            LabeledContent {
                Button("Check again") { model.refreshHookState() }.controlSize(.small)
            } label: {
                Text("Status line collector")
                Text("~/.claude/settings.json isn't valid JSON, so Clanker Tracker won't change it.")
            }
        }
        if let error = model.hookError {
            Text(error).font(.caption).foregroundStyle(Palette.warn)
        }
        Toggle(isOn: Binding(get: { model.settings.checkUsage }, set: { model.setUsageChecks($0) })) {
            Text("Check limits with Anthropic")
            Text("Keeps Fable current and covers the desktop app, IDE extensions and subagents. Uses Claude Code's login from your Keychain; if macOS asks, choose Always Allow.")
        }
        if model.settings.checkUsage, let check = model.usageCheck, check.outcome != "updated" {
            Text(usageCheckText(check)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cursorSource: some View {
        Toggle(isOn: Binding(get: { model.settings.checkCursorUsage }, set: { model.setCursorChecks($0) })) {
            Text("Check limits and spend with Cursor")
            Text("Every 15 minutes, using the `agent login` from your Keychain; if macOS asks, choose Always Allow.")
        }
        if model.settings.checkCursorUsage, let check = model.cursorUsageCheck, check.outcome != "updated" {
            Text(cursorCheckText(check)).font(.caption).foregroundStyle(.secondary)
        }
        Toggle(isOn: Binding(get: { model.settings.trackGrokBot }, set: { model.setTrackGrokBot($0) })) {
            Text("Track Grok Bot")
            Text("Its weekly limit and its requests in spend.")
        }
        .disabled(!model.settings.checkCursorUsage)
    }

    private func sourceHeader(_ tool: Tool, waiting: String) -> some View {
        HStack {
            Text(tool.displayName)
            Spacer()
            connection(model.lastSeen(tool), waiting: waiting)
        }
    }

    private func usageCheckText(_ c: UsageCheck) -> String {
        let when = Fmt.ago(model.now.timeIntervalSince(c.at))
        switch c.outcome {
        case "updated": return "Last checked \(when)"
        case "noLogin": return "Checked \(when): Claude Code's login isn't available (sign in to Claude Code, or allow Keychain access)"
        case "loginExpired": return "Checked \(when): Claude Code's login needs refreshing; it does that the next time it runs"
        default: return "Checked \(when): Anthropic didn't answer (\(c.outcome)); trying again later"
        }
    }

    private func cursorCheckText(_ c: UsageCheck) -> String {
        let when = Fmt.ago(model.now.timeIntervalSince(c.at))
        switch c.outcome {
        case "updated": return "Last checked \(when)"
        case "noLogin": return "Checked \(when): Cursor Agent's login isn't available (run `agent login`, or allow Keychain access)"
        case "loginExpired": return "Checked \(when): Cursor Agent's login needs refreshing; sign in again with `agent login`"
        default: return "Checked \(when): Cursor didn't answer (\(c.outcome)); trying again later"
        }
    }

    private func installed(_ detail: String) -> some View {
        LabeledContent {
            Button("Remove") { model.uninstallHook() }.controlSize(.small)
        } label: {
            Text("Status line collector")
            Text(detail)
        }
    }

    @ViewBuilder private func setup(_ detail: String) -> some View {
        LabeledContent {
            Button("Install") { model.installHook() }
        } label: {
            Text("Status line collector")
            Text(detail)
        }
        if let change = model.plannedCollectorChange {
            DisclosureGroup(isExpanded: $showChange) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\"statusLine\" in ~/.claude/settings.json. Nothing else in the file changes, and a backup is saved as settings.json.clanker-backup. Applies to new Claude Code sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    codeBlock("Now:    \(change.before ?? "not set")\nAfter:  \(change.after)")
                }
                .padding(.top, 4)
            } label: {
                Text("What changes").font(.caption)
            }
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.track, in: RoundedRectangle(cornerRadius: 6))
    }

    private func connection(_ lastSeen: Date?, waiting: String = "No readings yet") -> some View {
        HStack(spacing: 6) {
            Circle().fill(lastSeen == nil ? Color.secondary : Palette.ok).frame(width: 6, height: 6)
            Text(lastSeen.map { "Last reading \(Fmt.ago(model.now.timeIntervalSince($0)))" } ?? waiting)
                .foregroundStyle(lastSeen == nil ? .secondary : Palette.ok)
        }
        .font(.caption)
    }

    private func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
