import Foundation

/// On-demand plan usage, the same numbers the Claude and ChatGPT apps show. Neither call asks a model anything:
/// Claude Code answers `/usage` and `auth status` locally, and Codex's app-server returns its rate limits.
enum UsageFetcher {
    struct Result {
        var plan: String?
        var windows: [UsageWindow]
        var error: String?
        /// The tool says it isn't signed in (the usage card then offers "Sign in").
        var signedOut = false
    }

    // MARK: Claude

    nonisolated static func claude(bin: URL, env: [String: String], cwd: URL) -> Result {
        let usage = run(bin, ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--tools", "",
                              "--strict-mcp-config", "--setting-sources", ""], env: env, cwd: cwd, timeout: 25)
        let auth = run(bin, ["auth", "status"], env: env, cwd: cwd, timeout: 10)
        var plan: String?
        var signedOut = false
        if let o = (try? JSONSerialization.jsonObject(with: Data(auth.utf8))) as? [String: Any] {
            if let sub = o["subscriptionType"] as? String { plan = sub.prefix(1).uppercased() + sub.dropFirst() }
            signedOut = o["loggedIn"] as? Bool == false
        }
        if signedOut { return Result(plan: nil, windows: [], error: "Not signed in.", signedOut: true) }
        guard let o = (try? JSONSerialization.jsonObject(with: Data(usage.utf8))) as? [String: Any],
              let text = o["result"] as? String else {
            return Result(plan: plan, windows: [], error: "Claude Code did not return usage.")
        }
        let windows = parseClaudeUsage(text)
        // Now and then /usage comes back with only its first line ("You are currently using your subscription…").
        let first = text.split(separator: "\n").first.map(String.init)
        let error = first?.hasPrefix("You are currently using your subscription") == true ? "Claude Code listed no numbers this time" : first
        return Result(plan: plan, windows: windows, error: windows.isEmpty ? error : nil)
    }

    /// Lines like "Current session: 42% used · resets Oct 17 at 8:09pm (America/New_York)".
    nonisolated static func parseClaudeUsage(_ text: String) -> [UsageWindow] {
        let re = try! NSRegularExpression(pattern: #"^\s*(Current [^:]+):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+(.+?))?\s*$"#)
        var out: [UsageWindow] = []
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let title = ns.substring(with: m.range(at: 1))
            let pct = Double(ns.substring(with: m.range(at: 2))) ?? 0
            var reset: String?
            if m.range(at: 3).location != NSNotFound {
                reset = ns.substring(with: m.range(at: 3)).replacingOccurrences(of: #"\s*\([A-Za-z_]+/[A-Za-z_/]+\)$"#, with: "", options: .regularExpression)
            }
            let short: String
            switch title.lowercased() {
            case "current session": short = "5h"
            case "current week (all models)": short = "week"
            default:
                let inner = title.range(of: #"\(([^)]+)\)"#, options: .regularExpression).map { String(title[$0].dropFirst().dropLast()) }
                short = inner.map { "\($0) wk" } ?? title
            }
            out.append(UsageWindow(label: short, percent: pct, resetsAt: nil, title: title, resetsText: reset))
        }
        return out
    }

    // MARK: ChatGPT (Codex)

    nonisolated static func codex(bin: URL, env: [String: String]) -> Result {
        let lines = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"colearner","title":"Co-learner","version":"0.1.8"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ].joined(separator: "\n") + "\n"
        var reply: [String: Any]?
        _ = run(bin, ["app-server"], env: env, cwd: nil, stdin: Data(lines.utf8), keepStdinOpen: true, timeout: 12) { line in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (o["id"] as? NSNumber)?.intValue == 2 else { return false }
            reply = o
            return true
        }
        guard let reply else { return Result(plan: nil, windows: [], error: "Codex did not answer (is it logged in?).") }
        if let err = reply["error"] as? [String: Any] {
            let m = err["message"] as? String ?? "Codex error"
            return Result(plan: nil, windows: [], error: m, signedOut: SignIn.isSignInError(m, .codex))
        }
        guard let result = reply["result"] as? [String: Any], let rl = result["rateLimits"] as? [String: Any] else {
            return Result(plan: nil, windows: [], error: "No rate limits in Codex's answer.")
        }
        var windows: [UsageWindow] = []
        for k in ["primary", "secondary"] {
            guard let w = rl[k] as? [String: Any], let pct = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let label = UsageWindow.windowLabel(minutes: mins)
            let title = mins == 300 ? "5-hour limit" : mins == 10080 ? "Weekly limit" : "\(label) limit"
            windows.append(UsageWindow(label: label, percent: pct, resetsAt: (w["resetsAt"] as? NSNumber)?.doubleValue, title: title))
        }
        return Result(plan: planName(rl["planType"] as? String), windows: windows, error: nil)
    }

    nonisolated static func planName(_ s: String?) -> String? {
        guard let s else { return nil }
        let known = ["prolite": "Pro Lite", "pro": "Pro", "plus": "Plus", "free": "Free", "team": "Team",
                     "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return known[s.lowercased()] ?? s.capitalized
    }

    // MARK: process helper

    /// Runs a tool and returns its stdout. With `stopWhen`, reads line by line and ends the process as soon as
    /// a line satisfies it (for servers that don't exit on their own).
    nonisolated static func run(_ exe: URL, _ args: [String], env: [String: String], cwd: URL?,
                                        stdin: Data? = nil, keepStdinOpen: Bool = false, timeout: TimeInterval,
                                        stopWhen: ((String) -> Bool)? = nil) -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return "" }
        if let stdin {
            try? inp.fileHandleForWriting.write(contentsOf: stdin)
            if !keepStdinOpen { try? inp.fileHandleForWriting.close() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        let fd = out.fileHandleForReading.fileDescriptor
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        var stopped = false
        // Non-blocking reads so the deadline holds even if the tool stays silent.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        while Date() < deadline {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(contentsOf: buf[0..<n])
                if let stopWhen {
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where stopWhen(String(line)) {
                        stopped = true
                        break
                    }
                    if stopped { break }
                }
            } else if n == 0 {
                break   // EOF
            } else if errno == EAGAIN || errno == EINTR {
                usleep(30_000)
            } else {
                break
            }
        }
        if p.isRunning { p.terminate() }
        try? inp.fileHandleForWriting.close()
        return String(decoding: data, as: UTF8.self)
    }
}
