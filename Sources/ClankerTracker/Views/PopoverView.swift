import ClankerCore
import SwiftUI

/// The summary that opens from the menu bar: every limit, what it's heading for, and when it resets.
struct PopoverView: View {
    let model: AppModel
    let open: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Tool.allCases.enumerated()), id: \.element) { i, tool in
                if i > 0 { Divider().padding(.horizontal, 10) }
                ToolSection(tool: tool, model: model)
            }
            Divider().padding(.horizontal, 10)
            SpendLine(model: model) { open(.spend) }
            Divider().padding(.horizontal, 4).padding(.bottom, 6)
            Text(model.updatedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            if let backfill = model.backfill {
                Text("Reading Codex history · \(backfill.done) of \(backfill.total) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            MenuRow(title: "Open Clanker Tracker", shortcut: "⌘O") { open(.overview) }
                .keyboardShortcut("o")
            MenuRow(title: "Settings…", shortcut: "⌘,") { open(.settings) }
                .keyboardShortcut(",")
            MenuRow(title: "Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(6)
        .frame(width: 320)
    }
}

private struct ToolSection: View {
    let tool: Tool
    let model: AppModel

    var body: some View {
        let forecasts = model.forecasts(tool)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tool.displayName).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = model.plan(tool) {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if forecasts.isEmpty {
                EmptyToolMessage(tool: tool, model: model, compact: true)
            }
            ForEach(forecasts) { f in LimitRow(f: f) }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

/// "API equivalent · today $87 · week $1,240"; opens the Spend page.
private struct SpendLine: View {
    let model: AppModel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(.plain)
            .background(hovering ? Palette.track : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .help("Open the Spend page")
    }

    @ViewBuilder private var content: some View {
        let today = model.spendSummary(SpendPeriod.day.interval(containing: model.now))
        let week = model.spendSummary(SpendPeriod.week.interval(containing: model.now))
        HStack(alignment: .firstTextBaseline) {
            Text("API equivalent").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("today \(Fmt.usd(today.usd)) · week \(Fmt.usd(week.usd))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct LimitRow: View {
    let f: Forecast

    var body: some View {
        let status = StatusText.line(f)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(f.window.label)
                Spacer()
                Text(Fmt.pct(f.used)).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 13))
            UsageBar(pct: f.used, height: 5)
            HStack(spacing: 8) {
                if let stale = StatusText.staleness(f) {
                    Text(stale).foregroundStyle(.secondary)
                } else {
                    Text(status.text)
                        .foregroundStyle(status.color ?? .secondary)
                        .fontWeight(status.color == nil ? .regular : .medium)
                }
                Spacer(minLength: 4)
                Text(StatusText.resets(f)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(hovering ? Color.white.opacity(0.8) : .secondary)
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? Color.white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
