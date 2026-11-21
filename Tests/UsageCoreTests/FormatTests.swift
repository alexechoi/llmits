import Foundation
import Testing
@testable import UsageCore

@Suite struct FormatTests {
    @Test func resetCountdowns() {
        #expect(Format.reset(now.addingTimeInterval(42 * 60), now: now) == "resets in 42m")
        #expect(Format.reset(now.addingTimeInterval(3 * 3600 + 5 * 60), now: now) == "resets in 3h 5m")
        #expect(Format.reset(now.addingTimeInterval(-1), now: now) == nil)
        #expect(Format.reset(nil, now: now) == nil)
    }

    @Test func resetMoreThanADayAwayShowsTheWeekday() {
        let date = ISODate.parse("2026-11-25T05:00:00.204008+00:00")!
        #expect(Format.reset(date, now: now, locale: gb, timeZone: utc) == "resets Wed 05:00")
    }

    @Test func resetTimesRoundToTheNearestMinute() {
        let date = ISODate.parse("2026-11-25T04:59:59.9Z")!
        #expect(Format.reset(date, now: now, locale: gb, timeZone: utc) == "resets Wed 05:00")
    }

    @Test func spokenDescriptionsForVoiceOver() {
        let soon = LimitRow(id: "a", title: "Weekly · Fable", percent: 93.6,
                            resetsAt: now.addingTimeInterval(3 * 3600 + 5 * 60), severity: .critical)
        #expect(Format.spokenTitle(soon) == "Weekly, Fable")
        #expect(Format.spokenValue(soon, now: now, locale: gb, timeZone: utc) == "94 percent used, resets in 3 hours, 5 minutes")

        let later = LimitRow(id: "b", title: "Weekly · all models", percent: 58,
                             resetsAt: ISODate.parse("2026-11-25T04:59:59.9Z"), severity: .normal)
        #expect(Format.spokenValue(later, now: now, locale: gb, timeZone: utc) == "58 percent used, resets Wednesday 05:00")

        let closed = LimitRow(id: "session", title: "Session (5h)", percent: nil, resetsAt: nil, severity: .normal)
        #expect(Format.spokenValue(closed, now: now) == "No active session")
    }

    @Test func percent() {
        #expect(Format.percent(55.6) == "56%")
        #expect(Format.percent(0) == "0%")
        #expect(Format.percent(nil) == "—")
    }

    @Test func claudePlans() {
        #expect(Format.claudePlan(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Max 20x")
        #expect(Format.claudePlan(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(Format.claudePlan(subscriptionType: nil, rateLimitTier: "default_claude_max_5x") == nil)
    }

    @Test func chatGPTPlans() {
        #expect(Format.chatGPTPlan("prolite") == "Pro Lite")
        #expect(Format.chatGPTPlan("plus") == "Plus")
        #expect(Format.chatGPTPlan("ent26") == "Enterprise")
        #expect(Format.chatGPTPlan("self_serve_business_usage_based") == "Business")
        #expect(Format.chatGPTPlan("some_new_plan") == "Some New Plan")
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
