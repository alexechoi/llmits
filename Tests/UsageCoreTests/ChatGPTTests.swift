import Foundation
import Testing
@testable import UsageCore

/// The shape of a real response, with the personal fields removed.
private let sample = """
{
  "plan_type": "prolite",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {"used_percent": 35, "limit_window_seconds": 604800, "reset_after_seconds": 270010, "reset_at": 1795564142},
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": null,
  "credits": {"has_credits": false, "unlimited": false, "balance": "0"},
  "spend_control": {"reached": false, "individual_limit": null},
  "rate_limit_reached_type": null,
  "something_new": [1, 2, 3]
}
"""

private func rows(_ json: String) throws -> [LimitRow] {
    try ChatGPTUsageResponse.decode(Data(json.utf8)).rows(now: now)
}

@Suite struct ChatGPTUsageTests {
    @Test func weeklyPlanLimit() throws {
        let usage = try ChatGPTUsageResponse.decode(Data(sample.utf8))
        #expect(Format.chatGPTPlan(usage.planType) == "Pro Lite")
        let rows = usage.rows(now: now)
        #expect(rows.map(\.title) == ["Weekly"])
        #expect(rows.map(\.percent) == [35])
        #expect(rows.first?.resetsAt == Date(timeIntervalSince1970: 1_795_564_142))
        #expect(rows.first?.severity == .normal)
    }

    @Test func everyKindOfWindow() throws {
        let rows = try rows("""
        {"plan_type": "plus",
         "rate_limit": {"primary_window": {"used_percent": 80, "limit_window_seconds": 18000, "reset_after_seconds": 600},
                        "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800, "reset_at": 1795564142}},
         "code_review_rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 604800}},
         "additional_rate_limits": [
           {"limit_name": "codex_other", "metered_feature": "codex_other",
            "rate_limit": {"primary_window": {"used_percent": 70, "limit_window_seconds": 900}}},
           "not an object"
         ]}
        """)
        // The malformed extra entry is dropped rather than failing the response.
        #expect(rows.map(\.title) == ["Session (5h)", "Weekly", "Weekly · Code review", "15-minute · Codex other"])
        #expect(rows.map(\.percent) == [80, 40, 10, 70])
        #expect(rows[0].severity == .warning)
        #expect(rows[0].resetsAt == now.addingTimeInterval(600))  // from reset_after_seconds
    }

    @Test func reachedLimitIsCritical() throws {
        let rows = try rows("""
        {"rate_limit": {"allowed": false, "limit_reached": true,
                        "primary_window": {"used_percent": 60, "limit_window_seconds": 18000},
                        "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800}}}
        """)
        #expect(rows.map(\.severity) == [.normal, .critical])
    }

    @Test func noLimitsGivesNoRows() throws {
        #expect(try rows(#"{"plan_type": "pro", "rate_limit": null}"#).isEmpty)
    }
}

@Suite struct ChatGPTCredentialTests {
    /// A token whose payload is `{"exp": 1795292100}`.
    private let token = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3OTUyOTIxMDB9.sig"

    @Test func parsesTheCodexLogin() throws {
        let json = """
        {"auth_mode": "chatgpt", "OPENAI_API_KEY": null,
         "tokens": {"id_token": "x", "access_token": "\(token)", "refresh_token": "r", "account_id": "acct-1"},
         "last_refresh": "2026-11-20T21:44:14Z"}
        """
        let credentials = try ChatGPTCredentialStore.parse(Data(json.utf8))
        #expect(credentials.accessToken == token)
        #expect(credentials.accountID == "acct-1")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_795_292_100))
    }

    @Test func apiKeyLoginHasNoPlanLimits() {
        #expect(throws: CredentialError.notFound) {
            try ChatGPTCredentialStore.parse(Data(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-test"}"#.utf8))
        }
    }

    @Test func honoursCodexHome() {
        #expect(ChatGPTCredentialStore.authFile(environment: ["CODEX_HOME": "/tmp/codex"]).path == "/tmp/codex/auth.json")
        #expect(ChatGPTCredentialStore.authFile(environment: [:]).path.hasSuffix("/.codex/auth.json"))
    }
}

@Suite struct ChatGPTSourceTests {
    private let valid = ChatGPTCredentials(accessToken: "token", accountID: "acct-1", expiresAt: now.addingTimeInterval(86_400))

    @Test func sendsTheAccountAndReadsThePlan() async {
        let requests = Recorder<(URL, [String: String])>()
        let source = ChatGPTSource(
            loadCredentials: { [valid] in valid },
            get: { url, headers in requests.record((url, headers)); return reply(200, sample) }
        )
        let outcome = await source.fetch(now: now)
        #expect(requests.all.first?.0.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(requests.all.first?.1["Authorization"] == "Bearer token")
        #expect(requests.all.first?.1["ChatGPT-Account-Id"] == "acct-1")
        guard case let .success(usage) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(usage.service == .chatGPT)
        #expect(usage.plan == "Pro Lite")
        #expect(usage.rows.map(\.percent) == [35])
    }

    @Test func statusCodes() async {
        func outcome(_ reply: HTTP.Reply) async -> FetchOutcome {
            await ChatGPTSource(loadCredentials: { [valid] in valid }, get: { _, _ in reply }).fetch(now: now)
        }
        #expect(await outcome(reply(401)) == .tokenExpired(plan: nil))
        #expect(await outcome(reply(429, retryAfter: 60)) == .rateLimited(retryAfter: 60))
        #expect(await outcome(reply(403)) == .failed("OpenAI returned HTTP 403"))
    }

    @Test func noLoginIsNotSignedIn() async {
        let source = ChatGPTSource(loadCredentials: { throw CredentialError.notFound }, get: { _, _ in reply(200, sample) })
        #expect(await source.fetch(now: now) == .notSignedIn)
    }
}
