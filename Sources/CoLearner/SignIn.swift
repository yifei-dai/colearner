import AppKit

/// Signing Claude Code or Codex in again when its login has expired, with no one else's help: Co-learner opens
/// Terminal with the tool's own login command (the browser shows the Authorize page; if the page shows a code
/// instead, it goes into that Terminal window), notices when it finished, checks the login, and tells the chat.
@MainActor
final class SignIn {
    enum Phase: String { case idle, waiting, signedIn, failed }

    private(set) var phase: [Provider: Phase] = [:]
    /// Called on every change; the chat page shows the phase under sign-in errors.
    var onChange: (Provider, Phase) -> Void = { _, _ in }
    /// The current watch per tool (a newer Sign in replaces it).
    private var watching: [Provider: UUID] = [:]

    static var folder: URL { AppPaths.support.appendingPathComponent("sign-in", isDirectory: true) }

    /// Error text from Claude Code / Codex that means its login has expired or is missing.
    nonisolated static func isSignInError(_ e: String, _ p: Provider) -> Bool {
        let l = e.lowercased()
        let http401 = l.range(of: #"\b401\b"#, options: .regularExpression) != nil
        switch p {
        case .claude:
            return http401 || l.contains("/login") || l.contains("not logged in") || l.contains("authenticat")
                || l.contains("oauth") || l.contains("log in again") || l.contains("invalid api key")
        case .codex:
            return http401 || l.contains("unauthorized") || l.contains("not logged in") || l.contains("login")
                || l.contains("sign in again") || l.contains("refresh token")
        }
    }

    /// The Terminal script: the login command, then its exit status into `marker` for Co-learner to pick up.
    nonisolated static func script(for p: Provider, binary: URL, marker: URL) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let name = p.displayName
        let login: String
        switch p {
        case .claude:
            // Same account Co-learner uses: no API key in the way, the Claude subscription login.
            login = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN\n"
                + "export DISABLE_AUTOUPDATER=1\n"
                + "\(q(binary.path)) auth login --claudeai"
        case .codex:
            login = "\(q(binary.path)) login"
        }
        return """
        #!/bin/zsh
        # Made by Co-learner to sign \(name) in again. Safe to delete.
        clear
        print -r -- "Signing \(name) in for Co-learner."
        print -r -- "Your browser opens the sign-in page: check it is your account, then click Authorize (or Continue)."
        print -r -- "If the page shows a code instead, paste it here and press Return."
        print
        \(login)
        s=$?
        print -r -- "$s" > \(q(marker.path))
        print
        if [ $s -eq 0 ]; then
          print -r -- "Signed in. Co-learner has noticed; you can close this window."
        else
          print -r -- "The sign-in did not finish (exit $s). Close this window and press Sign in again in Co-learner."
        fi

        """
    }

    /// Opens Terminal with the login for `p` and watches for it to finish.
    func start(_ p: Provider, binary: URL?, checkIn cwd: URL?) {
        guard let binary else {
            let a = NSAlert()
            a.messageText = "\(p.displayName) isn't installed where Co-learner can find it"
            a.informativeText = p == .claude
                ? "Open the Claude desktop app once (it keeps Claude Code up to date), then restart Co-learner."
                : "Install the Codex CLI (npm i -g @openai/codex), then restart Co-learner."
            a.runModal()
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let marker = Self.folder.appendingPathComponent("\(p.rawValue).exit")
        try? fm.removeItem(at: marker)
        let file = Self.folder.appendingPathComponent("Sign in to \(p.displayName).command")
        do {
            try Self.script(for: p, binary: binary, marker: marker).write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            set(p, .failed)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let done: @Sendable (NSRunningApplication?, Error?) -> Void = { [weak self] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.set(p, .failed) } }
        }
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: config, completionHandler: done)
        } else {
            NSWorkspace.shared.open(file, configuration: config, completionHandler: done)
        }
        set(p, .waiting)
        watch(p, marker: marker, binary: binary, cwd: cwd)
    }

    /// Checks once a second for the script's exit status (for up to 20 minutes), then asks the tool itself.
    private func watch(_ p: Provider, marker: URL, binary: URL, cwd: URL?) {
        let token = UUID()
        watching[p] = token
        let started = Date()
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.watching[p] == token else { return }
                    if Date().timeIntervalSince(started) > 20 * 60 {
                        self.watching[p] = nil
                        if self.phase[p] == .waiting { self.set(p, .idle) }
                        return
                    }
                    guard let s = try? String(contentsOf: marker, encoding: .utf8) else { tick(); return }
                    self.watching[p] = nil
                    try? FileManager.default.removeItem(at: marker)
                    guard s.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { self.set(p, .failed); return }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let ok = Self.isSignedIn(p, binary: binary, cwd: cwd)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.set(p, ok ? .signedIn : .failed)
                                // Back to Co-learner, where "Ask again" waits.
                                if ok { NSApplication.shared.activate(ignoringOtherApps: true) }
                            }
                        }
                    }
                }
            }
        }
        tick()
    }

    private func set(_ p: Provider, _ ph: Phase) {
        phase[p] = ph
        onChange(p, ph)
    }

    /// Asks the tool whether it is signed in (no model is called).
    nonisolated static func isSignedIn(_ p: Provider, binary: URL, cwd: URL?) -> Bool {
        switch p {
        case .claude:
            let r = run(binary, ["auth", "status"], env: ClaudeBackend.environment(binary), cwd: cwd)
            guard r.status == 0,
                  let o = (try? JSONSerialization.jsonObject(with: Data(r.output.utf8))) as? [String: Any] else { return false }
            return o["loggedIn"] as? Bool == true
        case .codex:
            // Prints "Logged in using ChatGPT" (on stderr) and exits 0 when signed in.
            let r = run(binary, ["login", "status"], env: ToolLocator.environment(addingDirsOf: [binary]), cwd: cwd)
            return r.status == 0 && r.output.contains("Logged in")
        }
    }

    /// Runs a short tool command; stdout and stderr together, with a 20 s limit.
    nonisolated private static func run(_ exe: URL, _ args: [String], env: [String: String], cwd: URL?) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return (-1, "") }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, s)
    }
}
