import Foundation
import Testing
@testable import ClankerCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func window(_ minutes: Int, elapsedHours: Double, _ readings: [(Double, Double)], tool: Tool = .claude) -> LimitWindow {
    let start = now.addingTimeInterval(-elapsedHours * 3600)
    return LimitWindow(
        tool: tool, minutes: minutes, resetsAt: start.addingTimeInterval(TimeInterval(minutes) * 60),
        points: readings.map { Reading(t: start.addingTimeInterval($0.0 * 3600), pct: $0.1) }
    )
}

@Suite struct DesignGoldenTests {
    let history = DemoData.history(now: now)

    @Test func claudeFiveHourRunsOut() throws {
        let f = try #require(history.currentForecasts(for: .claude, now: now).first { $0.window.minutes == 300 })
        #expect(abs(f.used - 72) < 0.001)
        #expect(abs(f.pace - 40) < 0.001)
        #expect(abs(f.sustainable - 17.5) < 0.001)
        #expect(f.runsOut)
        #expect(f.runoutHours > 0.3 && f.runoutHours < 1.6)
        #expect(!f.isStale)
    }

    @Test func claudeWeeklyAndCodexWeekly() throws {
        let claude = try #require(history.currentForecasts(for: .claude, now: now).first { $0.window.minutes == 10080 })
        #expect(abs(claude.used - 41) < 0.001)
        #expect(abs(claude.pace - 0.6615) < 0.001)
        let codex = try #require(history.currentForecasts(for: .codex, now: now).first)
        #expect(abs(codex.pace - 0.25) < 0.001)
        #expect(abs(codex.used - 35.5) < 0.001)
        #expect(!codex.runsOut)
        #expect(codex.projected > codex.used && codex.projected < 100)
    }

    @Test func tightestIsClaudeFiveHour() throws {
        let t = try #require(Tightest.pick(history.currentForecasts(now: now)))
        #expect(t.tool == .claude && t.window.minutes == 300)
    }

    @Test func pastWeeksEndWithCurrent() {
        let bars = PastWeeks.bars(history, tool: .claude, now: now)
        #expect(bars.map(\.peak) == [62, 88, 100, 74, 55, 93, 100, 41])
        #expect(bars.last?.isCurrent == true)
        #expect(bars.dropLast().allSatisfy { !$0.isCurrent })
    }

    @Test func projectionFollowsTheChosenEstimator() throws {
        let f = try #require(history.currentForecasts(for: .codex, now: now).first)
        let points = f.projectionPoints()
        #expect(points.first?.pct == f.used)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.pct <= $1.pct })
        #expect(abs((points.last?.pct ?? 0) - f.projected) < 0.001)
    }
}

@Suite struct ForecastEdgeTests {
    @Test func paceUsesElapsedWhenShorterThanLookback() {
        let f = Forecast(window(300, elapsedHours: 0.5, [(0.5, 10)]), heartbeat: now, now: now)
        #expect(abs(f.pace - 20) < 0.001)
    }

    @Test func noReadingsInLookbackMeansNoPace() {
        let f = Forecast(window(10080, elapsedHours: 30, [(10, 20)]), heartbeat: now, now: now, estimator: LinearPace(lookback: 6 * 3600))
        #expect(f.pace == 0)
        #expect(!f.runsOut)
        #expect(f.projected == 20)
        #expect(f.runoutHours == .infinity)
    }

    @Test func aShortBurstFades() {
        // A quiet past week, then 25 points in the last hour: linear pace over the hour says it runs out
        // within a day; the chosen estimator expects the burst to calm down to the usual pace.
        let past = window(10080, elapsedHours: 7 * 24 + 30, (1...167).map { (Double($0), Double($0) * 0.3) })
        let w = window(10080, elapsedHours: 30, [(10, 5), (29, 5), (30, 30)])
        let series = [WindowSeries(past, end: past.resetsAt)]
        let linear = Forecast(w, heartbeat: now, now: now, past: series, estimator: LinearPace(lookback: 3600))
        let chosen = Forecast(w, heartbeat: now, now: now, past: series)
        #expect(linear.runsOut && linear.runoutHours < 3)
        #expect(chosen.runoutHours > 24)
    }

    @Test func afterResetShowsZero() {
        let w = window(300, elapsedHours: 6, [(1, 30), (4, 60)])
        let f = Forecast(w, heartbeat: now, now: now)
        #expect(f.isReset)
        #expect(f.used == 0)
        #expect(!f.runsOut && !f.isHit)
    }

    @Test func resetWindowIsNotTightest() throws {
        let reset = Forecast(window(300, elapsedHours: 6, [(4, 90)]), now: now)
        let live = Forecast(window(10080, elapsedHours: 10, [(9, 12)], tool: .codex), now: now)
        #expect(try #require(Tightest.pick([reset, live])).tool == .codex)
    }

    @Test func staleAfterThirtyMinutesForShortWindows() {
        let w = window(300, elapsedHours: 3, [(1, 30)])
        #expect(Forecast(w, now: now).isStale)
        #expect(!Forecast(w, heartbeat: now.addingTimeInterval(-60), now: now).isStale)
    }

    @Test func noWarningDuringWarmup() {
        let f = Forecast(window(300, elapsedHours: 0.05, [(0.05, 20)]), heartbeat: now, now: now)
        #expect(f.pace > 100)
        #expect(!f.runsOut)
    }

    @Test func hitLimitComesFirst() throws {
        let hit = Forecast(window(10080, elapsedHours: 100, [(99, 100)]), heartbeat: now, now: now)
        let hot = Forecast(window(300, elapsedHours: 3, [(2, 50), (3, 90)], tool: .codex), heartbeat: now, now: now)
        #expect(hit.isHit && !hit.runsOut)
        #expect(hot.runsOut)
        #expect(try #require(Tightest.pick([hot, hit])).id == hit.id)
    }

    @Test func curveNeverDecreases() {
        let f = Forecast(window(300, elapsedHours: 3, [(1, 30), (2, 28), (3, 35)]), now: now)
        #expect(f.curve.map(\.pct) == [0, 30, 30, 35])
    }
}

@Suite struct MomentFormatTests {
    let cal = Calendar.current
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12, minute: 5))! }

    func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func laterTodayIsJustTheTime() {
        #expect(Fmt.moment(at(day: 24, hour: 23, minute: 50), now: now) == Fmt.clock(at(day: 24, hour: 23, minute: 50)))
    }

    /// 13:58 tomorrow while it's 12:05 today would otherwise read as two hours from now.
    @Test func anotherDayCarriesTheWeekday() {
        let tomorrow = at(day: 25, hour: 13, minute: 58)
        #expect(Fmt.moment(tomorrow, now: now) == Fmt.dayClock(tomorrow))
        #expect(Fmt.moment(tomorrow, now: now) != Fmt.clock(tomorrow))
        let yesterday = at(day: 23, hour: 9)
        #expect(Fmt.moment(yesterday, now: now) == Fmt.dayClock(yesterday))
    }

    @Test func justPastMidnightIsTomorrow() {
        let late = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 23, minute: 30))!
        let after = at(day: 25, hour: 0, minute: 10)
        #expect(Fmt.moment(after, now: late) == Fmt.dayClock(after))
    }

    @Test func sameWeekdayNextWeekGetsTheDate() {
        let nextWeek = at(day: 30, hour: 9, minute: 52)
        #expect(Fmt.moment(nextWeek, now: now) == Fmt.dayClock(nextWeek))
        // Thursday again, a week out: "Thu 09:00" would read as today.
        let oct1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
        #expect(Fmt.moment(oct1, now: now) == Fmt.dateClock(oct1))
    }
}

@Suite struct HistoryTests {
    func sample(_ minutes: Int, reset: TimeInterval, at t: TimeInterval, _ pct: Double, tool: Tool = .codex) -> Sample {
        Sample(tool: tool, minutes: minutes, resetsAt: Date(timeIntervalSince1970: reset), reading: Reading(t: Date(timeIntervalSince1970: t), pct: pct))
    }

    @Test func jitteredResetsShareAWindow() {
        var h = UsageHistory()
        h.add(sample(300, reset: 10_000, at: 1_000, 5))
        h.add(sample(300, reset: 10_060, at: 2_000, 9))
        h.add(sample(300, reset: 28_000, at: 20_000, 3))
        #expect(h.windows.count == 2)
        #expect(h.windows[0].points.count == 2)
    }

    @Test func earlyResetEndsPreviousWindow() {
        var h = UsageHistory()
        h.add(sample(10080, reset: 1_000_000, at: 500_000, 40))
        h.add(sample(10080, reset: 1_500_000, at: 900_000, 2))
        let old = h.windows(for: .codex)[0]
        #expect(h.effectiveEnd(of: old) == Date(timeIntervalSince1970: 900_000))
        #expect(h.effectiveEnd(of: h.windows(for: .codex)[1]) == Date(timeIntervalSince1970: 1_500_000))
    }

    @Test func endedWindowsMatchEffectiveEndsAndLeaveOutRunningOnes() {
        var h = UsageHistory()
        h.add(sample(10080, reset: 1_000_000, at: 500_000, 40))
        h.add(sample(10080, reset: 1_000_000, at: 880_000, 100))
        h.add(sample(10080, reset: 1_500_000, at: 900_000, 2))   // took over early
        h.add(sample(10080, reset: 1_600_000, at: 1_000_000, 7)) // overlaps the one before
        h.add(sample(10080, reset: 1_600_000, at: 1_200_000, 9))
        h.add(sample(10080, reset: 1_500_000, at: 1_300_000, 5))
        let ended = h.endedWindows(tool: .codex, minutes: 10080, scope: nil, now: Date(timeIntervalSince1970: 1_550_000))
        #expect(ended.map(\.end) == [Date(timeIntervalSince1970: 900_000), Date(timeIntervalSince1970: 1_500_000)])
        for e in ended { #expect(e.end == h.effectiveEnd(of: e.window)) }
        #expect(ended[0].endedEarly && !ended[1].endedEarly)
        #expect(ended[0].hitAt == Date(timeIntervalSince1970: 880_000))
        #expect(ended[0].curve.last?.t == ended[0].end)
    }

    @Test func mergingIsIdempotentAndOrderFree() {
        let samples = (0..<50).map { sample(10080, reset: 1_000_000, at: 400_000 + Double($0) * 600, Double($0 / 5)) }
        var a = UsageHistory(), b = UsageHistory()
        a.add(contentsOf: samples)
        a.add(contentsOf: samples)
        b.add(contentsOf: samples.shuffled())
        #expect(a == b)
        // 10 distinct values, each a run of 5 kept as first + last.
        #expect(a.windows[0].points.count == 20)
    }

    @Test func readingsOutsideTheirWindowAreDropped() {
        var h = UsageHistory()
        h.add(sample(10080, reset: 1_000_000, at: 1_000_000 - 30 * 86400, 13))
        h.add(sample(10080, reset: 1_000_000, at: 1_000_000 + 86400, 13))
        #expect(h.windows.isEmpty)
    }

    @Test func currentWindowIsTheOneLastUsed() {
        var h = UsageHistory()
        let n = now.timeIntervalSince1970
        // Overlapping windows after an early reset: the older one got the latest reading.
        h.add(sample(10080, reset: n + 5 * 86400, at: n - 60, 40))
        h.add(sample(10080, reset: n + 6 * 86400, at: n - 3 * 3600, 10))
        #expect(h.currentForecasts(for: .codex, now: now).first?.used == 40)
    }

    @Test func retiredKindsAreHidden() {
        var h = UsageHistory()
        let n = now.timeIntervalSince1970
        h.add(sample(300, reset: n - 20 * 86400, at: n - 20 * 86400 - 3600, 50))
        h.add(sample(10080, reset: n + 3 * 86400, at: n - 3600, 20))
        #expect(h.currentForecasts(for: .codex, now: now).map(\.window.minutes) == [10080])
    }
}
