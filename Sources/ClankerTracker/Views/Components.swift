import ClankerCore
import SwiftUI

struct UsageBar: View {
    var pct: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.accent)
                    .frame(width: max(pct > 0 ? height : 0, geo.size.width * min(1, max(0, pct / 100))))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.4), value: pct)
        .accessibilityElement()
        .accessibilityLabel("\(Fmt.pct(pct)) used")
    }
}

/// One-line summary of a forecast, used in the popover and cards.
enum StatusText {
    struct Line {
        var text: String
        var color: Color?
    }

    static func line(_ f: Forecast) -> Line {
        if f.isReset { return Line(text: "Reset at \(Fmt.moment(f.end, now: f.now))", color: nil) }
        if f.isHit { return Line(text: "Limit reached · back in \(Fmt.duration(hours: f.leftHours))", color: Palette.crit) }
        if let runout = f.runoutDate { return Line(text: "Runs out ~\(Fmt.moment(runout, now: f.now))", color: Palette.warn) }
        if let runout = f.spikeRunoutDate { return Line(text: "Runs out ~\(Fmt.moment(runout, now: f.now)) at this pace", color: Palette.warn) }
        return Line(text: "On track · ~\(Fmt.pct(f.projected)) at reset", color: nil)
    }

    static func resets(_ f: Forecast) -> String {
        if f.isReset { return "Waiting for next use" }
        return "Resets " + Fmt.moment(f.end, now: f.now)
    }

    /// "Estimated from Fable usage since the Tue 04:15 reading"
    static func estimateNote(_ f: Forecast) -> String? {
        guard f.isEstimated, let scope = f.window.scopeName else { return nil }
        guard let r = f.lastReported else { return "Estimated from \(scope) usage this window" }
        return "Estimated from \(scope) usage since the \(Fmt.moment(r.t, now: f.now)) reading"
    }

    static func staleness(_ f: Forecast) -> String? {
        guard f.isStale, !f.isEstimated else { return nil }
        let ago = Fmt.ago(f.now.timeIntervalSince(f.lastSeen))
        return f.tool == .claude ? "Last reading \(ago) · updates while Claude Code runs" : "Last reading \(ago)"
    }
}

struct EmptyToolMessage: View {
    let tool: Tool
    let model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            if tool == .claude, !model.collector.isInstalled, model.collector != .settingsUnreadable, !compact {
                Button("Set up collector") { model.pane = .settings }
                    .controlSize(.small)
            }
        }
        .font(compact ? .caption : .callout)
    }

    private var title: String {
        switch tool {
        case .codex:
            model.hasLoaded ? "No Codex usage in the last 8 days." : "Reading Codex logs…"
        case .claude:
            model.collector.isInstalled
                ? "Waiting for your next Claude Code message."
                : compact ? "Set up the collector in Settings to track Claude Code."
                : "Claude Code reports its limits only to its status line. Set up the collector in Settings to save them."
        }
    }
}

/// The small "5h | 7d" switch from the design.
struct WindowSwitch: View {
    let options: [(id: Int, title: String)]
    let selection: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let on = option.id == selection
                Button { select(option.id) } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 5).fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 0.75, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.track, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Limit window")
    }
}
