import Foundation
import Testing
@testable import CoLearner

@Suite(.serialized)
@MainActor
struct BackendTests {
    private let partial = #"{"type":"item.completed","item":{"type":"agent_message","text":"I will start by explaining..."}}"#
    private let completed = #"{"type":"turn.completed"}"#
    private let failure = #"{"type":"turn.failed","error":{"message":"Connection lost"}}"#
    private let retry = #"{"type":"error","message":"Retrying the stream"}"#

    @Test(arguments: [0, 1])
    func partialAnswerWithoutCompletedTurnFails(exitCode: Int) async throws {
        let result = try await run(lines: [partial], exitCode: exitCode)
        #expect(result.events == ["answer", "notKept", "failed"])
        #expect(result.error?.contains("before the answer finished") == true)
        #expect(result.error?.contains("status \(exitCode)") == true)
        #expect(result.error?.contains("fixture stderr") == true)
        #expect(result.exitStatus == Int32(exitCode))
    }

    @Test
    func explicitFailurePreservesPartialAnswerAndError() async throws {
        let result = try await run(lines: [partial, failure], exitCode: 1)
        #expect(result.events == ["answer", "notKept", "failed"])
        #expect(result.error == "Connection lost")
    }

    @Test
    func emptyIncompleteTurnFailsWithoutMarkingPartialText() async throws {
        let result = try await run(lines: [], exitCode: 0)
        #expect(result.events == ["failed"])
        #expect(result.error?.contains("without an answer") == true)
    }

    @Test(arguments: [0, 1])
    func completedTurnSucceedsDespiteRetryOrExitStatus(exitCode: Int) async throws {
        let result = try await run(lines: [retry, partial, completed], exitCode: exitCode)
        #expect(result.events == ["answer", "saved", "finished"])
        #expect(result.error == nil)
    }

    @Test
    func cancellationKeepsStopSemanticsAndReplaysUnfinishedText() async throws {
        let result = try await run(lines: [partial], cancelWhen: "answer")
        #expect(result.events == ["answer", "notKept", "finished"])
        #expect(result.error == nil)
    }

    @Test
    func cancellationAfterCompletionKeepsSavedTurn() async throws {
        let result = try await run(lines: [partial, completed], cancelWhen: "saved")
        #expect(result.events == ["answer", "saved", "finished"])
        #expect(result.error == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func fastModeSetsTierForNewAndResumedTurns(fastMode: Bool, resumed: Bool) async throws {
        let request = BackendRequest(prompt: "fixture question", instructions: "fixture instructions",
                                     resume: resumed ? "existing-thread" : nil,
                                     model: "fixture-model", effort: "high", fastMode: fastMode)
        let result = try await run(lines: [partial, completed], request: request)
        #expect(result.error == nil)
        let args = result.arguments
        func values(after flag: String) -> [String] {
            args.indices.dropLast().filter { args[$0] == flag }.map { args[$0 + 1] }
        }
        #expect(values(after: "-m") == ["fixture-model"])
        #expect(values(after: "-c").contains("model_reasoning_effort=high"))
        #expect(values(after: "--enable").contains("fast_mode"))
        // Explicit default clears a previous Fast turn when resuming the same chat.
        #expect(values(after: "-c").filter { $0.hasPrefix("service_tier=") } ==
                ["service_tier=\(fastMode ? "fast" : "default")"])
        #expect(values(after: "resume") == (resumed ? ["existing-thread"] : []))
        #expect(args.contains("--ignore-user-config"))
        #expect(values(after: "-s") == ["read-only"])
        #expect(result.model == "fixture-model · high" + (fastMode ? " · Fast" : ""))
    }

    private struct Result {
        var events: [String] = []
        var error: String?
        var exitStatus: Int32?
        var arguments: [String] = []
        var model: String?
    }

    private enum FixtureError: Error { case timedOut }

    /// A real ProcessRunner consumes a tiny local CLI fixture. No installed AI CLI or session log is used.
    private func run(lines: [String], exitCode: Int = 0, cancelWhen: String? = nil,
                     request: BackendRequest = BackendRequest(prompt: "fixture question", instructions: "fixture instructions")) async throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colearner-backend-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("fake-codex")
        let argumentsFile = dir.appendingPathComponent("arguments.txt")
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = "#!/bin/sh\n"
        script += "printf '%s\\n' \"$@\" > " + quote(argumentsFile.path) + "\n"
        script += lines.map { "printf '%s\\n' " + quote($0) }.joined(separator: "\n") + "\n"
        script += "printf '%s\\n' 'fixture stderr' >&2\n"
        // exec keeps the same PID and no grandchild keeps its output pipe open when cancelled.
        script += cancelWhen == nil ? "exit \(exitCode)\n" : "exec /bin/sleep 30\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let backend = CodexBackend(binary: executable, workDirectory: dir, readUsage: { _ in [] })
        return try await withCheckedThrowingContinuation { continuation in
            var result = Result()
            var settled = false
            var handle: RunHandle?
            handle = backend.start(request) { event in
                guard !settled else { return }
                let name: String
                switch event {
                case .model(let model): result.model = model; return
                case .replace: name = "answer"
                case .saved: name = "saved"
                case .notKept: name = "notKept"
                case .finished: name = "finished"
                case .failed(let message): name = "failed"; result.error = message
                default: return
                }
                result.events.append(name)
                if name == cancelWhen { handle?.cancel() }
                if name == "finished" || name == "failed" {
                    result.exitStatus = handle?.exitStatus
                    result.arguments = ((try? String(contentsOf: argumentsFile, encoding: .utf8)) ?? "")
                        .split(separator: "\n").map(String.init)
                    settled = true
                    handle = nil
                    continuation.resume(returning: result)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !settled else { return }
                settled = true
                handle?.terminateNow()
                handle = nil
                continuation.resume(throwing: FixtureError.timedOut)
            }
        }
    }
}
