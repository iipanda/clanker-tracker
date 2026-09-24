import ClankerCore
import SwiftUI

/// One tool's current limit: big number, status, burn chart, pace, and forecast details.
struct ToolCard: View {
    let tool: Tool
    let model: AppModel
    var detailsExpanded = false

    @State private var selectedMinutes: Int?
    @State private var showDetails = false

    var body: some View {
        let forecasts = model.forecasts(tool)
        let f = forecasts.first { $0.window.minutes == selectedMinutes } ?? forecasts.first

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                header(forecasts)
                if let f {
                    headline(f)
                    UsageBar(pct: f.used).padding(.top, -6)
                    if f.isReset {
                        Text("A new \(f.window.sentenceLabel) window starts with your next request.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            BurnChart(f: f)
                            ChartLegend()
                        }
                    }
                    stats(f)
                } else {
                    EmptyToolMessage(tool: tool, model: model)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            }
            .padding(20)

            if let f {
                Divider()
                DisclosureGroup(isExpanded: $showDetails) {
                    details(f).padding(.top, 8)
                } label: {
                    Text("Forecast details").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
        .onAppear { showDetails = detailsExpanded }
    }

    @ViewBuilder private func header(_ forecasts: [Forecast]) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.displayName).font(.system(size: 14, weight: .semibold))
                if let plan = model.plan(tool) {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if forecasts.count > 1 {
                WindowSwitch(options: forecasts.map { ($0.window.minutes, $0.window.shortLabel) },
                             selection: selectedMinutes ?? forecasts.first?.window.minutes ?? 0) { selectedMinutes = $0 }
            } else if let only = forecasts.first {
                Text("\(only.window.label) limit only").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func headline(_ f: Forecast) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Fmt.pct(f.used))
                    .font(.system(size: 40, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(f.window.sentenceLabel) limit used").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                let status = headlineStatus(f)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.title).fontWeight(.medium)
                }
                .foregroundStyle(status.color)
                Text(status.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }

    private func headlineStatus(_ f: Forecast) -> (title: String, detail: String, color: Color) {
        let short = f.window.isShort
        if f.isReset { return ("Reset", "At \(Fmt.when(f.end, short: short))", .secondary) }
        if f.isHit { return ("Limit reached", "Back at \(Fmt.when(f.end, short: short))", Palette.crit) }
        if let runout = f.runoutDate {
            return ("Runs out in \(Fmt.duration(hours: f.runoutHours))", "Around \(Fmt.clock(runout)), before the \(Fmt.when(f.end, short: short)) reset", Palette.warn)
        }
        if let spike = f.spikeRunoutDate {
            return ("Runs out ~\(Fmt.clock(spike)) at this pace", "If this spike settles: about \(Fmt.pct(f.projected)) at reset", Palette.warn)
        }
        if let stale = StatusText.staleness(f) { return ("On track", stale, Palette.ok) }
        return ("On track", "About \(Fmt.pct(f.projected)) at reset", Palette.ok)
    }

    @ViewBuilder private func stats(_ f: Forecast) -> some View {
        VStack(spacing: 16) {
            Divider()
            HStack(alignment: .top) {
                stat("Pace, last \(Int(f.lookbackHours))h", Fmt.rate(f.pace), unit: "%/h")
                stat("Sustainable", Fmt.rate(f.sustainable), unit: "%/h")
                stat("Resets", f.isReset ? "–" : f.leftHours < 24 ? Fmt.clock(f.end) : Fmt.dayClock(f.end),
                     detail: f.isReset ? nil : "in \(Fmt.duration(hours: f.leftHours))")
            }
        }
    }

    private func stat(_ label: String, _ value: String, unit: String? = nil, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit()
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func details(_ f: Forecast) -> some View {
        let short = f.window.isShort
        let lead = f.used - f.even
        let rows: [(String, String)] = [
            ("Window started", short ? Fmt.clock(f.start) : Fmt.dateClock(f.start)),
            ("Resets", short ? Fmt.dayClock(f.end) : Fmt.dateClock(f.end)),
            ("Remaining", Fmt.pct(max(0, 100 - f.used), digits: 1)),
            ("Hits 100%", f.runoutDate.map(short ? Fmt.dayClock : Fmt.dateClock) ?? (f.isHit ? "Reached" : "Not before reset")),
            ("Even pace now", "\(Fmt.pct(f.even, digits: 1)) (\(String(format: "%.1f", abs(lead))) pts \(lead >= 0 ? "ahead" : "behind"))"),
            (short ? "Budget per hour" : "Budget per day", short ? Fmt.pct(f.sustainable, digits: 1) : Fmt.pct(f.sustainable * 24, digits: 1)),
            ("Forecast learns from", f.learnedFrom == 0 ? "This window so far" : "Your usual hours in \(f.learnedFrom) past window\(f.learnedFrom == 1 ? "" : "s")"),
            ("API equivalent this window", Fmt.usd(model.windowSpend(tool, from: f.start, to: f.end).usd)),
            ("Last reading", Fmt.ago(f.now.timeIntervalSince(f.lastSeen))),
        ]
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.callout)
    }
}
