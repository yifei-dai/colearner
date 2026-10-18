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

    private struct Result {
        var events: [String] = []
        var error: String?
        var exitStatus: Int32?
    }

    private enum FixtureError: Error { case timedOut }

    /// A real ProcessRunner consumes a tiny local CLI fixture. No installed AI CLI or session log is used.
    private func run(lines: [String], exitCode: Int = 0, cancelWhen: String? = nil) async throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colearner-backend-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("fake-codex")
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = "#!/bin/sh\n"
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
            handle = backend.start(BackendRequest(prompt: "fixture question", instructions: "fixture instructions")) { event in
                guard !settled else { return }
                let name: String
                switch event {
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
