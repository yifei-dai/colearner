import AppKit
import Foundation
import Testing
@testable import CoLearner

/// Signing an assistant in again after its login expired, and "Ask again" after a failed answer: the errors that
/// count, the Terminal script (run for real against fake tools), and the buttons on the shipped chat page.
@Suite(.serialized)
@MainActor
struct SignInTests {
    @Test func expiredLoginsAreRecognized() {
        #expect(SignIn.isSignInError("Failed to authenticate: OAuth session expired and could not be refreshed", .claude))
        #expect(SignIn.isSignInError("Invalid API key · Please run /login", .claude))
        #expect(SignIn.isSignInError("Not logged in · Please run /login", .claude))
        #expect(SignIn.isSignInError("unexpected status 401 Unauthorized", .codex))
        #expect(SignIn.isSignInError("Not logged in. Run `codex login`.", .codex))
        #expect(!SignIn.isSignInError("Overloaded", .claude))
        #expect(!SignIn.isSignInError("Prompt is too long: 4012 tokens over the limit", .claude))
        #expect(!SignIn.isSignInError("You've hit your usage limit. Try again at 4:01 PM.", .codex))
    }

    @Test func theErrorHintPointsAtTheButton() {
        #expect(ClaudeBackend.withHint("Failed to authenticate: OAuth session expired").contains("Sign in to Claude"))
        #expect(CodexBackend.withHint("unexpected status 401 Unauthorized").contains("Sign in to ChatGPT"))
        #expect(ClaudeBackend.withHint("Overloaded") == "Overloaded")
    }

    @Test func aFailedAnswerRemembersThatItNeedsSignIn() throws {
        var m = ChatMessage(role: .assistant, provider: .claude, text: "", status: .error)
        #expect(m.js["needsSignIn"] == nil)
        m.needsSignIn = true
        #expect(m.js["needsSignIn"] as? Bool == true)
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: data).needsSignIn == true)
    }

    /// The script Terminal runs: the tool's own login (a path with spaces and a quote), without an API key in the
    /// way for Claude, and its exit status written where Co-learner looks.
    @Test func theTerminalScriptRunsTheLoginAndReportsHowItEnded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signin-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("it's a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (p, code, args) in [(Provider.claude, 0, "auth login --claudeai"), (.codex, 3, "login")] {
            let fake = dir.appendingPathComponent("fake \(p.rawValue)")
            try "#!/bin/sh\nprintf '%s|%s' \"$*\" \"${ANTHROPIC_API_KEY:-none}\" > \"$ARGS_FILE\"\nexit \(code)\n"
                .write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let marker = dir.appendingPathComponent("\(p.rawValue).exit")
            let script = dir.appendingPathComponent("Sign in to \(p.displayName).command")
            try SignIn.script(for: p, binary: fake, marker: marker).write(to: script, atomically: true, encoding: .utf8)
            let argsFile = dir.appendingPathComponent("args-\(p.rawValue)")

            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/bin/zsh")
            run.arguments = [script.path]
            run.environment = ["PATH": "/usr/bin:/bin", "TERM": "dumb", "ARGS_FILE": argsFile.path,
                               "ANTHROPIC_API_KEY": "must-not-reach-the-login"]
            run.standardInput = FileHandle.nullDevice
            run.standardOutput = FileHandle.nullDevice
            run.standardError = FileHandle.nullDevice
            try run.run()
            let deadline = Date().addingTimeInterval(10)
            while run.isRunning && Date() < deadline { usleep(20_000) }
            #expect(!run.isRunning)

            // Claude's login never sees an API key from the shell (it would sign in to the wrong account kind).
            let seen = try String(contentsOf: argsFile, encoding: .utf8)
            #expect(seen == args + "|" + (p == .claude ? "none" : "must-not-reach-the-login"))
            let status = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(status == String(code))
        }
    }

    /// For real (set COLEARNER_LIVE_SIGNIN=1): Terminal opens the script with a fake Claude whose login succeeds at
    /// once; Co-learner notices it finished, asks the fake for its status and moves to "signed in".
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLEARNER_LIVE_SIGNIN"] == "1"))
    func liveTerminalSignInIsNoticed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signin-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before = ProcessInfo.processInfo.environment["COLEARNER_SUPPORT_DIR"]
        setenv("COLEARNER_SUPPORT_DIR", root.appendingPathComponent("support").path, 1)
        defer {
            if let before { setenv("COLEARNER_SUPPORT_DIR", before, 1) } else { unsetenv("COLEARNER_SUPPORT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let fake = root.appendingPathComponent("fake claude")
        try """
        #!/bin/sh
        if [ "$1 $2" = "auth status" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai"}'; exit 0; fi
        echo "fake login: $*"
        exit 0

        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let signIn = SignIn()
        var phases: [SignIn.Phase] = []
        signIn.onChange = { _, phase in phases.append(phase) }
        signIn.start(.claude, binary: fake, checkIn: root)
        #expect(phases == [.waiting])
        for _ in 0..<300 where phases.last == .waiting { try await Task.sleep(for: .milliseconds(100)) }
        #expect(phases == [.waiting, .signedIn])
        #expect(!FileManager.default.fileExists(atPath: SignIn.folder.appendingPathComponent("claude.exit").path))
    }

    // MARK: the chat page

    private func thread(_ messages: [[String: Any]]) -> [String: Any] {
        ["hasDeck": true, "deckTitle": "Adversarial Search", "deckPath": "/tmp/signin-deck.pdf", "page": 74,
         "pageCount": 80, "provider": "both", "pages": [74], "history": [], "conversation": ["id": "signin-chat"],
         "area": NSNull(), "messages": messages, "images": [], "quote": NSNull()]
    }

    private let failed: [[String: Any]] = [
        ["id": "q1", "role": "user", "text": "Explain this slide in detail.", "display": "Explain this slide",
         "status": "done", "page": 74],
        ["id": "a1", "role": "assistant", "provider": "claude", "text": "", "status": "error", "page": 74,
         "error": "Failed to authenticate: OAuth session expired and could not be refreshed", "needsSignIn": true],
        ["id": "a2", "role": "assistant", "provider": "codex", "text": "Expected utility, not ranking.",
         "status": "done", "page": 74],
    ]

    @Test func signInThenAskAgainFromTheFailedAnswer() async throws {
        let web = ChatWebFixture()
        try await web.load()
        defer { web.close() }
        try await web.call("setThread", thread(failed))
        try await web.waitFor("document.querySelectorAll('.retry').length === 1")
        #expect(try await web.evaluate("document.querySelector('.retry button.primary').textContent") as? String
                == "Sign in to Claude")

        _ = try await web.evaluate("document.querySelector('.retry button.primary').click(); null;")
        #expect(try await web.waitForMessage(type: "signIn")["provider"] as? String == "claude")

        try await web.call("setSignIn", ["claude": "waiting", "codex": "idle"])
        try await web.waitFor("document.querySelector('.retry button.primary').textContent === 'Open sign-in again'")
        try await web.call("setSignIn", ["claude": "signedIn", "codex": "idle"])
        try await web.waitFor("document.querySelector('.retry button.primary').textContent === 'Ask again'")
        #expect(try await web.evaluate("document.querySelector('.retry .ok').textContent") as? String
                == "Signed in to Claude.")

        _ = try await web.evaluate("document.querySelector('.retry button.primary').click(); null;")
        let again = try await web.waitForMessage(type: "askAgain")
        #expect(again["messageID"] as? String == "a1")
        #expect(again["useArea"] as? Bool == false)

        // A newer Claude answer takes the buttons away from the old failure.
        try await web.call("upsertMessage", ["id": "a3", "role": "assistant", "provider": "claude", "text": "",
                                             "status": "streaming", "page": 74])
        try await web.waitFor("!document.querySelector('.retry')")
        #expect(web.javaScriptErrors.isEmpty)
    }

    @Test func otherFailuresJustOfferAskAgain() async throws {
        let web = ChatWebFixture()
        try await web.load()
        defer { web.close() }
        var msgs = failed
        msgs[1]["error"] = "Overloaded"
        msgs[1].removeValue(forKey: "needsSignIn")
        try await web.call("setThread", thread(msgs))
        try await web.waitFor("!!document.querySelector('.retry button')")
        #expect(try await web.evaluate("document.querySelectorAll('.retry button').length") as? Int == 1)
        #expect(try await web.evaluate("document.querySelector('.retry button').textContent") as? String == "Ask again")
        #expect(web.javaScriptErrors.isEmpty)
    }

    @Test func anAreaQuestionWaitsForTheAreaAgain() async throws {
        let web = ChatWebFixture()
        try await web.load()
        defer { web.close() }
        var msgs = failed
        msgs[0]["areaThumb"] = "data:image/png;base64,iVBORw0KGgo="
        try await web.call("setThread", thread(msgs))
        try await web.call("setSignIn", ["claude": "signedIn", "codex": "idle"])
        try await web.waitFor("document.querySelector('.retry button.primary').textContent === 'Ask again'")
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('.retry button.primary').click(); null;")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!web.messages.contains { $0["type"] as? String == "askAgain" })
        #expect(web.javaScriptErrors.isEmpty)
    }
}
