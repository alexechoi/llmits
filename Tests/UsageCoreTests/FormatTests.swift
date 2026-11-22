import Foundation
import Testing
@testable import UsageCore

@Suite struct FormatTests {
    @Test func resetCountdowns() {
        #expect(Format.reset(now.addingTimeInterval(42 * 60), now: now) == "Resets in 42m")
        #expect(Format.reset(now.addingTimeInterval(3 * 3600 + 5 * 60), now: now) == "Resets in 3h 5m")
        #expect(Format.reset(now.addingTimeInterval(-1), now: now) == nil)
        #expect(Format.reset(nil, now: now) == nil)
    }

    @Test func resetMoreThanADayAwayShowsTheWeekday() {
        let date = ISODate.parse("2026-11-25T05:00:00.204008+00:00")!
        #expect(Format.reset(date, now: now, locale: gb, timeZone: utc) == "Resets Wed 05:00")
    }

    @Test func resetTimesRoundToTheNearestMinute() {
        let date = ISODate.parse("2026-11-25T04:59:59.9Z")!
        #expect(Format.reset(date, now: now, locale: gb, timeZone: utc) == "Resets Wed 05:00")
    }

    @Test func resetTomorrowSaysSo() {
        let date = ISODate.parse("2026-11-22T21:00:00Z")!  // more than a day away, but tomorrow
        #expect(Format.reset(date, now: now, locale: gb, timeZone: utc) == "Resets tomorrow 21:00")
    }

    @Test func captionsSayWhetherUsageIsKeepingPace() {
        let week: TimeInterval = 604_800
        let reset = ISODate.parse("2026-11-25T05:00:00Z")!  // 52% of the week gone at `now`
        func row(_ percent: Double, resetsAt: Date = reset) -> LimitRow {
            LimitRow(id: "w", title: "Weekly", percent: percent, resetsAt: resetsAt, severity: .normal, windowLength: week)
        }
        #expect(Format.caption(row(62), now: now, locale: gb, timeZone: utc) == "Resets Wed 05:00 · ahead of pace")
        #expect(Format.caption(row(55), now: now, locale: gb, timeZone: utc) == "Resets Wed 05:00 · on track")
        #expect(Format.caption(row(35), now: now, locale: gb, timeZone: utc) == "Resets Wed 05:00 · on track")
        // Used up: pace no longer matters.
        #expect(Format.caption(row(100), now: now, locale: gb, timeZone: utc) == "Resets Wed 05:00")
        // Too early in the window to judge.
        #expect(row(30, resetsAt: now.addingTimeInterval(week * 0.95)).pace(at: now) == nil)
        // No window length, no pace.
        let unknown = LimitRow(id: "u", title: "Weekly", percent: 80, resetsAt: reset, severity: .warning)
        #expect(Format.caption(unknown, now: now, locale: gb, timeZone: utc) == "Resets Wed 05:00")
    }

    @Test func captionsExplainEmptyRows() {
        let session = LimitRow(id: "session", title: "Session (5h)", percent: nil, resetsAt: nil, severity: .normal)
        let weekly = LimitRow(id: "w", title: "Weekly", percent: nil, resetsAt: nil, severity: .normal)
        let reset = LimitRow(id: "r", title: "Weekly", percent: 0, resetsAt: nil, severity: .normal)
        #expect(Format.caption(session, now: now) == "Starts with your next message")
        #expect(Format.caption(weekly, now: now) == "No usage yet")
        #expect(Format.caption(reset, now: now) == nil)
    }

    @Test func spokenDescriptionsForVoiceOver() {
        let soon = LimitRow(id: "a", title: "Weekly · Fable", percent: 93.6,
                            resetsAt: now.addingTimeInterval(3 * 3600 + 5 * 60), severity: .critical)
        #expect(Format.spokenTitle(soon) == "Weekly, Fable")
        // The Show in Menu Bar items are labelled from titles alone.
        #expect(Format.spokenTitle("Session (5h)") == "5-hour session")
        #expect(Format.spokenTitle("Weekly · all models") == "Weekly, all models")
        #expect(Format.spokenValue(soon, now: now, locale: gb, timeZone: utc) == "Nearly used up, 93 percent used, resets in 3 hours, 5 minutes")
        #expect(Format.spokenValue(soon, stale: true, now: now, locale: gb, timeZone: utc).hasSuffix(", out of date"))

        let later = LimitRow(id: "b", title: "Weekly · all models", percent: 58,
                             resetsAt: ISODate.parse("2026-11-25T04:59:59.9Z"), severity: .normal)
        #expect(Format.spokenValue(later, now: now, locale: gb, timeZone: utc) == "58 percent used, resets Wednesday 05:00")

        let closed = LimitRow(id: "session", title: "Session (5h)", percent: nil, resetsAt: nil, severity: .normal)
        #expect(Format.spokenTitle(closed) == "5-hour session")
        #expect(Format.spokenValue(closed, now: now) == "Starts with your next message")

        let full = LimitRow(id: "f", title: "Weekly", percent: 100, resetsAt: ISODate.parse("2026-11-25T05:00:00Z"),
                            severity: .critical, windowLength: 604_800)
        #expect(Format.spokenValue(full, now: now, locale: gb, timeZone: utc)
                == "Limit reached, 100 percent used, 52 percent of the week gone, resets Wednesday 05:00")

        var busy = full
        busy.percent = 62
        busy.severity = .normal
        #expect(Format.spokenValue(busy, now: now, locale: gb, timeZone: utc)
                == "62 percent used, 52 percent of the week gone, ahead of pace, resets Wednesday 05:00")
    }

    @Test func problemsSayWhatHappensNext() {
        #expect(Format.problem(.tokenExpired, service: .claude) == "Login expired. Run Claude Code to renew it.")
        #expect(Format.problem(.tokenExpired, service: .chatGPT) == "Login expired. Run Codex to renew it.")
        #expect(Format.problem(.rateLimited(until: ISODate.parse("2026-11-21T21:15:00Z")!), service: .claude, locale: gb, timeZone: utc)
                == "Too many requests. Retrying at 21:15.")
        #expect(Format.problem(.failed(.offline), service: .claude) == "You're offline. Retrying automatically.")
        #expect(Format.problem(.failed(.server(status: 503)), service: .chatGPT) == "Couldn't load ChatGPT usage. Retrying automatically.")
        #expect(Format.problem(.failed(.unreadable), service: .claude) == "Couldn't read Claude usage. Try updating this app.")
        #expect(Format.problemDetail(.failed(.server(status: 503))) == "HTTP 503")
        #expect(Format.problemDetail(.tokenExpired) == nil)
    }

    @Test func percent() {
        #expect(Format.percent(55.6) == "55%")
        #expect(Format.percent(99.6) == "99%")  // only a used-up limit reads as 100%
        #expect(Format.percent(100) == "100%")
        #expect(Format.percent(0) == "0%")
        #expect(Format.percent(nil) == "—")
    }

    @Test func claudePlans() {
        #expect(Format.claudePlan(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Max 20x")
        #expect(Format.claudePlan(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(Format.claudePlan(subscriptionType: nil, rateLimitTier: "default_claude_max_5x") == nil)
    }

    @Test func chatGPTPlans() {
        // The labels Codex's own status screen uses.
        #expect(Format.chatGPTPlan("prolite") == "Pro 100")
        #expect(Format.chatGPTPlan("pro") == "Pro 200")
        #expect(Format.chatGPTPlan("promax") == "Pro 500")
        #expect(Format.chatGPTPlan("plus") == "Plus")
        #expect(Format.chatGPTPlan("team") == "Business")
        #expect(Format.chatGPTPlan("business") == "Enterprise")
        #expect(Format.chatGPTPlan("self_serve_business_prolite") == "Business Premium")
        #expect(Format.chatGPTPlan("ent26") == "Enterprise")
        #expect(Format.chatGPTPlan("PROLITE") == "Pro 100")
        // An unknown plan gets no name rather than a guess.
        #expect(Format.chatGPTPlan("some_new_plan") == nil)
        #expect(Format.chatGPTPlan(nil) == nil)
    }

    @Test func windowNames() {
        #expect(Format.windowName(seconds: 18_000) == "Session (5h)")
        #expect(Format.windowName(seconds: 86_400) == "Daily")
        #expect(Format.windowName(seconds: 604_800) == "Weekly")
        #expect(Format.windowName(seconds: 2_592_000) == "Monthly")
        #expect(Format.windowName(seconds: 900) == "15-minute")
        #expect(Format.windowName(seconds: 7200) == "2-hour")
        #expect(Format.windowName(seconds: 259_200) == "3-day")
        #expect(Format.windowName(seconds: nil) == "Usage")
    }
}

@Suite struct SummaryTests {
    @Test func tightestIgnoresClosedWindowsAndBreaksTiesBySeverity() {
        let rows = [
            LimitRow(id: "session", title: "Session", percent: nil, resetsAt: nil, severity: .normal),
            LimitRow(id: "a", title: "A", percent: 80, resetsAt: nil, severity: .warning),
            LimitRow(id: "b", title: "B", percent: 80, resetsAt: nil, severity: .critical),
        ]
        #expect(UsageSummary.tightest(rows)?.id == "b")
        #expect(UsageSummary.tightest([rows[0]]) == nil)
    }

    @Test func tightestAcrossServices() {
        let claude = ServiceUsage(service: .claude, plan: "Max 20x", rows: [
            LimitRow(id: "w", title: "Weekly", percent: 60, resetsAt: nil, severity: .normal),
        ])
        let chatGPT = ServiceUsage(service: .chatGPT, plan: "Plus", rows: [
            LimitRow(id: "w", title: "Weekly", percent: 85, resetsAt: nil, severity: .warning),
        ])
        let top = UsageSummary.tightest(in: [claude, chatGPT], now: now)
        #expect(top?.service == .chatGPT)
        #expect(top?.row.percent == 85)
        #expect(UsageSummary.tightest(in: [], now: now) == nil)
    }

    @Test func severityFallsBackToThresholds() {
        #expect(Severity(serverValue: nil, percent: 74) == .normal)
        #expect(Severity(serverValue: nil, percent: 75) == .warning)
        #expect(Severity(serverValue: "something_new", percent: 90) == .critical)
        #expect(Severity(serverValue: "normal", percent: 95) == .normal)  // the server's word wins
    }
}

@Suite struct DecodingTests {
    @Test func isoDatesWithMicrosecondsAndOffsets() {
        let expected = Date(timeIntervalSince1970: 1_795_582_800)  // 2026-11-25T05:00:00Z
        #expect(ISODate.parse("2026-11-25T05:00:00.204008+00:00").map { $0.timeIntervalSince1970.rounded(.down) } == expected.timeIntervalSince1970)
        #expect(ISODate.parse("2026-11-25T06:00:00+01:00") == expected)
        #expect(ISODate.parse("2026-11-25T05:00:00Z") == expected)
        #expect(ISODate.parse("garbage") == nil)
    }

    @Test func jwtExpiry() {
        #expect(JWT.expiry(of: "eyJhbGciOiJub25lIn0.eyJleHAiOjE3OTUyOTIxMDB9.sig") == Date(timeIntervalSince1970: 1_795_292_100))
        #expect(JWT.expiry(of: "not-a-jwt") == nil)
    }
}
