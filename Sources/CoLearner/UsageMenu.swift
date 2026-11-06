import Foundation

/// One assistant's plan usage as last fetched (ChatController keeps it; the Usage menu shows it).
struct PlanUsageEntry: Equatable {
    var plan: String?
    var windows: [UsageWindow]
    var updated: Double
    var loading = false
    var error: String?
    var signedOut = false
}

/// The Usage menu in the menu bar: for each assistant its plan, how much of each window is used and when it resets,
/// and a sign-in while the tool says it is signed out; then when the numbers were fetched, and Refresh. Pure, so it is
/// tested without the app.
enum UsageMenu {
    struct Section: Equatable {
        var provider: Provider
        var title: String       // "Claude · Max"
        var lines: [String]     // "Current session: 1% used · resets 11:20 AM"
        var signIn: String?     // "Sign In to Claude…" while signed out
    }

    static func sections(_ usage: [Provider: PlanUsageEntry], signIn: [Provider: SignIn.Phase], now: Date = Date(),
                         locale: Locale = .current, timeZone: TimeZone = .current) -> [Section] {
        Provider.allCases.map { p in
            let u = usage[p]
            let name = p == .claude ? "Claude" : "ChatGPT"
            var lines: [String]
            if let u, !u.windows.isEmpty {
                lines = u.windows.map { line($0, now: now, locale: locale, timeZone: timeZone) }
                if let e = u.error { lines.append("Last refresh failed: " + e) }
            } else if u?.loading == true {
                lines = ["Checking…"]
            } else if let e = u?.error {
                lines = [e]
            } else {
                lines = ["No numbers yet"]
            }
            var sign: String?
            if let u, u.signedOut, !u.loading {
                let waiting = signIn[p] == .waiting
                sign = waiting ? "Open Sign-In Again…" : "Sign In to \(name)…"
                if waiting { lines.append("Finish in your browser (click Authorize)") }
            }
            return Section(provider: p, title: name + (u?.plan.map { " · " + $0 } ?? ""), lines: lines, signIn: sign)
        }
    }

    /// "Current session: 1% used · resets 11:20 AM"
    static func line(_ w: UsageWindow, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var s = "\(w.title ?? w.label): \(Int(w.percent.rounded()))% used"
        if let r = reset(w, now: now, locale: locale, timeZone: timeZone) { s += " · resets " + r }
        return s
    }

    /// When a window resets: a time today, else a day and a time. Never "in 2 h": a menu is often opened much later
    /// than its numbers were fetched.
    static func reset(_ w: UsageWindow, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let at = w.resetsAt else { return w.resetsText }
        return time(Date(timeIntervalSince1970: at), now: now, withDay: "EEEMMMdjmm", locale: locale, timeZone: timeZone)
    }

    /// "Updated 8:21 AM · also after every answer" (the newest fetch), nil before the first.
    static func footer(_ usage: [Provider: PlanUsageEntry], now: Date = Date(), locale: Locale = .current,
                       timeZone: TimeZone = .current) -> String? {
        guard let newest = usage.values.map(\.updated).max(), newest > 0 else { return nil }
        return "Updated " + time(Date(timeIntervalSince1970: newest), now: now, withDay: "EEEjmm", locale: locale, timeZone: timeZone)
            + " · also after every answer"
    }

    static func loading(_ usage: [Provider: PlanUsageEntry]) -> Bool { usage.values.contains { $0.loading } }

    private static func time(_ d: Date, now: Date, withDay template: String, locale: Locale, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate(cal.isDate(d, inSameDayAs: now) ? "jmm" : template)
        return f.string(from: d)
    }
}
