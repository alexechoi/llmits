import Foundation
import Testing
@testable import UsageCore

private let now = ISODate.parse("2026-11-21T20:15:00Z")!

/// Trimmed from a real response, plus an unknown field to check it's ignored.
private let sample = """
{
  "five_hour": null,
  "seven_day": {"utilization": 56.0, "resets_at": "2026-11-25T05:00:00.204008+00:00"},
  "seven_day_opus": null,
  "some_future_field": {"anything": [1, 2, 3]},
  "limits": [
    {"kind": "weekly_all", "group": "weekly", "percent": 56, "severity": "normal",
     "resets_at": "2026-11-25T05:00:00.204008+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 91, "severity": "critical",
     "resets_at": "2026-11-25T05:00:00.204185+00:00",
     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
  ]
}
"""

private func rows(_ json: String) throws -> [LimitRow] {
    UsageSummary.rows(from: try UsageResponse.decode(Data(json.utf8)), now: now)
}

@Suite struct UsageSummaryTests {
    @Test func rowsFromLimits() throws {
        let rows = try rows(sample)
        #expect(rows.map(\.title) == ["Session (5h)", "Weekly · all models", "Weekly · Fable"])
        #expect(rows.map(\.percent) == [nil, 56, 91])
        #expect(rows.map(\.severity) == [.normal, .normal, .critical])
        #expect(rows[1].resetsAt == ISODate.parse("2026-11-25T05:00:00.204008Z"))
        #expect(UsageSummary.tightest(rows)?.title == "Weekly · Fable")
    }

    @Test func sessionLimitWinsOverLegacyField() throws {
        let rows = try rows("""
        {"five_hour": {"utilization": 3, "resets_at": "2026-11-21T22:00:00Z"},
         "limits": [{"kind": "weekly_all", "percent": 40},
                    {"kind": "session", "group": "session", "percent": 12, "resets_at": "2026-11-21T22:00:00Z"}]}
        """)
        #expect(rows.map(\.title) == ["Session (5h)", "Weekly · all models"])
        #expect(rows.map(\.percent) == [12, 40])
    }

    @Test func legacyShapeWithoutLimits() throws {
        let rows = try rows("""
        {"five_hour": {"utilization": 30, "resets_at": "2026-11-21T22:00:00Z"},
         "seven_day": {"utilization": 80, "resets_at": "2026-11-25T05:00:00Z"},
         "seven_day_opus": {"utilization": 95}}
        """)
        #expect(rows.map(\.title) == ["Session (5h)", "Weekly · all models", "Weekly · Opus"])
        #expect(rows.map(\.severity) == [.normal, .warning, .critical])
    }

    @Test func unknownKindsGetReadableTitles() throws {
        let rows = try rows("""
        {"limits": [{"kind": "monthly_scoped", "group": "monthly", "percent": 5, "scope": {"surface": "Cowork"}},
                    {"kind": "spend", "percent": 10}]}
        """)
        #expect(rows.dropFirst().map(\.title) == ["Monthly · Cowork", "Spend"])
    }

    @Test func malformedEntriesAreDropped() throws {
        let rows = try rows("""
        {"limits": [42, {"percent": 10},
                    {"kind": "weekly_all", "percent": "lots"},
                    {"kind": "weekly_scoped", "percent": 20, "resets_at": "not a date", "scope": "weird"}]}
        """)
        #expect(rows.count == 3)  // the session row plus the two entries that have a kind
        #expect(rows[1].percent == nil)
        #expect(rows[2].percent == 20)
        #expect(rows[2].resetsAt == nil)
        #expect(rows[2].title == "Weekly · scoped")
    }

    @Test func windowsPastTheirResetAreShownAsReset() {
        let past = now.addingTimeInterval(-60)
        let usage = UsageResponse(
            fiveHour: .init(utilization: 70, resetsAt: past),
            limits: [.init(kind: "weekly_all", percent: 99, severity: "critical", resetsAt: past)]
        )
        let rows = UsageSummary.rows(from: usage, now: now)
        #expect(rows[0].percent == nil)  // a new session only starts on next use
        #expect(rows[1].percent == 0)  // a new week starts straight away
        #expect(rows[1].severity == .normal)
        #expect(rows[1].resetsAt == nil)
    }

    @Test func tightestIgnoresClosedWindowsAndBreaksTiesBySeverity() {
        let rows = [
            LimitRow(id: "session", title: "Session", percent: nil, resetsAt: nil, severity: .normal),
            LimitRow(id: "a", title: "A", percent: 80, resetsAt: nil, severity: .warning),
            LimitRow(id: "b", title: "B", percent: 80, resetsAt: nil, severity: .critical),
        ]
        #expect(UsageSummary.tightest(rows)?.id == "b")
        #expect(UsageSummary.tightest([rows[0]]) == nil)
    }

    @Test func severityFallsBackToThresholds() {
        #expect(Severity(serverValue: nil, percent: 74) == .normal)
        #expect(Severity(serverValue: nil, percent: 75) == .warning)
        #expect(Severity(serverValue: "something_new", percent: 90) == .critical)
        #expect(Severity(serverValue: "normal", percent: 95) == .normal)  // the server's word wins
    }
}

@Suite struct FormatTests {
    @Test func resetCountdowns() {
        #expect(Format.reset(now.addingTimeInterval(42 * 60), now: now) == "resets in 42m")
        #expect(Format.reset(now.addingTimeInterval(3 * 3600 + 5 * 60), now: now) == "resets in 3h 5m")
        #expect(Format.reset(now.addingTimeInterval(-1), now: now) == nil)
        #expect(Format.reset(nil, now: now) == nil)
    }

    @Test func resetMoreThanADayAwayShowsTheWeekday() {
        let date = ISODate.parse("2026-11-25T05:00:00.204008+00:00")!
        let reset = Format.reset(date, now: now, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(reset == "resets Wed 05:00")
    }

    @Test func resetTimesRoundToTheNearestMinute() {
        let date = ISODate.parse("2026-11-25T04:59:59.9Z")!
        let reset = Format.reset(date, now: now, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(reset == "resets Wed 05:00")
    }

    @Test func percent() {
        #expect(Format.percent(55.6) == "56%")
        #expect(Format.percent(0) == "0%")
        #expect(Format.percent(nil) == "—")
    }

    @Test func plan() {
        #expect(Format.plan(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Max 20x")
        #expect(Format.plan(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
        #expect(Format.plan(subscriptionType: nil, rateLimitTier: "default_claude_max_5x") == nil)
    }
}

@Suite struct CredentialTests {
    @Test func parsesClaudeCodeCredentials() throws {
        let json = """
        {"mcpOAuth": {}, "claudeAiOauth": {"accessToken": "tok", "refreshToken": "r", "expiresAt": 1795292100000,
         "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x", "scopes": ["user:inference"]}}
        """
        let credentials = try CredentialStore.parse(Data(json.utf8))
        #expect(credentials.accessToken == "tok")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_795_292_100))
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.rateLimitTier == "default_claude_max_20x")
    }

    @Test func expiryHasASafetyMargin() {
        let credentials = Credentials(accessToken: "t", expiresAt: now)
        #expect(!credentials.isExpired(at: now.addingTimeInterval(-3600)))
        #expect(credentials.isExpired(at: now.addingTimeInterval(-30)))
        #expect(!Credentials(accessToken: "t", expiresAt: nil).isExpired(at: now))
    }

    @Test func missingOrMalformedCredentials() {
        #expect(throws: CredentialError.notFound) {
            try CredentialStore.parse(Data(#"{"mcpOAuth": {}}"#.utf8))
        }
        #expect(throws: CredentialError.malformed) {
            try CredentialStore.parse(Data("not json".utf8))
        }
    }
}

@Suite struct DateParsingTests {
    @Test func acceptsMicrosecondsAndOffsets() {
        let expected = Date(timeIntervalSince1970: 1_795_582_800)  // 2026-11-25T05:00:00Z
        #expect(ISODate.parse("2026-11-25T05:00:00.204008+00:00").map { $0.timeIntervalSince1970.rounded(.down) } == expected.timeIntervalSince1970)
        #expect(ISODate.parse("2026-11-25T06:00:00+01:00") == expected)
        #expect(ISODate.parse("2026-11-25T05:00:00Z") == expected)
        #expect(ISODate.parse("garbage") == nil)
    }
}
