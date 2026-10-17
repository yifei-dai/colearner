import Foundation

/// Runs a command-line tool, hands every stdout line to `onLine` on the main thread (in order),
/// and reports the exit status plus the tail of stderr once the output is fully read.
final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let inPipe = Pipe()
    private let lock = NSLock()
    private var errData = Data()
    private var cancelled = false
    private var outDone = false
    private let stdinQueue = DispatchQueue(label: "colearner.stdin")   // keeps write-then-close in order

    let onLine: @MainActor (String) -> Void
    let onExit: @MainActor (_ status: Int32, _ stderr: String, _ cancelled: Bool) -> Void

    init(executable: URL, arguments: [String], cwd: URL?, environment: [String: String],
         onLine: @escaping @MainActor (String) -> Void,
         onExit: @escaping @MainActor (Int32, String, Bool) -> Void) {
        self.onLine = onLine
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = environment
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
    }

    func start(stdin: Data?, keepStdinOpen: Bool = false) throws {
        process.terminationHandler = { [weak self] _ in
            // A grandchild that inherited stdout could keep the pipe open; stop waiting after a moment.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard let self else { return }
                self.lock.lock(); let done = self.outDone; self.lock.unlock()
                if !done { try? self.outPipe.fileHandleForReading.close() }
            }
        }
        // No stdin data: give the child /dev/null so tools that wait for EOF on stdin (codex) never hang.
        if stdin == nil { process.standardInput = FileHandle.nullDevice }
        try process.run()
        if let stdin {
            // Off the main thread: a big image can fill the pipe buffer before the child reads it.
            // (SIGPIPE is ignored app-wide, so a child that dies early only makes this write throw.)
            let h = inPipe.fileHandleForWriting
            let close = !keepStdinOpen
            stdinQueue.async {
                try? h.write(contentsOf: stdin)
                if close { try? h.close() }
            }
        }

        let errHandle = errPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            while let d = Self.readSome(errHandle) {
                lock.lock()
                errData.append(d)
                if errData.count > 64_000 { errData = Data(errData.suffix(32_000)) }
                lock.unlock()
            }
        }
        let outHandle = outPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = Data()
            func flush(final: Bool) {
                var lines: [String] = []
                while let nl = buffer.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                if final, !buffer.isEmpty {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll()
                }
                let clean = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !clean.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { for l in clean { self.onLine(l) } } }
                }
            }
            while let d = Self.readSome(outHandle) {
                buffer.append(d)
                flush(final: false)
            }
            flush(final: true)
            lock.lock(); outDone = true; lock.unlock()
            process.waitUntilExit()
            usleep(100_000)   // let the stderr reader catch the last bytes
            lock.lock()
            let err = String(decoding: errData.suffix(4000), as: UTF8.self)
            let wasCancelled = cancelled
            lock.unlock()
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onExit(status, err, wasCancelled) } }
        }
    }

    var isRunning: Bool { process.isRunning }

    /// Blocks until *some* bytes arrive and returns them; nil at end of file or on error.
    /// (FileHandle.read(upToCount:) would wait for the full count, which stalls streaming output.)
    private static func readSome(_ h: FileHandle) -> Data? {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(h.fileDescriptor, &buf, buf.count)
            if n > 0 { return Data(buf[0..<n]) }
            if n < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// Ends the input stream (for tools that wait for EOF before exiting).
    func closeStdin() {
        let h = inPipe.fileHandleForWriting
        stdinQueue.async { try? h.close() }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.interrupt()                      // SIGINT first, like Ctrl-C
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.process.terminate()             // then SIGTERM
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if self.process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

/// Finds command-line tools for a GUI app, which does not inherit the shell's PATH.
enum ToolLocator {
    static func find(_ name: String, candidates: [String]) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let key = "toolPath.\(name)"
        if let saved = UserDefaults.standard.string(forKey: key), fm.isExecutableFile(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        for c in candidates {
            let p = c.replacingOccurrences(of: "~", with: home)
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        // Ask a login shell, which loads the user's PATH (nvm, Homebrew, ~/.local/bin, …).
        if let p = shellWhich(name), fm.isExecutableFile(atPath: p) {
            UserDefaults.standard.set(p, forKey: key)
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static func shellWhich(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
    }

    /// PATH for child processes: the usual places tools live, plus the tool's own folder.
    static func environment(addingDirsOf tools: [URL]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // If the app was started from inside a Claude Code session, don't let the child think it is nested.
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDE_AGENT_SDK_VERSION" {
            env.removeValue(forKey: k)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = tools.map { $0.resolvingSymlinksInPath().deletingLastPathComponent().path }
        dirs += tools.map { $0.deletingLastPathComponent().path }
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (dirs + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }
}
