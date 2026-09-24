import ClankerCore
import SwiftUI

/// One tool's current limit: big number, status, burn chart, pace, and forecast details. Earlier
/// windows of the limit can be browsed with the arrows in the header.
struct ToolCard: View {
    let tool: Tool
    let model: AppModel
    var detailsExpanded = false

    /// The selected limit, by `LimitWindow.kindKey`.
    @State private var selectedKind: String?
    @State private var showDetails = false

    var body: some View {
        let forecasts = model.forecasts(tool)
        // A window picked in the recent windows row selects its limit.
        let past = model.browsedWindow(tool).flatMap { p in forecasts.contains { $0.window.kindKey == p.window.kindKey } ? p : nil }
        let kind = past?.window.kindKey ?? selectedKind
        let f = forecasts.first { $0.window.kindKey == kind } ?? forecasts.first

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                header(forecasts, selected: f, past: past)
                if let past {
                    pastHeadline(past)
                    UsageBar(pct: past.peak).padding(.top, -6)
                    VStack(alignment: .leading, spacing: 10) {
                        BurnChart(past: past, now: model.now).id(past.id)
                        ChartLegend(forecast: false)
                    }
                    pastStats(past)
                } else if let f {
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

            if let f, past == nil {
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

    @ViewBuilder private func header(_ forecasts: [Forecast], selected f: Forecast?, past: EndedWindow?) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.displayName).font(.system(size: 14, weight: .semibold))
                if let plan = model.plan(tool) {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            let ended = (past?.window ?? f?.window).map(model.endedWindows) ?? []
            // Side by side when there's room, the pager under the limit switch when there isn't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pager(ended, past: past); limitSwitch(forecasts, selected: f) }
                VStack(alignment: .trailing, spacing: 6) { limitSwitch(forecasts, selected: f); pager(ended, past: past) }
            }
        }
    }

    @ViewBuilder private func limitSwitch(_ forecasts: [Forecast], selected f: Forecast?) -> some View {
        HStack {
            if forecasts.count > 1 {
                WindowSwitch(options: forecasts.enumerated().map { ($0.offset, $0.element.window.shortLabel) },
                             selection: forecasts.firstIndex { $0.id == f?.id } ?? 0) {
                    selectedKind = forecasts[$0].window.kindKey
                    model.browsing[tool] = nil
                }
            } else if let only = forecasts.first {
                Text("\(only.window.label) limit only").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func headline(_ f: Forecast) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text((f.isEstimated ? "≈" : "") + Fmt.pct(f.used))
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

    // MARK: Past windows

    /// ‹ Sep 12 – 19 › Now: steps through ended windows of the limit; right of the latest one is the
    /// current window. Styled like the limit switch next to it.
    @ViewBuilder private func pager(_ ended: [EndedWindow], past: EndedWindow?) -> some View {
        if !ended.isEmpty {
            let i = past.flatMap { p in ended.firstIndex { $0.id == p.id } } ?? ended.count
            HStack(spacing: 0) {
                pagerButton(Image(systemName: "chevron.left"), enabled: i > 0, help: "Earlier window") {
                    model.browsing[tool] = ended[max(0, i - 1)].id
                }
                if let past {
                    Text(rangeLabel(past))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                }
                pagerButton(Image(systemName: "chevron.right"), enabled: past != nil, help: "Later window") {
                    model.browsing[tool] = i + 1 < ended.count ? ended[i + 1].id : nil
                }
                if past != nil {
                    pagerButton(Text("Now"), enabled: true, help: "Back to the current window") { model.browsing[tool] = nil }
                }
            }
            .padding(2)
            .background(Palette.track, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Past windows")
        }
    }

    private func pagerButton(_ label: some View, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    /// "Sep 12 – 19", "Sep 12 – Oct 2"; "Sep 12, 09:00–14:00" for short windows.
    private func rangeLabel(_ p: EndedWindow) -> String {
        let cal = Calendar.current
        if p.window.isShort { return "\(Fmt.monthDay(p.start)), \(Fmt.clock(p.start))–\(Fmt.clock(p.end))" }
        let sameMonth = cal.isDate(p.start, equalTo: p.end, toGranularity: .month)
        return "\(Fmt.monthDay(p.start)) – \(sameMonth ? p.end.formatted(.dateTime.day()) : Fmt.monthDay(p.end))"
    }

    @ViewBuilder private func pastHeadline(_ p: EndedWindow) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text((p.window.isEstimated ? "≈" : "") + Fmt.pct(p.peak))
                    .font(.system(size: 40, weight: .medium))
                    .monospacedDigit()
                Text("of \(p.window.sentenceLabel) limit used").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                let status = pastStatus(p)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.title).fontWeight(.medium)
                }
                .foregroundStyle(status.color)
                Text(status.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }

    private func pastStatus(_ p: EndedWindow) -> (title: String, detail: String, color: Color) {
        if let hit = p.hitAt {
            let early = p.end.timeIntervalSince(hit) / 3600
            return ("Hit the limit", "At \(Fmt.moment(hit, now: model.now)), \(Fmt.duration(hours: early)) before it reset", Palette.crit)
        }
        let lasted = "After \(Fmt.duration(hours: p.end.timeIntervalSince(p.start) / 3600))"
        if p.endedEarly { return ("Reset early", lasted, .secondary) }
        return ("Ended", "\(Fmt.pct(100 - p.peak)) left unused", .secondary)
    }

    private func pastStats(_ p: EndedWindow) -> some View {
        VStack(spacing: 16) {
            Divider()
            HStack(alignment: .top) {
                stat("Started", day(p.start), detail: Fmt.clock(p.start))
                stat(p.endedEarly ? "Reset early" : "Reset", day(p.end), detail: Fmt.clock(p.end))
                stat("API equivalent", Fmt.usd(model.windowSpend(tool, scope: p.window.scope, from: p.start, to: p.end).usd))
            }
        }
    }

    /// "Mon, Sep 15"
    private func day(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    private func headlineStatus(_ f: Forecast) -> (title: String, detail: String, color: Color) {
        if f.isReset { return ("Reset", "At \(Fmt.moment(f.end, now: f.now))", .secondary) }
        if f.isHit { return ("Limit reached", "Back at \(Fmt.moment(f.end, now: f.now))", Palette.crit) }
        if let runout = f.runoutDate {
            return ("Runs out in \(Fmt.duration(hours: f.runoutHours))", "Around \(Fmt.moment(runout, now: f.now)), before the \(Fmt.moment(f.end, now: f.now)) reset", Palette.warn)
        }
        if let spike = f.spikeRunoutDate {
            return ("Runs out ~\(Fmt.moment(spike, now: f.now)) at this pace", "If this spike settles: about \(Fmt.pct(f.projected)) at reset", Palette.warn)
        }
        if let note = StatusText.estimateNote(f) {
            return ("On track", note, Palette.ok)
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
                stat("Resets", f.isReset ? "–" : Fmt.moment(f.end, now: f.now),
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

    /// For a scoped limit (Fable): how much of it $100 of usage takes, which the estimate builds on.
    private func calibrationRow(_ f: Forecast) -> [(String, String)] {
        guard let scope = f.window.scope, let name = f.window.scopeName, let c = model.calibration(tool, scope: scope) else { return [] }
        let rate = Fmt.pct(c.percentPerDollar * 100, digits: 1)
        return [("Each $100 of \(name) uses", c.earlier.map { "\(rate) (earlier weeks \(Fmt.pct($0 * 100, digits: 1)))" } ?? rate)]
    }

    @ViewBuilder private func details(_ f: Forecast) -> some View {
        let short = f.window.isShort
        let lead = f.used - f.even
        let rows: [(String, String)] = [
            ("Window started", short ? Fmt.moment(f.start, now: f.now) : Fmt.dateClock(f.start)),
            ("Resets", short ? Fmt.dayClock(f.end) : Fmt.dateClock(f.end)),
            ("Remaining", Fmt.pct(max(0, 100 - f.used), digits: 1)),
            ("Hits 100%", f.runoutDate.map(short ? Fmt.dayClock : Fmt.dateClock) ?? (f.isHit ? "Reached" : "Not before reset")),
            ("Even pace now", "\(Fmt.pct(f.even, digits: 1)) (\(String(format: "%.1f", abs(lead))) pts \(lead >= 0 ? "ahead" : "behind"))"),
            (short ? "Budget per hour" : "Budget per day", short ? Fmt.pct(f.sustainable, digits: 1) : Fmt.pct(f.sustainable * 24, digits: 1)),
            ("Forecast learns from", f.learnedFrom == 0 ? "This window so far" : "Your usual hours in \(f.learnedFrom) past window\(f.learnedFrom == 1 ? "" : "s")"),
            ("API equivalent this window", Fmt.usd(model.windowSpend(tool, scope: f.window.scope, from: f.start, to: f.end).usd)),
            (f.isEstimated ? "Last reported reading" : "Last reading",
             f.lastReported.map { Fmt.ago(f.now.timeIntervalSince($0.t)) } ?? "None yet in this window"),
        ] + calibrationRow(f)
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
