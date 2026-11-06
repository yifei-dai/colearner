import Foundation
import Testing
@testable import CoLearner

/// What the Usage menu in the menu bar says (UsageMenu builds it from the usage ChatController keeps).
@Suite
@MainActor
struct UsageMenuTests {
    private let zone = TimeZone(identifier: "America/New_York")!
    private let locale = Locale(identifier: "en_US")

    /// November `day`, 2026, at that time in New York.
    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// Newer ICU puts a narrow no-break space before AM / PM.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func eachAssistantsWindowsWithWhenTheyReset() {
        let now = at(6, 8, 30)
        let usage: [Provider: PlanUsageEntry] = [
            .claude: PlanUsageEntry(plan: "Max", windows: [
                UsageWindow(label: "5h", percent: 1.4, resetsAt: at(6, 11, 20).timeIntervalSince1970, title: "Current session"),
                UsageWindow(label: "week", percent: 0, resetsAt: nil, title: "Current week (all models)", resetsText: "Nov 9 at 9am")],
                updated: at(6, 8, 21).timeIntervalSince1970),
            .codex: PlanUsageEntry(plan: "Plus", windows: [
                UsageWindow(label: "5h", percent: 0, resetsAt: at(6, 13, 10).timeIntervalSince1970, title: "5-hour limit"),
                UsageWindow(label: "week", percent: 7.2, resetsAt: at(10, 9, 0).timeIntervalSince1970, title: "Weekly limit")],
                updated: at(6, 8, 25).timeIntervalSince1970),
        ]
        let s = UsageMenu.sections(usage, signIn: [:], now: now, locale: locale, timeZone: zone)
        #expect(s.map(\.title) == ["Claude · Max", "ChatGPT · Plus"])
        #expect(s[0].lines.map(plain) == ["Current session: 1% used · resets 11:20 AM",
                                          "Current week (all models): 0% used · resets Nov 9 at 9am"])
        #expect(plain(s[1].lines[0]) == "5-hour limit: 0% used · resets 1:10 PM")
        // Another day: its day and time, never "in 4 days" (the menu may be opened much later).
        let week = plain(s[1].lines[1])
        #expect(week.hasPrefix("Weekly limit: 7% used · resets Tue") && week.contains("Nov 10") && week.contains("9:00 AM"), "\(week)")
        #expect(s.allSatisfy { $0.signIn == nil })
        #expect(UsageMenu.footer(usage, now: now, locale: locale, timeZone: zone).map(plain) == "Updated 8:25 AM · also after every answer")
        #expect(UsageMenu.footer(usage, now: at(7, 9, 0), locale: locale, timeZone: zone).map(plain)?.hasPrefix("Updated Fri") == true)
        #expect(!UsageMenu.loading(usage))
    }

    @Test func checkingFailingSignedOutAndNothingYet() {
        let now = at(6, 8, 30)
        var usage: [Provider: PlanUsageEntry] = [
            .claude: PlanUsageEntry(plan: nil, windows: [], updated: 0, loading: true),
            .codex: PlanUsageEntry(plan: nil, windows: [], updated: 0, error: "Codex CLI not found."),
        ]
        var s = UsageMenu.sections(usage, signIn: [:], now: now)
        #expect(s.map(\.title) == ["Claude", "ChatGPT"])
        #expect(s[0].lines == ["Checking…"] && s[1].lines == ["Codex CLI not found."])
        #expect(UsageMenu.loading(usage) && UsageMenu.footer(usage, now: now) == nil)
        #expect(UsageMenu.sections([:], signIn: [:], now: now).map(\.lines) == [["No numbers yet"], ["No numbers yet"]])
        // Signed out: the menu offers the tool's own sign-in; while it waits for the browser, to open it again.
        usage[.claude] = PlanUsageEntry(plan: "Max", windows: [], updated: 0, error: "Not signed in.", signedOut: true)
        s = UsageMenu.sections(usage, signIn: [:], now: now)
        #expect(s[0].signIn == "Sign In to Claude…" && s[0].lines == ["Not signed in."])
        s = UsageMenu.sections(usage, signIn: [.claude: .waiting], now: now)
        #expect(s[0].signIn == "Open Sign-In Again…" && s[0].lines.last == "Finish in your browser (click Authorize)")
        usage[.claude]?.loading = true
        #expect(UsageMenu.sections(usage, signIn: [:], now: now)[0].signIn == nil)   // checking again first
        // A refresh that failed keeps the last numbers and says so.
        usage[.codex] = PlanUsageEntry(plan: nil, windows: [UsageWindow(label: "5h", percent: 40, resetsAt: nil)],
                                       updated: now.timeIntervalSince1970, error: "timed out")
        #expect(UsageMenu.sections(usage, signIn: [:], now: now)[1].lines == ["5h: 40% used", "Last refresh failed: timed out"])
    }
}
