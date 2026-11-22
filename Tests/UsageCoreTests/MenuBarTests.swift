import Foundation
import Testing
@testable import UsageCore

private func row(_ id: String, _ title: String, _ percent: Double?, _ severity: Severity = .normal) -> LimitRow {
    LimitRow(id: id, title: title, percent: percent, resetsAt: now.addingTimeInterval(3 * 86_400),
             severity: severity, windowLength: 604_800)
}

/// Claude with a session at 20%, weekly at 35% and a per-model limit at 80%; ChatGPT weekly at 60%.
private func tracker() -> UsageTracker {
    var tracker = UsageTracker()
    tracker.record(.success(ServiceUsage(service: .claude, plan: "Max 20x", rows: [
        row("session", "Session (5h)", 20),
        row("weekly_all-1", "Weekly · all models", 35),
        row("weekly_scoped-2", "Weekly · Fable", 80, .warning),
    ])), for: .claude, at: now)
    tracker.record(.success(ServiceUsage(service: .chatGPT, plan: "Pro 100", rows: [
        row("codex-1", "Weekly", 60),
    ])), for: .chatGPT, at: now)
    return tracker
}

private let claudeWeekly = LimitChoice(service: .claude, title: "Weekly · all models")
private let claudeSession = LimitChoice(service: .claude, title: "Session (5h)")
private let fable = LimitChoice(service: .claude, title: "Weekly · Fable")
private let chatGPTWeekly = LimitChoice(service: .chatGPT, title: "Weekly")

@Suite struct MenuBarTests {
    @Test func withNothingChosenItShowsTheTightestLimit() {
        let shown = tracker().menuBarLimits(chosen: [], at: now)
        #expect(shown.map(\.row.title) == ["Weekly · Fable"])
    }

    @Test func chosenLimitsShowInTheMenusOrder() {
        let shown = tracker().menuBarLimits(chosen: [chatGPTWeekly, claudeWeekly], at: now)
        #expect(shown.map(\.service) == [.claude, .chatGPT])
        #expect(shown.map(\.row.title) == ["Weekly · all models", "Weekly"])
    }

    @Test func choicesThatNoLongerExistAreSkipped() {
        let gone = LimitChoice(service: .claude, title: "Weekly · Opus")
        #expect(tracker().menuBarLimits(chosen: [gone, chatGPTWeekly], at: now).map(\.row.title) == ["Weekly"])
        // None left: back to the tightest, rather than an empty menu bar.
        #expect(tracker().menuBarLimits(chosen: [gone], at: now).map(\.row.title) == ["Weekly · Fable"])
    }

    @Test func aSignedOutServiceDropsItsChoices() {
        var tracker = tracker()
        tracker.record(.notSignedIn, for: .chatGPT, at: now.addingTimeInterval(60))
        tracker.record(.notSignedIn, for: .chatGPT, at: now.addingTimeInterval(120))
        #expect(tracker.menuBarLimits(chosen: [chatGPTWeekly, claudeWeekly], at: now.addingTimeInterval(120))
            .map(\.row.title) == ["Weekly · all models"])
    }

    @Test func atMostThreeAreShown() {
        let shown = tracker().menuBarLimits(chosen: [claudeSession, claudeWeekly, fable, chatGPTWeekly], at: now)
        #expect(shown.count == UsageTracker.menuBarLimit)
        #expect(shown.map(\.row.title) == ["Session (5h)", "Weekly · all models", "Weekly · Fable"])
    }

    @Test func eachShownLimitCarriesItsOwnServicesStaleness() {
        var tracker = tracker()
        tracker.record(.success(ServiceUsage(service: .chatGPT, plan: nil, rows: [row("codex-1", "Weekly", 61)])),
                       for: .chatGPT, at: now.addingTimeInterval(16 * 60))
        let shown = tracker.menuBarLimits(chosen: [claudeWeekly, chatGPTWeekly], at: now.addingTimeInterval(16 * 60))
        #expect(shown.map(\.isStale) == [true, false])
    }

    @Test func theNumberIsTheTightestShown() {
        let shown = tracker().menuBarLimits(chosen: [claudeWeekly, fable, chatGPTWeekly], at: now)
        #expect(UsageTracker.tightest(of: shown)?.row.title == "Weekly · Fable")  // the warning, which is also the fullest
        // Claude's own label can leave a fuller limit normal; the warning still leads.
        let fuller = Headline(service: .claude, row: row("session", "Session (5h)", 85), isStale: false)
        #expect(UsageTracker.tightest(of: [fuller] + shown)?.row.title == "Weekly · Fable")
        let normal = tracker().menuBarLimits(chosen: [claudeWeekly, chatGPTWeekly], at: now)
        #expect(UsageTracker.tightest(of: normal)?.row.percent == 60)
        // A session that hasn't started has no number, so it only leads when it's alone.
        let idle = Headline(service: .claude, row: row("session", "Session (5h)", nil), isStale: false)
        #expect(UsageTracker.tightest(of: [idle] + normal)?.row.percent == 60)
        #expect(UsageTracker.tightest(of: [idle])?.row.title == "Session (5h)")
        #expect(UsageTracker.tightest(of: []) == nil)
    }

    @Test func twoLimitsWithTheSameTitleShowOnce() {
        var tracker = UsageTracker()
        tracker.record(.success(ServiceUsage(service: .chatGPT, plan: nil, rows: [
            row("codex-0", "Weekly", 40), row("extra-0", "Weekly", 90, .critical), row("codex-1", "Session (5h)", 10),
        ])), for: .chatGPT, at: now)
        let shown = tracker.menuBarLimits(chosen: [chatGPTWeekly, LimitChoice(service: .chatGPT, title: "Session (5h)")], at: now)
        #expect(shown.map(\.row.id) == ["codex-0", "codex-1"])
    }

    @Test func tickingAndUnticking() {
        let tracker = tracker()
        var chosen = tracker.toggling(claudeWeekly, in: [], at: now)
        #expect(chosen == [claudeWeekly])
        chosen = tracker.toggling(fable, in: chosen, at: now)
        chosen = tracker.toggling(chatGPTWeekly, in: chosen, at: now)
        // Three is all there's room for.
        #expect(tracker.toggling(claudeSession, in: chosen, at: now) == chosen)
        #expect(tracker.toggling(fable, in: chosen, at: now) == [claudeWeekly, chatGPTWeekly])
    }

    /// Choose three Claude limits, sign out of Claude, pick ChatGPT's, sign back in: the ticks
    /// must still match the menu bar, so the absent choices give way rather than making four.
    @Test func aPickWhileAServiceIsSignedOutNeverMakesFour() {
        var tracker = tracker()
        var chosen: Set<LimitChoice> = [claudeSession, claudeWeekly, fable]
        tracker.record(.notSignedIn, for: .claude, at: now.addingTimeInterval(60))
        tracker.record(.notSignedIn, for: .claude, at: now.addingTimeInterval(120))
        chosen = tracker.toggling(chatGPTWeekly, in: chosen, at: now.addingTimeInterval(120))
        #expect(chosen == [chatGPTWeekly])

        tracker.record(.success(ServiceUsage(service: .claude, plan: nil, rows: [
            row("session", "Session (5h)", 20), row("weekly_all-1", "Weekly · all models", 35),
        ])), for: .claude, at: now.addingTimeInterval(180))
        #expect(tracker.menuBarLimits(chosen: chosen, at: now.addingTimeInterval(180)).map(\.row.title) == ["Weekly"])

        // With room to spare, an absent choice is kept for when it's back.
        let kept = tracker.toggling(chatGPTWeekly, in: [fable], at: now.addingTimeInterval(180))
        #expect(kept == [fable, chatGPTWeekly])
    }

    @Test func choicesListEveryLimitInTheMenusOrder() {
        #expect(tracker().choices(at: now) == [claudeSession, claudeWeekly, fable, chatGPTWeekly])
    }

    @Test func choicesSurviveBeingSaved() {
        for choice in [claudeWeekly, chatGPTWeekly, LimitChoice(service: .claude, title: "Weekly · a/b")] {
            #expect(LimitChoice(stored: choice.stored) == choice)
        }
        for junk in ["", "claude", "claude/", "nope/Weekly", "/Weekly"] {
            #expect(LimitChoice(stored: junk) == nil, "\(junk)")
        }
    }
}

private typealias Headline = UsageTracker.Headline
