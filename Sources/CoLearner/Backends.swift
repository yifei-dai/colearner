import Foundation

struct BackendRequest {
    var prompt: String
    var instructions: String
    /// Slide images and selected areas attached to this message (in order).
    var imageURLs: [URL] = []
    var resume: String?
    var model: String?
    var effort: String?
    /// Folders the assistant may read (Claude only).
    var readableDirs: [URL] = []
}

enum BackendEvent {
    case session(String)
    case model(String)
    case delta(String)          // append to the answer
    case replace(String)        // the full answer so far (used at the end, or for whole-message backends)
    case activity(String?)      // "Reading L05_notes.tex…"
    case usage([UsageWindow])   // plan usage reported along the way
    case finished
    case failed(String)
    /// The partial answer on screen may be missing from the assistant's session (killed, cut off, failed).
    case notKept
    /// The turn completed and is in the session (a Stop pressed after this doesn't make it "stopped").
    case saved
}

protocol RunHandle: AnyObject {
    func cancel()
    func terminateNow()
    var isRunning: Bool { get }
    /// The exit status once the process has ended (nil while it runs).
    var exitStatus: Int32? { get }
}
extension ProcessRunner: RunHandle {}

@MainActor
protocol Backend: AnyObject {
    func start(_ req: BackendRequest, onEvent: @escaping @MainActor (BackendEvent) -> Void) -> RunHandle?
}

// MARK: - helpers

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let d = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Errors from the CLIs often wrap a JSON body in a string; dig out the human message.
private func humanError(_ s: String) -> String {
    if let o = jsonObject(s) {
        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = o["message"] as? String { return m }
    }
    return s
}

// MARK: - Codex (ChatGPT)

@MainActor
final class CodexBackend: Backend {
    nonisolated static let defaultModel = "gpt-6-astra"

    nonisolated static func locate() -> URL? {
        let fm = FileManager.default
        if let saved = UserDefaults.standard.string(forKey: "toolPath.codex"), fm.isExecutableFile(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        // The native binary inside the npm package needs no node on PATH. Pick the newest copy.
        let nvm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        var best: (URL, [Int])?
        for v in (try? fm.contentsOfDirectory(atPath: nvm.path)) ?? [] {
            let u = nvm.appendingPathComponent(v)
                .appendingPathComponent("lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex")
            guard fm.isExecutableFile(atPath: u.path), let ver = version(of: u) else { continue }
            if best == nil || ver.lexicographicallyPrecedes(best!.1) == false { best = (u, ver) }
        }
        if let best { return best.0 }
        for p in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] where fm.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        if let p = ToolLocator.shellWhich("codex") {
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath()
            if real.lastPathComponent == "codex.js" {
                let native = real.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex")
                if fm.isExecutableFile(atPath: native.path) { return native }
            }
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    nonisolated private static func version(of u: URL) -> [Int]? {
        let p = Process()
        p.executableURL = u
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let r = s.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return s[r].split(separator: ".").compactMap { Int($0) }
    }

    static func withHint(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("401") || l.contains("unauthorized") || l.contains("login") || l.contains("not logged in") {
            return e + "\n\nFix: open Terminal, run `codex login`, then ask again."
        }
        return e
    }

    private var cached: URL??
    private let workDirectory: URL?
    private let readUsage: (String?) -> [UsageWindow]

    init(binary: URL? = nil, workDirectory: URL? = nil,
         readUsage: @escaping (String?) -> [UsageWindow] = { UsageWindow.latestCodex(thread: $0) }) {
        self.workDirectory = workDirectory
        self.readUsage = readUsage
        if let binary {
            cached = .some(binary)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let u = Self.locate()
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.cached == nil { self.cached = .some(u) } } }
        }
    }
    /// Without probing: nil = not known yet (the launch-time lookup is still running).
    var knownBinary: URL?? { cached }

    var binary: URL? {
        if let c = cached { return c }
        let u = Self.locate()
        cached = .some(u)
        return u
    }

    func start(_ req: BackendRequest, onEvent: @escaping @MainActor (BackendEvent) -> Void) -> RunHandle? {
        guard let bin = binary else {
            onEvent(.failed("Codex CLI not found. Install it (npm i -g @openai/codex), run `codex login` in Terminal, then restart Co-learner."))
            return nil
        }
        let work = workDirectory ?? AppPaths.support.appendingPathComponent("codex-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let tomlString = (try? String(decoding: enc.encode(req.instructions), as: UTF8.self)) ?? "\"\""
        let model = (req.model?.isEmpty == false) ? req.model! : Self.defaultModel
        let effort = req.effort ?? "medium"
        var args = ["exec", "--json", "--skip-git-repo-check", "--ignore-user-config",
                    "-m", model, "-s", "read-only", "-C", work.path,
                    "-c", "model_reasoning_effort=\(effort)",
                    "-c", "web_search=disabled",
                    "--disable", "shell_tool", "--disable", "unified_exec",
                    "-c", "developer_instructions=\(tomlString)"]
        if let r = req.resume { args += ["resume", r] }
        for img in req.imageURLs { args += ["-i", img.path] }
        args += ["--", req.prompt]

        var messages: [String] = []
        var completed = false
        var failure: String?
        var thread: String? = req.resume
        onEvent(.model(ModelCatalog.label(.codex, model) + " · " + effort))
        let runner = ProcessRunner(
            executable: bin, arguments: args, cwd: work,
            environment: ToolLocator.environment(addingDirsOf: [bin]),
            onLine: { line in
                guard let o = jsonObject(line), let type = o["type"] as? String else { return }
                switch type {
                case "thread.started":
                    if let id = o["thread_id"] as? String { thread = id; onEvent(.session(id)) }
                case "turn.started":
                    onEvent(.activity("thinking…"))
                case "item.started":
                    if let item = o["item"] as? [String: Any], let t = item["type"] as? String, t != "agent_message" {
                        onEvent(.activity(t.replacingOccurrences(of: "_", with: " ") + "…"))
                    }
                case "item.completed":
                    guard let item = o["item"] as? [String: Any], let t = item["type"] as? String else { return }
                    if t == "agent_message", let text = item["text"] as? String {
                        messages.append(text)
                        onEvent(.replace(messages.joined(separator: "\n\n")))
                        onEvent(.activity(nil))
                    }
                case "turn.completed":
                    completed = true
                    failure = nil   // an earlier "error" line (e.g. a stream retry) was not fatal
                    onEvent(.saved)
                case "turn.failed":
                    let e = (o["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed"
                    failure = humanError(e)
                case "error":
                    if let m = o["message"] as? String { failure = humanError(m) }
                default:
                    break
                }
            },
            onExit: { status, stderr, cancelled in
                // Codex writes its plan usage into the session log, not to stdout.
                let w = self.readUsage(thread)
                if !w.isEmpty { onEvent(.usage(w)) }
                if completed && failure == nil { onEvent(.finished); return }
                // An agent_message may be commentary before the final answer. Only turn.completed
                // confirms that the turn finished; replay partial text if an unfinished turn is resumed.
                if !completed && messages.contains(where: { !$0.isEmpty }) { onEvent(.notKept) }
                if cancelled { onEvent(.finished); return }
                if let failure { onEvent(.failed(Self.withHint(failure))); return }
                let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
                let reason = messages.isEmpty ? "without an answer" : "before the answer finished"
                onEvent(.failed("Codex exited (status \(status)) \(reason).\n\(tail)"))
            })
        do {
            try runner.start(stdin: nil)
        } catch {
            onEvent(.failed("Could not start Codex: \(error.localizedDescription)"))
            return nil
        }
        return runner
    }
}

// MARK: - Claude (Claude Code CLI, headless)

@MainActor
final class ClaudeBackend: Backend {
    /// Opus 5.5 needs Claude Code 2.1.280 or newer.
    static let minVersion = [2, 1, 280]

    /// Every claude binary on this Mac with its version; the newest wins.
    nonisolated static func candidates() -> [(URL, [Int])] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var paths: [URL] = []
        if let saved = UserDefaults.standard.string(forKey: "toolPath.claude"), fm.isExecutableFile(atPath: saved) {
            return [(URL(fileURLWithPath: saved), version(of: URL(fileURLWithPath: saved)) ?? [0])]
        }
        // The copy the Claude desktop app keeps up to date (needs no node).
        let desk = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        for v in (try? fm.contentsOfDirectory(atPath: desk.path)) ?? [] {
            let vdir = desk.appendingPathComponent(v)
            for sub in (try? fm.contentsOfDirectory(atPath: vdir.path)) ?? [] {
                let bin = vdir.appendingPathComponent(sub).appendingPathComponent("Contents/MacOS/claude")
                if sub.hasSuffix(".app"), fm.isExecutableFile(atPath: bin.path) { paths.append(bin) }
                let nested = vdir.appendingPathComponent(sub).appendingPathComponent("claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: nested.path) { paths.append(nested) }
            }
        }
        for p in ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            let u = URL(fileURLWithPath: p.replacingOccurrences(of: "~", with: home.path))
            if fm.isExecutableFile(atPath: u.path) { paths.append(u) }
        }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        for v in (try? fm.contentsOfDirectory(atPath: nvm.path)) ?? [] {
            let u = nvm.appendingPathComponent(v).appendingPathComponent("bin/claude")
            if fm.isExecutableFile(atPath: u.path) { paths.append(u) }
        }
        if paths.isEmpty, let p = ToolLocator.shellWhich("claude") { paths.append(URL(fileURLWithPath: p)) }
        return paths.compactMap { u in version(of: u).map { (u, $0) } }
    }

    nonisolated static func version(of u: URL) -> [Int]? {
        let p = Process()
        p.executableURL = u
        p.arguments = ["--version"]
        p.environment = ToolLocator.environment(addingDirsOf: [u])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning && Date() < deadline { usleep(30_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let r = s.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return s[r].split(separator: ".").compactMap { Int($0) }
    }

    private var cached: (URL, [Int])??
    init() {
        // Finding the binary runs `--version` on each candidate; do it in the background at launch.
        DispatchQueue.global(qos: .utility).async {
            let best = Self.candidates().max { $0.1.lexicographicallyPrecedes($1.1) }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self.cached == nil { self.cached = .some(best) } } }
        }
    }
    /// Without probing: nil = not known yet (the launch-time lookup is still running).
    var knownLocation: (URL, [Int])?? { cached }

    var located: (URL, [Int])? {
        if let c = cached { return c }
        let best = Self.candidates().max { $0.1.lexicographicallyPrecedes($1.1) }
        cached = .some(best)
        return best
    }

    /// For Settings: never probes on the main thread.
    var versionString: String {
        guard let c = cached else { return "checking…" }
        return c.map { $0.1.map(String.init).joined(separator: ".") } ?? "not found"
    }

    func start(_ req: BackendRequest, onEvent: @escaping @MainActor (BackendEvent) -> Void) -> RunHandle? {
        // The desktop app prunes old versions; if ours vanished, look again.
        if let c = cached, let (u, _) = c, !FileManager.default.isExecutableFile(atPath: u.path) { cached = nil }
        guard let (bin, ver) = located else {
            onEvent(.failed("Claude Code not found. Install it or open the Claude desktop app once, then restart Co-learner."))
            return nil
        }
        let model = (req.model?.isEmpty == false) ? req.model! : "opus"
        let effort = req.effort ?? "medium"
        if model == "opus", ver.lexicographicallyPrecedes(Self.minVersion) {
            onEvent(.failed("Claude Code \(versionString) is too old for Opus 5.5 (needs 2.1.280+). Run `claude update` in Terminal, then restart Co-learner."))
            return nil
        }
        // A fixed, app-owned working folder: no CLAUDE.md or project memory gets loaded, and sessions resume reliably.
        let cwd = AppPaths.support.appendingPathComponent("claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages",
                    "--model", model, "--effort", effort,
                    "--tools", "Read,Grep,Glob",
                    // Read works on any path in -p mode; these deny rules keep Claude out of the handwritten scans.
                    "--disallowedTools", "Read(//**/*inclass*)", "Read(//**/*_scribing_*.pdf)",
                    "Grep(//**/*inclass*)", "Grep(//**/*_scribing_*.pdf)",
                    "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
                    "--system-prompt", req.instructions]
        for d in req.readableDirs { args += ["--add-dir", d.path] }
        if let r = req.resume { args += ["--resume", r] }

        var content: [[String: Any]] = []
        for img in req.imageURLs {
            guard let data = try? Data(contentsOf: img) else { continue }
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": req.prompt])
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        guard var line = try? JSONSerialization.data(withJSONObject: msg) else {
            onEvent(.failed("Could not encode the message."))
            return nil
        }
        line.append(0x0A)

        let env = Self.environment(bin)

        var text = ""
        var segmentStart = 0          // where the current API message's text began (character offset)
        var gotResult = false
        var succeeded = false   // a successful result: the whole turn is in the session
        var failure: String?
        weak var runnerRef: ProcessRunner?
        let runner = ProcessRunner(
            executable: bin, arguments: args, cwd: cwd, environment: env,
            onLine: { line in
                guard let o = jsonObject(line), let type = o["type"] as? String else { return }
                switch type {
                case "system":
                    if (o["subtype"] as? String) == "init" {
                        if let s = o["session_id"] as? String { onEvent(.session(s)) }
                        if let m = o["model"] as? String { onEvent(.model(Self.prettyModel(m) + " · " + effort)) }
                    }
                case "stream_event":
                    guard let ev = o["event"] as? [String: Any], let et = ev["type"] as? String else { return }
                    if et == "message_start" {
                        if !text.isEmpty, !text.hasSuffix("\n\n") {
                            text += "\n\n"   // a new message after a tool call starts a new paragraph
                            onEvent(.delta("\n\n"))
                        }
                        segmentStart = text.count
                    } else if et == "message_delta", let d = ev["delta"] as? [String: Any],
                              (d["stop_reason"] as? String) == "tool_use" {
                        // Drop a short "let me check the notes" lead-in before a tool call; keep real content.
                        let seg = String(text.dropFirst(segmentStart))
                        if !seg.isEmpty, seg.trimmingCharacters(in: .whitespacesAndNewlines).count < 240 {
                            text = String(text.prefix(segmentStart))
                            onEvent(.replace(text))
                        }
                    } else if et == "content_block_start", let cb = ev["content_block"] as? [String: Any] {
                        switch cb["type"] as? String {
                        case "thinking", "redacted_thinking": onEvent(.activity("thinking…"))
                        case "tool_use": onEvent(.activity("looking at the notes…"))
                        default: break
                        }
                    } else if et == "content_block_delta", let d = ev["delta"] as? [String: Any],
                              (d["type"] as? String) == "text_delta", let t = d["text"] as? String {
                        text += t
                        onEvent(.delta(t))
                    }
                case "rate_limit_event":
                    if let info = o["rate_limit_info"] as? [String: Any] {
                        let w = UsageWindow.fromClaude(info)
                        if !w.isEmpty { onEvent(.usage(w)) }
                    }
                case "assistant":
                    // Name the file being read, if any.
                    if let m = o["message"] as? [String: Any], let blocks = m["content"] as? [[String: Any]] {
                        for b in blocks where (b["type"] as? String) == "tool_use" {
                            let input = b["input"] as? [String: Any] ?? [:]
                            let target = (input["file_path"] ?? input["pattern"] ?? input["path"]) as? String ?? ""
                            let name = URL(fileURLWithPath: target).lastPathComponent
                            onEvent(.activity("\((b["name"] as? String) ?? "Reading") \(name)…"))
                        }
                    }
                case "result":
                    gotResult = true
                    runnerRef?.closeStdin()
                    let isError = (o["is_error"] as? Bool) == true
                    let subtype = o["subtype"] as? String ?? ""
                    if isError || subtype != "success" {
                        if subtype == "error_during_execution" && !isError { return }   // our own interrupt
                        var msg = (o["result"] as? String) ?? ((o["errors"] as? [String])?.joined(separator: "\n") ?? subtype)
                        if let r = msg.range(of: "API Error: ") { msg = humanError(String(msg[r.upperBound...]).replacingOccurrences(of: #"^\d{3} "#, with: "", options: .regularExpression)) }
                        failure = msg
                    } else {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let final = o["result"] as? String, !final.isEmpty {
                            // Nothing streamed (shouldn't happen with partial messages on): use the final text.
                            text = final
                            onEvent(.replace(final))
                        }
                        succeeded = true
                        onEvent(.saved)
                    }
                default:
                    break
                }
            },
            onExit: { status, stderr, cancelled in
                // Stop sends SIGINT: Claude Code then saves the partial answer in the session and exits 0.
                // Killed (SIGTERM/SIGKILL), cut off or failed, the text on screen never reached the session.
                if succeeded && failure == nil { onEvent(.finished); return }   // complete, even if Stop came late
                if cancelled {
                    if status != 0 && !text.isEmpty { onEvent(.notKept) }
                    onEvent(.finished)
                    return
                }
                if let failure {
                    if !text.isEmpty { onEvent(.notKept) }
                    onEvent(.failed(Self.withHint(failure)))
                    return
                }
                if gotResult { onEvent(.finished); return }
                if !text.isEmpty { onEvent(.notKept) }
                let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
                onEvent(.failed(text.isEmpty ? "Claude exited (status \(status)) without an answer.\n\(tail)" : "The answer was cut off (status \(status)).\n\(tail)"))
            })
        runnerRef = runner
        do {
            try runner.start(stdin: line, keepStdinOpen: true)
        } catch {
            onEvent(.failed("Could not start Claude: \(error.localizedDescription)"))
            return nil
        }
        return runner
    }

    /// Subscription login only (no API keys), no memory/CLAUDE.md, no updater or MCP connectors.
    nonisolated static func environment(_ bin: URL) -> [String: String] {
        var env = ToolLocator.environment(addingDirsOf: [bin])
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] { env.removeValue(forKey: k) }
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        env["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        return env
    }

    static var workingDirectory: URL {
        let cwd = AppPaths.support.appendingPathComponent("claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        return cwd
    }

    static func withHint(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("/login") || l.contains("not logged in") || l.contains("authentication") || l.contains("oauth") || l.contains("401") {
            return e + "\n\nFix: open Terminal, run `claude`, type /login and sign in, then ask again here."
        }
        return e
    }

    static func prettyModel(_ id: String) -> String {
        // "claude-opus-5-5" -> "Opus 5.5"
        let core = id.replacingOccurrences(of: "claude-", with: "").split(separator: "[").first.map(String.init) ?? id
        let parts = core.split(separator: "-")
        guard let fam = parts.first else { return id }
        let nums = parts.dropFirst().prefix { $0.count <= 2 && Int($0) != nil }
        return fam.capitalized + (nums.isEmpty ? "" : " " + nums.joined(separator: "."))
    }
}
