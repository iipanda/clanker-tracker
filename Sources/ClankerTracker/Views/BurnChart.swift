import Charts
import ClankerCore
import SwiftUI

/// Usage over the window: recorded line, dashed projection (following your usual hours, ending where
/// it would hit 100%), and a faint dotted even-pace line from 0% to 100%. For an ended window, just
/// what was recorded.
struct BurnChart: View {
    private let start: Date
    private let end: Date
    /// Where the even-pace line stops: 100% at the reset, less where a window was reset early.
    private let evenEnd: Double
    private let usage: [Point]
    private let projection: [Point]
    /// The latest value, marked with a dot while the window runs.
    private let latest: Point?
    private let runout: Date?
    private let isShort: Bool
    /// Before this the hover shows recorded usage, after it the projection.
    private let now: Date
    private let value: (Date) -> Double
    private let accessibilityText: String
    @State private var selected: Date?

    private struct Point: Identifiable {
        let id: Int
        let t: Date
        let v: Double
    }

    init(f: Forecast) {
        start = f.start
        end = f.end
        evenEnd = 100
        var pts = f.curve.enumerated().map { Point(id: $0.offset, t: $0.element.t, v: $0.element.pct) }
        if let last = pts.last, last.t < f.now { pts.append(Point(id: pts.count, t: f.now, v: f.used)) }
        usage = pts
        projection = f.projectionPoints().enumerated().map { Point(id: $0.offset, t: $0.element.t, v: $0.element.pct) }
        latest = Point(id: 0, t: f.now, v: f.used)
        runout = f.runsOut ? (projection.last?.t ?? f.now) : nil
        isShort = f.window.isShort
        now = f.now
        value = f.estimate(at:)
        accessibilityText = "\(Fmt.pct(f.used)) used"
            + (f.runoutDate.map { ", projected to run out at \(Fmt.moment($0, now: f.now))" } ?? ", about \(Fmt.pct(f.projected)) at reset")
    }

    init(past w: EndedWindow, now: Date) {
        start = w.start
        end = w.end
        evenEnd = min(100, w.end.timeIntervalSince(w.start) / w.window.duration * 100)
        usage = w.curve.enumerated().map { Point(id: $0.offset, t: $0.element.t, v: $0.element.pct) }
        projection = []
        latest = nil
        runout = nil
        isShort = w.window.isShort
        self.now = now
        value = w.value(at:)
        accessibilityText = "Peaked at \(Fmt.pct(w.peak)), ended \(Fmt.moment(w.end, now: now))"
    }

    var body: some View {
        Chart {
            ForEach([Point(id: 0, t: start, v: 0), Point(id: 1, t: end, v: evenEnd)]) { p in
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
            if let runout {
                PointMark(x: .value("Time", runout), y: .value("Used", 100))
                    .symbol { Circle().strokeBorder(Palette.warn, lineWidth: 1.75).background(Circle().fill(.background)).frame(width: 9, height: 9) }
            }
            if let latest {
                PointMark(x: .value("Time", latest.t), y: .value("Used", latest.v))
                    .symbol { Circle().fill(Palette.accent).overlay(Circle().stroke(.background, lineWidth: 2)).frame(width: 9, height: 9) }
            }

            if let selected {
                let v = value(selected)
                RuleMark(x: .value("Time", selected))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HStack(spacing: 4) {
                            Text("\(Fmt.pct(v, digits: 1)) \(selected <= now ? "used" : "projected")")
                            Text("· \(Fmt.moment(selected, now: now))").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXScale(domain: start...end)
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
                        Text(isShort ? d.formatted(.dateTime.hour()) : Fmt.weekday(d))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: 150)
        .accessibilityLabel(accessibilityText)
    }

    /// Noon of each day for weekly windows (the label sits in the middle of its day), each hour for short ones.
    private var xTicks: [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        if isShort {
            guard var d = cal.nextDate(after: start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) else { return [] }
            while d < end { out.append(d); d = d.addingTimeInterval(3600) }
        } else {
            guard var d = cal.nextDate(after: start, matching: DateComponents(hour: 12), matchingPolicy: .nextTime) else { return [] }
            while d < end {
                out.append(d)
                d = cal.date(byAdding: .day, value: 1, to: d) ?? end
            }
        }
        return out
    }
}

struct ChartLegend: View {
    var forecast = true

    var body: some View {
        HStack(spacing: 16) {
            item("Used") { Capsule().fill(Palette.accent).frame(width: 14, height: 2) }
            if forecast { item("Forecast") { Dashes(color: Palette.accent.opacity(0.7), dash: [4, 3]) } }
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
