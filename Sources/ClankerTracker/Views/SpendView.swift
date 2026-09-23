import Charts
import ClankerCore
import SwiftUI

/// What your usage would cost at API list prices, per day / week / month, compared across periods.
struct SpendView: View {
    let model: AppModel
    @State private var period: SpendPeriod = .week
    @State private var toolFilter: Tool?
    @State private var selected: Date?

    var body: some View {
        let periods = period.recent(now: model.now)
        let current = selectedInterval(periods)
        VStack(alignment: .leading, spacing: 24) {
            controls
            tiles(current, periods: periods)
            chart(periods, selected: current)
            breakdown(current)
            footnote
        }
        .padding(24)
        .onChange(of: period) { selected = nil }
    }

    private func selectedInterval(_ periods: [DateInterval]) -> DateInterval {
        guard let selected, let hit = periods.first(where: { $0.contains(selected) }) else { return periods[periods.count - 1] }
        return hit
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            WindowSwitch(options: SpendPeriod.allCases.enumerated().map { ($0.offset, $0.element.title) },
                         selection: SpendPeriod.allCases.firstIndex(of: period) ?? 1) { period = SpendPeriod.allCases[$0] }
            Spacer()
            WindowSwitch(options: [(0, "Both")] + Tool.allCases.enumerated().map { ($0.offset + 1, $0.element.displayName) },
                         selection: toolFilter.flatMap { Tool.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0) {
                toolFilter = $0 == 0 ? nil : Tool.allCases[$0 - 1]
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder private func tiles(_ current: DateInterval, periods: [DateInterval]) -> some View {
        let now = model.summary(toolFilter, current)
        let inProgress = current.contains(model.now)
        // The current period is compared with the previous one up to the same point (e.g. Monday to Thursday).
        let previous = Calendar.current.date(byAdding: period.component, value: -1, to: current.start)
            .map { period.interval(containing: $0) }
            .map { inProgress ? DateInterval(start: $0.start, duration: min($0.duration, model.now.timeIntervalSince(current.start))) : $0 }
        let before = previous.map { model.summary(toolFilter, $0) }
        HStack(alignment: .top, spacing: 16) {
            tile(period.name(current, now: model.now), Fmt.usd(now.usd), detail: change(now.usd, before?.usd, inProgress: inProgress))
            if toolFilter == nil {
                ForEach(Tool.allCases) { tool in
                    let s = model.summary(tool, current)
                    tile(tool.displayName, Fmt.usd(s.usd), detail: share(s.usd, of: now.usd))
                }
            } else {
                let avg = periods.dropLast().map { model.summary(toolFilter, $0).usd }
                tile("Average \(period.rawValue)", Fmt.usd(avg.isEmpty ? 0 : avg.reduce(0, +) / Double(avg.count)),
                     detail: "Over the previous \(avg.count) \(period.rawValue)s")
            }
            tile("Tokens", Fmt.tokens(now.tokens.total), detail: cacheShare(now.tokens))
        }
    }

    private func tile(_ label: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .medium)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }

    private func change(_ now: Double, _ before: Double?, inProgress: Bool) -> String {
        guard let before else { return " " }
        let name = inProgress ? (period == .day ? "this time yesterday" : "this point last \(period.rawValue)")
            : (period == .day ? "the day before" : "the \(period.rawValue) before")
        guard before > 0.005 else { return "Nothing by \(name)" }
        let pct = (now - before) / before * 100
        return String(format: "%@%.0f%% vs %@", pct >= 0 ? "+" : "−", abs(pct), name)
    }

    private func share(_ part: Double, of whole: Double) -> String {
        whole > 0 ? String(format: "%.0f%% of the total", part / whole * 100) : " "
    }

    private func cacheShare(_ t: TokenCounts) -> String {
        t.total > 0 ? String(format: "%.0f%% read from cache", Double(t.cacheRead) / Double(t.total) * 100) : " "
    }

    // MARK: Chart

    private func chart(_ periods: [DateInterval], selected current: DateInterval) -> some View {
        let bars = periods.flatMap { p in
            (toolFilter.map { [$0] } ?? Tool.allCases).map { tool in Bar(start: p.start, tool: tool, usd: model.summary(tool, p).usd) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("API equivalent per \(period.rawValue)").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Click a bar to see that \(period.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            Chart(bars) { bar in
                BarMark(x: .value("Period", bar.start, unit: period.component), y: .value("Cost", bar.usd))
                    .foregroundStyle(by: .value("Tool", bar.tool.displayName))
                    .opacity(current.contains(bar.start) ? 1 : 0.45)
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale([Tool.claude.displayName: Palette.accent, Tool.codex.displayName: Palette.codex])
            .chartXScale(domain: periods[0].start...periods[periods.count - 1].end)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.usd(v)) } }
                }
            }
            .chartXAxis {
                // Centered labels sit between a tick and the next, so the last bar needs a closing tick.
                AxisMarks(values: periods.map(\.start) + [periods[periods.count - 1].end]) { value in
                    AxisValueLabel(centered: true, collisionResolution: .disabled) {
                        if let d = value.as(Date.self), let i = periods.first(where: { $0.start == d }),
                           period != .day || periods.firstIndex(of: i).map({ $0 % 3 == 2 || i.contains(model.now) }) == true {
                            Text(period.axisLabel(i))
                        }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .chartXSelection(value: $selected)
            .frame(height: 200)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }

    private struct Bar: Identifiable {
        let start: Date
        let tool: Tool
        let usd: Double
        var id: String { "\(start.timeIntervalSince1970).\(tool.rawValue)" }
    }

    // MARK: Breakdown

    @ViewBuilder private func breakdown(_ current: DateInterval) -> some View {
        let rows = model.spendRows(tool: toolFilter, current)
            .map { (row: $0, usd: $0.cost(model.prices)) }
            .sorted { ($0.usd ?? -1, $0.row.tokens.total) > ($1.usd ?? -1, $1.row.tokens.total) }
        VStack(alignment: .leading, spacing: 12) {
            Text("By model · \(period.name(current, now: model.now))").font(.system(size: 13, weight: .semibold))
            if rows.isEmpty {
                Text("No usage in this \(period.rawValue).").foregroundStyle(.secondary).font(.callout)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Model").gridColumnAlignment(.leading)
                        Text("Input")
                        Text("Cache write")
                        Text("Cache read")
                        Text("Output")
                        Text("API equivalent")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(rows, id: \.row.id) { item in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.row.model + (item.row.fast ? " (fast)" : "")).font(.callout)
                                Text(item.row.tool.displayName + (PriceTable.aliases[item.row.model].map { " · priced as \($0)" } ?? ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .gridColumnAlignment(.leading)
                            tokens(item.row.tokens.input)
                            tokens(item.row.tokens.cacheWrite)
                            tokens(item.row.tokens.cacheRead)
                            tokens(item.row.tokens.output)
                            Text(item.usd.map(Fmt.usd) ?? "No price")
                                .foregroundStyle(item.usd == nil ? .secondary : .primary)
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }

    private func tokens(_ n: Int) -> some View {
        Text(n == 0 ? "–" : Fmt.tokens(n)).monospacedDigit().foregroundStyle(n == 0 ? .tertiary : .primary)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API equivalent is what these tokens would cost at API list prices; your subscription is billed separately. Claude Code counts Claude Code sessions on this Mac.")
            Text(pricesNote)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var pricesNote: String {
        let since = model.spend.firstDate.map { " History starts \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
        guard let fetched = model.prices.fetchedAt else { return "Prices: built-in copy of LiteLLM's price table." + since }
        return "Prices: LiteLLM's price table, updated \(Fmt.ago(model.now.timeIntervalSince(fetched)))." + since
    }
}

extension AppModel {
    func summary(_ tool: Tool?, _ interval: DateInterval) -> SpendSummary { spendSummary(tool: tool, interval) }
}
