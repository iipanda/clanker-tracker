import Charts
import ClankerCore
import SwiftUI

/// Usage over the window: recorded line, dashed projection (following your usual hours, ending where
/// it would hit 100%), and a faint dotted even-pace line from 0% to 100%.
struct BurnChart: View {
    let f: Forecast
    @State private var selected: Date?

    private struct Point: Identifiable {
        let id: Int
        let t: Date
        let v: Double
    }

    var body: some View {
        let usage = usagePoints
        let projection = f.projectionPoints().enumerated().map { Point(id: $0.offset, t: $0.element.t, v: $0.element.pct) }
        let projectionEnd = projection.last ?? Point(id: 0, t: f.now, v: f.used)

        Chart {
            ForEach([Point(id: 0, t: f.start, v: 0), Point(id: 1, t: f.end, v: 100)]) { p in
                LineMark(x: .value("Time", p.t), y: .value("Used", p.v), series: .value("Series", "even"))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 4]))
            }
            ForEach(projection) { p in
                LineMark(x: .value("Time", p.t), y: .value("Used", p.v), series: .value("Series", "projection"))
                    .foregroundStyle(Palette.accent.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
            }
            ForEach(usage) { p in
                LineMark(x: .value("Time", p.t), y: .value("Used", p.v), series: .value("Series", "usage"))
                    .foregroundStyle(Palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if f.runsOut {
                PointMark(x: .value("Time", projectionEnd.t), y: .value("Used", 100))
                    .symbol { Circle().strokeBorder(Palette.warn, lineWidth: 1.75).background(Circle().fill(.background)).frame(width: 9, height: 9) }
            }
            PointMark(x: .value("Time", f.now), y: .value("Used", f.used))
                .symbol { Circle().fill(Palette.accent).overlay(Circle().stroke(.background, lineWidth: 2)).frame(width: 9, height: 9) }

            if let selected {
                let v = f.estimate(at: selected)
                RuleMark(x: .value("Time", selected))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HStack(spacing: 4) {
                            Text("\(Fmt.pct(v, digits: 1)) \(selected <= f.now ? "used" : "projected")")
                            Text("· \(Fmt.moment(selected, now: f.now))").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXScale(domain: f.start...f.end)
        .chartYScale(domain: 0...104) // headroom so marks at 100% aren't clipped
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Palette.line)
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisValueLabel(centered: false) {
                    if let d = value.as(Date.self) {
                        Text(f.window.isShort ? d.formatted(.dateTime.hour()) : Fmt.weekday(d))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: 150)
        .accessibilityLabel(accessibilityText)
    }

    private var usagePoints: [Point] {
        var pts = f.curve.enumerated().map { Point(id: $0.offset, t: $0.element.t, v: $0.element.pct) }
        if let last = pts.last, last.t < f.now { pts.append(Point(id: pts.count, t: f.now, v: f.used)) }
        return pts
    }

    /// Noon of each day for weekly windows (the label sits in the middle of its day), each hour for short ones.
    private var xTicks: [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        if f.window.isShort {
            guard var d = cal.nextDate(after: f.start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) else { return [] }
            while d < f.end { out.append(d); d = d.addingTimeInterval(3600) }
        } else {
            guard var d = cal.nextDate(after: f.start, matching: DateComponents(hour: 12), matchingPolicy: .nextTime) else { return [] }
            while d < f.end {
                out.append(d)
                d = cal.date(byAdding: .day, value: 1, to: d) ?? f.end
            }
        }
        return out
    }

    private var accessibilityText: String {
        "\(Fmt.pct(f.used)) used" + (f.runoutDate.map { ", projected to run out at \(Fmt.moment($0, now: f.now))" } ?? ", about \(Fmt.pct(f.projected)) at reset")
    }
}

struct ChartLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            item("Used") { Capsule().fill(Palette.accent).frame(width: 14, height: 2) }
            item("Forecast") { Dashes(color: Palette.accent.opacity(0.7), dash: [4, 3]) }
            item("Even pace") { Dashes(color: .secondary, dash: [1, 3]) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func item(_ title: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 6) { swatch(); Text(title) }
    }

    private struct Dashes: View {
        let color: Color
        let dash: [CGFloat]
        var body: some View {
            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dash))
                .frame(width: 14, height: 2)
        }
    }
}
