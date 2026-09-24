import ClankerCore
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.pane) {
                Label("Overview", systemImage: "square.grid.2x2").tag(Pane.overview)
                Section("Tools") {
                    ForEach(Tool.allCases) { tool in
                        HStack {
                            Label(tool.displayName, systemImage: "chart.line.uptrend.xyaxis")
                            Spacer()
                            if let f = model.tightest(tool) {
                                Text(Fmt.pct(f.used))
                                    .monospacedDigit()
                                    .foregroundStyle(LimitState(f).color ?? .secondary)
                                    .fontWeight(LimitState(f) == .calm ? .regular : .medium)
                            }
                        }
                        .tag(Pane.tool(tool))
                    }
                }
                Label("Spend", systemImage: "dollarsign.circle").tag(Pane.spend)
                Label("Settings", systemImage: "gearshape").tag(Pane.settings)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button { model.refresh() } label: { Label("Refresh now", systemImage: "arrow.clockwise") }
                            .help("Refresh now")
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch model.pane ?? .overview {
        case .overview:
            ScrollView { OverviewPane(model: model) }
                .navigationTitle("Overview")
            .navigationSubtitle(model.updatedText)
        case .tool(let tool):
            ScrollView { ToolPane(model: model, tool: tool) }
                .navigationTitle(tool.displayName)
            .navigationSubtitle(model.lastSeen(tool).map { "Last reading \(Fmt.ago(model.now.timeIntervalSince($0)))" } ?? "No readings yet")
        case .spend:
            ScrollView { SpendView(model: model) }
                .navigationTitle("Spend")
                .navigationSubtitle("API-equivalent cost")
        case .settings:
            SettingsView(model: model)
                .navigationTitle("Settings")
        }
    }
}

struct OverviewPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            BackfillBanner(model: model)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(Tool.allCases) { ToolCard(tool: $0, model: model) }
            }
            PastWeeksView(model: model, tools: Tool.allCases)
        }
        .padding(24)
    }
}

struct ToolPane: View {
    let model: AppModel
    let tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if tool == .codex { BackfillBanner(model: model) }
            ToolCard(tool: tool, model: model, detailsExpanded: true).id(tool)
            PastWeeksView(model: model, tools: [tool])
        }
        .padding(24)
        .frame(maxWidth: 820, alignment: .leading)
    }
}

private struct BackfillBanner: View {
    let model: AppModel

    var body: some View {
        if let b = model.backfill {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reading your Codex history · \(b.done) of \(b.total) files").font(.callout)
                ProgressView(value: Double(b.done), total: Double(max(1, b.total)))
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
            }
            .padding(14)
            .background(Palette.track, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct PastWeeksView: View {
    let model: AppModel
    let tools: [Tool]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent weekly windows").font(.system(size: 13, weight: .semibold))
                    Text("How full each weekly window got before it reset. Click one to see its usage.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 14) {
                    key(Palette.accent, "Used")
                    key(Palette.warn, "Hit the limit")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(tools) { tool in
                row(tool, scope: nil)
                ForEach(model.scopes(tool), id: \.self) { scope in row(tool, scope: scope) }
            }
        }
    }

    private func key(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }

    @ViewBuilder private func row(_ tool: Tool, scope: String?) -> some View {
        let bars = model.pastWeeks(tool, scope: scope)
        HStack(alignment: .center, spacing: 16) {
            Text(scope.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? tool.displayName)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            if bars.isEmpty {
                Text("No weekly history yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(0..<(8 - bars.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                        ForEach(bars) { bar in
                            let viewed = model.browsing[tool] == bar.id
                            Button { model.browsing[tool] = bar.isCurrent ? nil : bar.id } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(bar.peak >= 100 ? Palette.warn : Palette.accent)
                                    .opacity(bar.isCurrent ? 0.35 : 0.85)
                                    .overlay { if viewed { RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.7), lineWidth: 1.5) } }
                                    .frame(maxWidth: 26)
                                    .frame(height: max(2, 64 * bar.peak / 100))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help((bar.isCurrent ? "Current window: \(Fmt.pct(bar.peak)) so far" : "Ended \(Fmt.monthDay(bar.end)): peaked at \(Fmt.pct(bar.peak))")
                                  + " · \(Fmt.usd(model.windowSpend(tool, scope: scope, from: bar.start, to: bar.end).usd)) API equivalent · Click to see its usage")
                        }
                    }
                    .frame(height: 64, alignment: .bottom)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                    HStack(spacing: 6) {
                        ForEach(0..<(8 - bars.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        ForEach(Array(bars.enumerated()), id: \.element.id) { i, bar in
                            Text(bar.isCurrent ? "Now" : (bars.count - 1 - i) % 2 == 1 ? Fmt.monthDay(bar.end) : "")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}
