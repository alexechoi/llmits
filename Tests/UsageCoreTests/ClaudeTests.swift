import Foundation
import Testing
@testable import UsageCore

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
    try ClaudeUsageResponse.decode(Data(json.utf8)).rows(now: now)
}

@Suite struct ClaudeUsageTests {
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
        let usage = ClaudeUsageResponse(
            fiveHour: .init(utilization: 70, resetsAt: past),
            limits: [.init(kind: "weekly_all", percent: 99, severity: "critical", resetsAt: past)]
        )
        let rows = usage.rows(now: now)
        #expect(rows[0].percent == nil)  // a new session only starts on next use
        #expect(rows[1].percent == 0)  // a new week starts straight away
        #expect(rows[1].severity == .normal)
        #expect(rows[1].resetsAt == nil)
    }
}

@Suite struct ClaudeCredentialTests {
    @Test func parsesClaudeCodeCredentials() throws {
        let json = """
        {"mcpOAuth": {}, "claudeAiOauth": {"accessToken": "tok", "refreshToken": "r", "expiresAt": 1795292100000,
         "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x", "scopes": ["user:inference"]}}
        """
        let credentials = try ClaudeCredentialStore.parse(Data(json.utf8))
        #expect(credentials.accessToken == "tok")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_795_292_100))
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.rateLimitTier == "default_claude_max_20x")
    }

    @Test func expiryHasASafetyMargin() {
        let credentials = ClaudeCredentials(accessToken: "t", expiresAt: now)
        #expect(!credentials.isExpired(at: now.addingTimeInterval(-3600)))
        #expect(credentials.isExpired(at: now.addingTimeInterval(-30)))
        #expect(!ClaudeCredentials(accessToken: "t", expiresAt: nil).isExpired(at: now))
    }

    @Test func missingOrMalformedCredentials() {
        #expect(throws: CredentialError.notFound) {
            try ClaudeCredentialStore.parse(Data(#"{"mcpOAuth": {}}"#.utf8))
        }
        #expect(throws: CredentialError.malformed) {
            try ClaudeCredentialStore.parse(Data("not json".utf8))
        }
    }
}

@Suite struct ClaudeSourceTests {
    private let valid = ClaudeCredentials(accessToken: "token-1", expiresAt: now.addingTimeInterval(3600),
                                          subscriptionType: "max", rateLimitTier: "default_claude_max_20x")

    @Test func keepsTheTokenInMemoryBetweenPolls() async {
        let loads = Recorder<Void>()
        let requests = Recorder<[String: String]>()
        let source = ClaudeSource(
            loadCredentials: { [valid] in loads.record(()); return valid },
            get: { _, headers in requests.record(headers); return reply(200, sample) }
        )
        let first = await source.fetch(now: now)
        _ = await source.fetch(now: now.addingTimeInterval(120))

        #expect(loads.all.count == 1)  // the keychain was read once, not on every poll
        #expect(requests.all.count == 2)
        #expect(requests.all.first?["Authorization"] == "Bearer token-1")
        #expect(requests.all.first?["anthropic-beta"] == "oauth-2025-04-20")
        guard case let .success(usage) = first else {
            Issue.record("expected success, got \(first)")
            return
        }
        #expect(usage.plan == "Max 20x")
        #expect(usage.rows.count == 3)
    }

    @Test func retriesOnceWhenClaudeCodeHasRenewedTheToken() async {
        var renewed = valid
        renewed.accessToken = "token-2"
        let stored = Sequence([valid, renewed])
        let requests = Recorder<String?>()
        let source = ClaudeSource(
            loadCredentials: { stored.next() },
            get: { _, headers in
                requests.record(headers["Authorization"])
                return headers["Authorization"] == "Bearer token-2" ? reply(200, sample) : reply(401)
            }
        )
        let outcome = await source.fetch(now: now)
        #expect(requests.all == ["Bearer token-1", "Bearer token-2"])
        if case .success = outcome {} else { Issue.record("expected success, got \(outcome)") }
    }

    @Test func rejectedTokenIsReportedAsExpired() async {
        let source = ClaudeSource(loadCredentials: { [valid] in valid }, get: { _, _ in reply(401) })
        #expect(await source.fetch(now: now) == .tokenExpired(plan: "Max 20x"))
    }

    @Test func expiredTokenIsNotSent() async {
        let requests = Recorder<Void>()
        let expired = ClaudeCredentials(accessToken: "old", expiresAt: now.addingTimeInterval(-10))
        let source = ClaudeSource(loadCredentials: { expired }, get: { _, _ in requests.record(()); return reply(200, sample) })
        #expect(await source.fetch(now: now) == .tokenExpired(plan: nil))
        #expect(requests.all.isEmpty)
    }

    @Test func statusCodes() async {
        func outcome(_ reply: HTTP.Reply) async -> FetchOutcome {
            await ClaudeSource(loadCredentials: { [valid] in valid }, get: { _, _ in reply }).fetch(now: now)
        }
        #expect(await outcome(reply(403)) == .rateLimited(retryAfter: nil))
        #expect(await outcome(reply(429, retryAfter: 30)) == .rateLimited(retryAfter: 30))
        #expect(await outcome(reply(500)) == .failed(.server(status: 500)))
        #expect(await outcome(reply(200, "<html>")) == .failed(.unreadable))
    }

    @Test func noLoginIsNotSignedIn() async {
        let source = ClaudeSource(loadCredentials: { throw CredentialError.notFound }, get: { _, _ in reply(200, sample) })
        #expect(await source.fetch(now: now) == .notSignedIn)
    }

    @Test func noConnectionIsOffline() async {
        let source = ClaudeSource(loadCredentials: { [valid] in valid }, get: { _, _ in throw URLError(.notConnectedToInternet) })
        #expect(await source.fetch(now: now) == .failed(.offline))
    }

    @Test func windowLengthsComeFromTheLimitKind() throws {
        let rows = try ClaudeUsageResponse.decode(Data(sample.utf8)).rows(now: now)
        let expected: [TimeInterval?] = [18_000, 604_800, 604_800]  // 5 hours, then 7 days
        #expect(rows.map(\.windowLength) == expected)
        // 2026-11-21 20:15 is 3.36 days into the week that ends on the 25th at 05:00.
        #expect(rows[1].elapsedFraction(at: now).map { ($0 * 100).rounded() } == 52)
        #expect(rows[0].elapsedFraction(at: now) == nil)  // no session in progress
    }
}
