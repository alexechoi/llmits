import Foundation
import Testing
@testable import UsageCore

/// Regression tests for the adversarial review of the data layer: each one pins a bug that was
/// found, so it can't come back.
@Suite struct HardeningTests {
    private let claudeSample = #"{"limits": [{"kind": "weekly_all", "percent": 40, "resets_at": "2026-11-25T05:00:00Z"}]}"#
    private let chatGPTSample = #"{"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 604800}}}"#

    // MARK: Rejected tokens

    @Test func aRejectedClaudeTokenIsNeverSentAgain() async {
        let stored = Sequence([ClaudeCredentials(accessToken: "old", expiresAt: now.addingTimeInterval(3600))])
        let loads = Recorder<Void>()
        let requests = Recorder<String?>()
        let source = ClaudeSource(
            loadCredentials: { loads.record(()); return stored.next() },
            get: { _, headers in
                requests.record(headers["Authorization"])
                return headers["Authorization"] == "Bearer new" ? reply(200, #"{"limits": []}"#) : reply(401)
            }
        )
        #expect(await source.fetch(now: now) == .tokenExpired(plan: nil))
        #expect(await source.fetch(now: now.addingTimeInterval(60)) == .tokenExpired(plan: nil))
        #expect(await source.fetch(now: now.addingTimeInterval(120)) == .tokenExpired(plan: nil))
        #expect(requests.all == ["Bearer old"])  // sent once, then only the keychain is re-read
        #expect(loads.all.count == 4)
    }

    @Test func aRenewedClaudeTokenIsUsedOnceItAppears() async {
        let stored = Sequence([
            ClaudeCredentials(accessToken: "old", expiresAt: now.addingTimeInterval(3600)),
            ClaudeCredentials(accessToken: "old", expiresAt: now.addingTimeInterval(3600)),
            ClaudeCredentials(accessToken: "new", expiresAt: now.addingTimeInterval(3600)),
        ])
        let requests = Recorder<String?>()
        let source = ClaudeSource(
            loadCredentials: { stored.next() },
            get: { _, headers in
                requests.record(headers["Authorization"])
                return headers["Authorization"] == "Bearer new" ? reply(200, #"{"limits": []}"#) : reply(401)
            }
        )
        #expect(await source.fetch(now: now) == .tokenExpired(plan: nil))
        if case .success = await source.fetch(now: now.addingTimeInterval(60)) {} else { Issue.record("expected success") }
        #expect(requests.all == ["Bearer old", "Bearer new"])
    }

    @Test func aRejectedCodexTokenIsNeverSentAgain() async {
        let token = Sequence(["old", "old", "new"])
        let requests = Recorder<String?>()
        let source = ChatGPTSource(
            loadCredentials: { ChatGPTCredentials(accessToken: token.next(), accountID: nil, expiresAt: nil) },
            get: { _, headers in
                requests.record(headers["Authorization"])
                return headers["Authorization"] == "Bearer new" ? reply(200, chatGPTSample) : reply(401)
            }
        )
        #expect(await source.fetch(now: now) == .tokenExpired(plan: nil))
        #expect(await source.fetch(now: now) == .tokenExpired(plan: nil))
        if case .success = await source.fetch(now: now) {} else { Issue.record("expected success") }
        #expect(requests.all == ["Bearer old", "Bearer new"])
    }

    @Test func anAccountSwitchShowsUpWithinFifteenMinutes() async {
        let stored = Sequence([
            ClaudeCredentials(accessToken: "a", expiresAt: now.addingTimeInterval(8 * 3600), subscriptionType: "max", rateLimitTier: "default_claude_max_20x"),
            ClaudeCredentials(accessToken: "b", expiresAt: now.addingTimeInterval(8 * 3600), subscriptionType: "pro"),
        ])
        let requests = Recorder<String?>()
        let source = ClaudeSource(loadCredentials: { stored.next() }, get: { _, headers in
            requests.record(headers["Authorization"])
            return reply(200, #"{"limits": []}"#)
        })
        _ = await source.fetch(now: now)
        _ = await source.fetch(now: now.addingTimeInterval(5 * 60))
        let later = await source.fetch(now: now.addingTimeInterval(16 * 60))
        #expect(requests.all == ["Bearer a", "Bearer a", "Bearer b"])
        if case let .success(usage) = later { #expect(usage.plan == "Pro") } else { Issue.record("expected success") }
    }

    // MARK: Absurd values never crash or mislead

    @Test func absurdNumbersAreClampedNotTrapped() throws {
        let claude = try ClaudeUsageResponse.decode(Data(#"{"limits": [{"kind": "weekly_all", "percent": 1e300}, {"kind": "weekly_scoped", "percent": -5}]}"#.utf8))
        #expect(claude.limits?.map(\.percent) == [1000, 0])
        let chatGPT = try ChatGPTUsageResponse.decode(Data(#"{"rate_limit": {"primary_window": {"used_percent": "1e19", "limit_window_seconds": 1e30, "reset_at": 1e30}}}"#.utf8))
        let window = try #require(chatGPT.rateLimit?.primaryWindow)
        #expect(window.usedPercent == 1000)
        #expect(window.limitWindowSeconds == 400 * 86_400)
        #expect(window.resetAt == nil)
        #expect(Format.percent(1e300) == "1000%")
        #expect(Format.percent(.infinity) == "—")
        #expect(Format.percent(.nan) == "—")
        #expect(Format.percent(-0.4) == "0%")
        #expect(Format.reset(.distantFuture, now: now) == nil)
        let row = LimitRow(id: "x", title: "Weekly", percent: 1e300, resetsAt: .distantFuture, severity: .critical)
        #expect(Format.spokenValue(row, now: now) == "Limit reached, 1000 percent used")  // no year-4001 reset read out
    }

    @Test func numbersAndTimesInOtherShapesAreUnderstood() throws {
        let claude = try ClaudeUsageResponse.decode(Data(#"{"limits": [{"kind": "weekly_all", "percent": "42", "resets_at": 1795582800}]}"#.utf8))
        #expect(claude.limits?.first?.percent == 42)
        #expect(claude.limits?.first?.resetsAt == Date(timeIntervalSince1970: 1_795_582_800))
        let chatGPT = try ChatGPTUsageResponse.decode(Data(#"{"rate_limit": {"primary_window": {"used_percent": "35", "reset_after_seconds": 600.5, "reset_at": 1795564142000}}}"#.utf8))
        let window = try #require(chatGPT.rateLimit?.primaryWindow)
        #expect(window.usedPercent == 35)
        #expect(window.resetAfterSeconds == 601)
        #expect(window.resetAt == Date(timeIntervalSince1970: 1_795_564_142))  // milliseconds
    }

    @Test func otherRFC3339Forms() {
        let expected = Date(timeIntervalSince1970: 1_795_582_800)
        for text in ["2026-11-25 05:00:00Z", "2026-11-25t05:00:00z", "2026-11-25T05:00:00", "2026-11-25T05:00:00+0000"] {
            #expect(ISODate.parse(text) == expected, "\(text)")
        }
        #expect(ISODate.parse("9999-01-01T00:00:00Z") == nil)  // implausible, treated as unknown
    }

    @Test func floatingPointNoiseDoesNotLoseAPoint() {
        #expect(Format.percent(0.29 * 100) == "29%")
        #expect(Format.percent(0.58 * 100) == "58%")
    }

    // MARK: Times

    @Test func resetsSixOrMoreDaysAwayIncludeTheDate() {
        let day: TimeInterval = 86_400
        #expect(Format.reset(now.addingTimeInterval(5 * day), now: now, locale: gb, timeZone: utc) == "Resets Thu 20:15")
        #expect(Format.reset(now.addingTimeInterval(7 * day), now: now, locale: gb, timeZone: utc) == "Resets Sat 28 Nov at 20:15")
        // Just after a weekly reset, next week's is no longer mistaken for today.
        let justAfter = ISODate.parse("2026-11-25T05:30:00Z")!
        #expect(Format.reset(ISODate.parse("2026-12-02T05:00:00Z"), now: justAfter, locale: gb, timeZone: utc) == "Resets Wed 2 Dec at 05:00")
        let row = LimitRow(id: "w", title: "Weekly", percent: 1, resetsAt: now.addingTimeInterval(7 * day), severity: .normal)
        #expect(Format.spokenValue(row, now: now, locale: gb, timeZone: utc) == "1 percent used, resets Saturday 28 November at 20:15")
    }

    @Test func retryAfterIsParsedSafely() {
        #expect(HTTP.retryAfter("120") == 120)
        #expect(HTTP.retryAfter(" 30 ") == 30)
        #expect(HTTP.retryAfter("-5") == 0)
        #expect(HTTP.retryAfter("999999") == 86_400)
        #expect(HTTP.retryAfter("inf") == nil)
        #expect(HTTP.retryAfter("nan") == nil)
        #expect(HTTP.retryAfter("soon") == nil)
        #expect(HTTP.retryAfter(nil) == nil)
        #expect(HTTP.retryAfter("Sat, 21 Nov 2026 20:25:00 GMT", now: now) == 600)
    }

    @Test func nonFiniteRetryAfterFallsBackToTheDefault() {
        for retryAfter in [TimeInterval.infinity, .nan, -1] {
            var tracker = UsageTracker()
            tracker.record(.rateLimited(retryAfter: retryAfter), for: .claude, at: now)
            #expect(tracker.state(of: .claude)?.nextFetch == now.addingTimeInterval(UsageTracker.rateLimitBackoff), "\(retryAfter)")
        }
    }

    @Test func aSlowServerIsNotCalledOffline() {
        #expect(Failure(URLError(.timedOut)) != .offline)
        #expect(Failure(URLError(.notConnectedToInternet)) == .offline)
    }

    // MARK: Names

    @Test func emptyNamesFallBack() throws {
        let chatGPT = try ChatGPTUsageResponse.decode(Data(#"""
            {"additional_rate_limits": [
              {"limit_name": "", "metered_feature": "codex_other", "rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 604800}}},
              {"limit_name": " ", "metered_feature": "", "rate_limit": {"primary_window": {"used_percent": 2, "limit_window_seconds": 604800}}}
            ]}
            """#.utf8))
        #expect(chatGPT.rows(now: now).map(\.title) == ["Weekly · Codex other", "Weekly · Other"])
        let claude = try ClaudeUsageResponse.decode(Data(#"{"limits": [{"kind": "", "percent": 5}]}"#.utf8))
        #expect(claude.rows(now: now).last?.title == "Limit")
        #expect(Format.windowName(seconds: 1) == "1-minute")
        #expect(Format.windowName(seconds: 29) == "1-minute")
    }

    // MARK: Stored logins in other shapes

    @Test func claudeLoginVariants() throws {
        let asString = try ClaudeCredentialStore.parse(Data(#"{"claudeAiOauth": {"accessToken": "t", "expiresAt": "1795292100000", "rateLimitTier": {"odd": true}}}"#.utf8))
        #expect(asString.expiresAt == Date(timeIntervalSince1970: 1_795_292_100))
        #expect(asString.rateLimitTier == nil)
        let inSeconds = try ClaudeCredentialStore.parse(Data(#"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1795292100}}"#.utf8))
        #expect(inSeconds.expiresAt == Date(timeIntervalSince1970: 1_795_292_100))
        // `security -w` prints hex when the item holds non-printable bytes.
        let json = #"{"claudeAiOauth": {"accessToken": "hex"}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined() + "\n"
        guard case let .found(data) = ClaudeCredentialStore.keychainRead(status: 0, output: Data(hex.utf8)) else {
            Issue.record("expected found")
            return
        }
        #expect(try ClaudeCredentialStore.parse(data).accessToken == "hex")
    }

    @Test func codexLoginVariants() throws {
        let numericAccount = try ChatGPTCredentialStore.parse(Data(#"{"tokens": {"access_token": "t", "account_id": 42}}"#.utf8))
        #expect(numericAccount.accountID == "42")
    }
}
