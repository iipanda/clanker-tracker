import ClankerCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let notifier: Notifier = .shared
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var copied = false

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

            Section("Data sources") {
                LabeledContent {
                    connection(model.lastSeen(.codex))
                } label: {
                    Text("Codex")
                    Text("Reads limits from session logs in \(tilde(model.engine.paths.codexSessions.path))")
                }
                claudeSource
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
        switch model.hookState {
        case .installed(let script):
            LabeledContent {
                HStack(spacing: 10) {
                    connection(model.lastSeen(.claude), waiting: "Waiting for Claude Code")
                    Button("Remove") { model.uninstallHook() }.controlSize(.small)
                }
            } label: {
                Text("Claude Code")
                Text("Collector installed in \(tilde(script.path)). Updates while Claude Code runs.")
            }
        case .notInstalled(let script):
            LabeledContent {
                Button("Install collector") { model.installHook() }
            } label: {
                Text("Claude Code")
                Text("Claude Code reports limits only to its status line. This adds a small block to \(tilde(script.path)) that saves them; your status line looks the same. A backup is kept next to it.")
            }
        case .anchorMissing(let script):
            manualInstall("Your status line script (\(tilde(script.path))) doesn't read its input with `input=$(cat)`. Add that line near the top, followed by this block:")
        case .noScript:
            manualInstall("Claude Code has no status line script. Create one in ~/.claude/settings.json (\"statusLine\"), read the input with `input=$(cat)`, then add this block:")
        }
        if let error = model.hookError {
            Text(error).font(.caption).foregroundStyle(Palette.warn)
        }
    }

    private func manualInstall(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code")
            Text(text).font(.caption).foregroundStyle(.secondary)
            Text(StatusLineHook.block)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.track, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(copied ? "Copied" : "Copy block") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(StatusLineHook.block, forType: .string)
                    copied = true
                }
                Button("Check again") { model.refreshHookState() }
            }
            .controlSize(.small)
        }
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
