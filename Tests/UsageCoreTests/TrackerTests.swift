import Foundation
import Testing
@testable import UsageCore

private func usage(_ service: Service, _ percent: Double, _ severity: Severity = .normal, resetsAt: Date? = nil) -> ServiceUsage {
    ServiceUsage(service: service, plan: nil, rows: [
        LimitRow(id: "weekly", title: "Weekly", percent: percent, resetsAt: resetsAt ?? now.addingTimeInterval(3 * 86_400),
                 severity: severity, windowLength: 604_800),
    ])
}

private func minutes(_ count: Double) -> Date {
    now.addingTimeInterval(count * 60)
}

@Suite struct TrackerTests {
    /// The bug that hid Claude: one failed check swapped the menu bar to ChatGPT's 35%.
    @Test func aFailedCheckKeepsAServiceInTheMenuBar() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        for failure in [FetchOutcome.rateLimited(retryAfter: 300), .failed(.offline), .failed(.server(status: 503)),
                        .failed(.loginUnreadable), .tokenExpired(plan: nil)] {
            var copy = tracker
            copy.record(failure, for: .claude, at: minutes(2))
            let headline = copy.headline(at: minutes(3))
            #expect(headline?.service == .claude, "after \(failure)")
            #expect(headline?.row.percent == 100)
            #expect(headline?.isStale == false)
            #expect(copy.signedInServices == [.claude, .chatGPT])
        }
    }

    @Test func numbersGoOutOfDateAfterFifteenMinutesButStillCount() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        tracker.record(.tokenExpired(plan: nil), for: .claude, at: minutes(5))
        #expect(!tracker.isStale(.claude, at: minutes(14)))
        #expect(tracker.isStale(.claude, at: minutes(16)))
        // An old reading is a lower bound, so it still leads; it's just marked out of date.
        let headline = tracker.headline(at: minutes(16))
        #expect(headline?.service == .claude)
        #expect(headline?.isStale == true)
        // A successful check clears it.
        tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: minutes(17))
        #expect(!tracker.isStale(.claude, at: minutes(17)))
    }

    @Test func anOldButHigherReadingStillLeads() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.chatGPT, 95, .critical)), for: .chatGPT, at: now)
        tracker.record(.failed(.offline), for: .chatGPT, at: minutes(1))
        tracker.record(.success(usage(.claude, 92, .critical)), for: .claude, at: minutes(20))
        let headline = tracker.headline(at: minutes(20))
        #expect(headline?.service == .chatGPT)
        #expect(headline?.row.severity == .critical)  // still red: it's at least 95% now
        #expect(headline?.isStale == true)
    }

    @Test func aWindowThatHasResetNoLongerLeads() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 100, .critical, resetsAt: minutes(30))), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: now)
        #expect(tracker.headline(at: minutes(29))?.service == .claude)
        #expect(tracker.headline(at: minutes(31))?.service == .chatGPT)
    }

    @Test func onlyAMissingLoginSignsOut() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 50)), for: .claude, at: now)
        tracker.record(.failed(.loginUnreadable), for: .claude, at: minutes(2))
        #expect(tracker.signedInServices == [.claude])
        #expect(tracker.state(of: .claude)?.usage != nil)
        tracker.record(.notSignedIn, for: .claude, at: minutes(4))
        #expect(tracker.signedInServices.isEmpty)
        #expect(tracker.headline(at: minutes(4)) == nil)
    }

    @Test func rateLimitBackoffHoldsEvenForForcedRefreshes() {
        var tracker = UsageTracker()
        tracker.record(.rateLimited(retryAfter: 600), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 10)), for: .chatGPT, at: now)
        // Claude is held back until its backoff ends, forced or not; ChatGPT is due as usual.
        #expect(tracker.servicesToFetch(from: Service.allCases, force: true, now: minutes(1)) == [.chatGPT])
        #expect(tracker.servicesToFetch(from: Service.allCases, force: false, now: minutes(1)).isEmpty)
        #expect(tracker.servicesToFetch(from: Service.allCases, force: false, now: minutes(6)) == [.chatGPT])
        #expect(tracker.servicesToFetch(from: Service.allCases, force: false, now: minutes(10)) == [.claude, .chatGPT])
    }

    @Test func checksAreScheduledByOutcome() {
        let cases: [(FetchOutcome, TimeInterval)] = [
            (.success(usage(.claude, 1)), 300), (.tokenExpired(plan: nil), 60), (.failed(.offline), 60),
            (.failed(.loginUnreadable), 60), (.failed(.server(status: 500)), 300), (.failed(.unreadable), 300),
            (.notSignedIn, 300), (.rateLimited(retryAfter: nil), 300), (.rateLimited(retryAfter: 0), 300),
            (.rateLimited(retryAfter: 30), 60), (.rateLimited(retryAfter: 900), 900),
        ]
        for (outcome, delay) in cases {
            var tracker = UsageTracker()
            tracker.record(outcome, for: .claude, at: now)
            #expect(tracker.state(of: .claude)?.nextFetch == now.addingTimeInterval(delay), "\(outcome)")
            #expect(tracker.nextWake(after: now) == now.addingTimeInterval(delay))
        }
        #expect(UsageTracker().nextWake(after: now) == now.addingTimeInterval(300))
    }

    @Test func repeatedRateLimitsBackOffFurtherUpToAnHour() {
        var tracker = UsageTracker()
        var waits: [TimeInterval] = []
        var time = now
        for _ in 0..<7 {
            tracker.record(.rateLimited(retryAfter: nil), for: .claude, at: time)
            let next = tracker.state(of: .claude)!.nextFetch
            waits.append(next.timeIntervalSince(time))
            time = next
        }
        #expect(waits == [300, 600, 1200, 2400, 3600, 3600, 3600])
        tracker.record(.success(usage(.claude, 1)), for: .claude, at: time)
        tracker.record(.rateLimited(retryAfter: nil), for: .claude, at: time)
        #expect(tracker.state(of: .claude)!.nextFetch == time.addingTimeInterval(300))  // reset by the success
    }

    @Test func loadingUntilEveryServiceHasBeenChecked() {
        var tracker = UsageTracker()
        #expect(tracker.isLoading)
        tracker.record(.notSignedIn, for: .chatGPT, at: now)
        #expect(tracker.isLoading)
        tracker.record(.success(usage(.claude, 1)), for: .claude, at: now)
        #expect(!tracker.isLoading)
    }

    /// Six hours of polls with a mix of hiccups: Claude must never leave the menu bar, and only
    /// counts as out of date after fifteen minutes without a successful check.
    @Test func hoursOfPollingWithHiccups() {
        var tracker = UsageTracker()
        let hiccups: [FetchOutcome] = [.failed(.offline), .rateLimited(retryAfter: 120), .failed(.loginUnreadable),
                                       .failed(.server(status: 502)), .tokenExpired(plan: nil)]
        var lastSuccess = now
        for step in 0..<180 {
            let time = minutes(Double(step) * 2)
            // Mostly fine; every so often a run of one to six failed checks.
            let failing = step % 17 >= 11
            if failing {
                tracker.record(hiccups[step % hiccups.count], for: .claude, at: time)
            } else {
                tracker.record(.success(usage(.claude, 100, .critical)), for: .claude, at: time)
                lastSuccess = time
            }
            tracker.record(.success(usage(.chatGPT, 35)), for: .chatGPT, at: time)

            let headline = tracker.headline(at: time)
            #expect(headline?.service == .claude, "step \(step)")
            #expect(headline?.isStale == (time.timeIntervalSince(lastSuccess) > UsageTracker.staleAfter), "step \(step)")
        }
    }
}

@Suite struct LoginReadTests {
    @Test func onlyStatus44MeansNoKeychainItem() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"t"}}"#.utf8)
        #expect(ClaudeCredentialStore.keychainRead(status: 0, output: json) == .found(json))
        #expect(ClaudeCredentialStore.keychainRead(status: 44, output: Data()) == .missing)
        #expect(ClaudeCredentialStore.keychainRead(status: 51, output: Data()) == .unreadable)  // interaction not allowed
        #expect(ClaudeCredentialStore.keychainRead(status: 36, output: Data()) == .unreadable)  // keychain locked
        #expect(ClaudeCredentialStore.keychainRead(status: 0, output: Data()) == .unreadable)
    }

    @Test func anUnreadableClaudeLoginIsATemporaryFailure() async {
        let source = ClaudeSource(loadCredentials: { throw CredentialError.unreadable }, get: { _, _ in reply(200) })
        #expect(await source.fetch(now: now) == .failed(.loginUnreadable))
    }

    @Test func anUnreadableCodexLoginIsATemporaryFailure() async {
        let source = ChatGPTSource(loadCredentials: { throw CredentialError.unreadable }, get: { _, _ in reply(200) })
        #expect(await source.fetch(now: now) == .failed(.loginUnreadable))
    }

    @Test func codexLoginFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "llmits-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "auth.json")

        #expect(throws: CredentialError.notFound) { try ChatGPTCredentialStore.load(from: file) }
        try Data(#"{"tokens": {"access_tok"#.utf8).write(to: file)  // caught mid-write
        #expect(throws: CredentialError.unreadable) { try ChatGPTCredentialStore.load(from: file) }
        try Data(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-test"}"#.utf8).write(to: file)
        #expect(throws: CredentialError.notFound) { try ChatGPTCredentialStore.load(from: file) }
        try Data(#"{"tokens": {"access_token": "t", "account_id": "a"}}"#.utf8).write(to: file)
        #expect(try ChatGPTCredentialStore.load(from: file).accountID == "a")
    }

    @Test func unreadableLoginCopy() {
        #expect(Format.problem(.failed(.loginUnreadable), service: .claude) == "Couldn't read your Claude Code login. Trying again shortly.")
    }
}

@Suite struct SavedUsageTests {
    @Test func lastNumbersSurviveARelaunch() throws {
        var before = UsageTracker()
        before.record(.success(usage(.claude, 100, .critical)), for: .claude, at: now)
        before.record(.success(usage(.chatGPT, 36)), for: .chatGPT, at: now)
        let data = try #require(before.snapshot.encoded())

        var after = UsageTracker()
        after.restore(try #require(UsageTracker.Snapshot.decode(data)))
        // Shown straight away, current if recent...
        #expect(after.headline(at: minutes(1)) == UsageTracker.Headline(service: .claude, row: usage(.claude, 100, .critical).rows[0], isStale: false))
        #expect(!after.isLoading)
        // ...out of date if old, and checked straight away either way.
        #expect(after.headline(at: minutes(20))?.isStale == true)
        #expect(after.servicesToFetch(from: Service.allCases, force: false, now: minutes(1)) == [.claude, .chatGPT])
        // A login that has gone since is dropped by its first check.
        after.record(.notSignedIn, for: .chatGPT, at: minutes(1))
        #expect(after.signedInServices == [.claude])
        #expect(after.snapshot.services.keys.sorted { $0.rawValue < $1.rawValue } == [.claude])
    }

    @Test func savedNumbersNeverReplaceLiveOnes() {
        var tracker = UsageTracker()
        tracker.record(.success(usage(.claude, 10)), for: .claude, at: minutes(5))
        var old = UsageTracker()
        old.record(.success(usage(.claude, 90)), for: .claude, at: now)
        tracker.restore(old.snapshot)
        #expect(tracker.state(of: .claude)?.usage?.rows.first?.percent == 10)
    }

    @Test func freshEnoughNotToRefetchOnOpen() {
        var tracker = UsageTracker()
        #expect(!tracker.isFresh(at: now))
        tracker.record(.success(usage(.claude, 10)), for: .claude, at: now)
        tracker.record(.success(usage(.chatGPT, 10)), for: .chatGPT, at: minutes(1))
        #expect(tracker.isFresh(at: minutes(1.5)))
        #expect(!tracker.isFresh(at: minutes(2.5)))  // Claude's are over two minutes old
    }

    @Test func garbageSavedDataIsIgnored() {
        #expect(UsageTracker.Snapshot.decode(Data("not json".utf8)) == nil)
    }
}
