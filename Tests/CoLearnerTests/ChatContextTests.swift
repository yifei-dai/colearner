import Foundation
import Testing
@testable import CoLearner

@Suite(.serialized)
@MainActor
struct ChatContextTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colearner-context-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func deck(_ dir: URL) -> Deck {
        Deck(path: dir.appendingPathComponent("lecture.pdf").path, title: "Lecture", courseID: "fixture",
             courseName: "Fixture", walkthroughs: [], contextFiles: [])
    }

    @Test(arguments: Provider.allCases)
    func recoveryResetsOnlyInterruptedProvider(provider: Provider) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("lecture.pdf").path
        let other: Provider = provider == .claude ? .codex : .claude
        let store = ChatStore(directory: dir)
        let id = store.current(path).id
        store.update(path, id) { c in
            c.claudeSession = "claude-session"
            c.codexSession = "codex-session"
            c.seenBy = [provider.rawValue: ["question"], other.rawValue: ["earlier"]]
            c.seenSlides = [provider.rawValue: [1, 2], other.rawValue: [1]]
            c.messages = [ChatMessage(id: "question", role: .user, text: "Explain slide 2", page: 2),
                          ChatMessage(role: .assistant, provider: provider, text: "Partial answer", status: .streaming,
                                      activity: "thinking…", page: 2)]
        }
        #expect(store.save(path))

        let recovered = ChatStore(directory: dir).current(path)
        #expect(recovered.id == id)
        #expect(recovered.messages.map(\.text) == ["Explain slide 2", "Partial answer"])
        #expect(recovered.messages.last?.status == .stopped)
        #expect(recovered.messages.last?.activity == nil)
        #expect(recovered.messages.last?.notInSession == true)
        #expect(recovered.session(for: provider) == nil)
        #expect(recovered.seenBy?[provider.rawValue] == nil)
        #expect(recovered.seenSlides?[provider.rawValue] == nil)
        #expect(recovered.session(for: other) == "\(other.rawValue)-session")
        #expect(recovered.seenBy?[other.rawValue] == ["earlier"])
        #expect(recovered.seenSlides?[other.rawValue] == [1])
        // Recovery is persisted; a second launch cannot resurrect the interrupted session.
        #expect(ChatStore(directory: dir).current(path).session(for: provider) == nil)
    }

    @Test func recoveryHandlesUnknownLegacyProviderConservatively() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChatStore(directory: dir)
        let id = store.current("legacy.pdf").id
        store.update("legacy.pdf", id) { c in
            c.claudeSession = "claude"
            c.codexSession = "codex"
            c.messages = [ChatMessage(role: .assistant, text: "", status: .streaming)]
        }
        #expect(store.save("legacy.pdf"))
        let recovered = ChatStore(directory: dir).current("legacy.pdf")
        #expect(recovered.claudeSession == nil && recovered.codexSession == nil)
        #expect(recovered.messages.first?.status == .stopped)
    }

    @Test func finishedConversationsKeepTheirSessionsAfterReload() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChatStore(directory: dir)
        let id = store.current("finished.pdf").id
        store.update("finished.pdf", id) { c in
            c.claudeSession = "saved-session"
            c.seenSlides = ["claude": [1]]
            c.contextRevisions = ["claude": "version"]
            c.messages = [ChatMessage(role: .assistant, provider: .claude, text: "Finished", status: .done)]
        }
        #expect(store.save("finished.pdf"))
        let recovered = ChatStore(directory: dir).current("finished.pdf")
        #expect(recovered.claudeSession == "saved-session")
        #expect(recovered.seenSlides?["claude"] == [1])
        #expect(recovered.contextRevisions?["claude"] == "version")
    }

    @Test func revisedDeckRestartsBothProvidersAndRetainsHistoryAcrossLaunches() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = deck(dir)
        try Data("old slide".utf8).write(to: d.url, options: .atomic)
        let revision = SourceRevision.context(for: d)
        let oldImageKey = SlideImages.cacheKey(for: d)
        let oldDate = try #require(FileManager.default.attributesOfItem(atPath: d.path)[.modificationDate] as? Date)
        let store = ChatStore(directory: dir.appendingPathComponent("chats"))
        let id = store.current(d.path).id
        store.update(d.path, id) { c in
            for p in Provider.allCases { c.prepareContext(revision, for: p); c.setSession("old-\(p.rawValue)", for: p) }
            c.seenBy = ["claude": ["question"], "codex": ["question"]]
            c.seenSlides = ["claude": [1], "codex": [1]]
            c.messages = [ChatMessage(id: "question", role: .user, text: "Explain this slide", page: 1)]
        }
        #expect(store.save(d.path))
        // Atomic replacement of equal length, even with the old mtime restored, must invalidate images too.
        try Data("new slide".utf8).write(to: d.url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: d.path)
        let updatedRevision = SourceRevision.context(for: d)
        #expect(updatedRevision != revision)
        #expect(SlideImages.cacheKey(for: d) != oldImageKey)
        let reopened = ChatStore(directory: dir.appendingPathComponent("chats"))
        reopened.update(d.path, id) { c in
            for p in Provider.allCases {
                let changed = c.prepareContext(updatedRevision, for: p)
                #expect(changed)
                #expect(c.session(for: p) == nil) // send() must build a new deck header.
                #expect(c.seenSlides?[p.rawValue] == nil) // Revised slide images are attached again.
                #expect(c.seenBy?[p.rawValue] == nil)
            }
        }
        #expect(reopened.current(d.path).messages.first?.id == "question")
        #expect(reopened.save(d.path))
        #expect(ChatStore(directory: dir.appendingPathComponent("chats")).current(d.path).contextRevisions?["claude"] == updatedRevision)
    }

    @Test func unchangedContextPreservesResumeButOldUnversionedSessionsReset() {
        var c = Conversation(claudeSession: "old", codexSession: "other", seenSlides: ["claude": [1], "codex": [2]])
        let reset = c.prepareContext("current", for: .claude)
        #expect(reset)
        #expect(c.claudeSession == nil && c.seenSlides?["claude"] == nil)
        #expect(c.codexSession == "other" && c.seenSlides?["codex"] == [2])
        c.setSession("fresh", for: .claude)
        c.seenSlides = ["claude": [1]]
        let unchanged = c.prepareContext("current", for: .claude)
        #expect(!unchanged)
        #expect(c.claudeSession == "fresh" && c.seenSlides?["claude"] == [1])
    }

    @Test func linkingUnlinkingAndEditingNotesChangeContext() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = deck(dir)
        try Data("slide".utf8).write(to: d.url)
        let original = SourceRevision.context(for: d)
        let notes = dir.appendingPathComponent("notes.tex")
        try Data("notes one".utf8).write(to: notes)
        d.contextFiles = [notes.path]
        let linked = SourceRevision.context(for: d)
        #expect(linked != original)
        try Data("notes two".utf8).write(to: notes, options: .atomic)
        #expect(SourceRevision.context(for: d) != linked)
        d.contextFiles = []
        #expect(SourceRevision.context(for: d) == original)
        d.walkthroughs = [StudyPage(title: "Walkthrough", path: dir.appendingPathComponent("review.html").path)]
        let htmlLinked = SourceRevision.context(for: d)
        #expect(htmlLinked != original)
        try Data("newly created HTML".utf8).write(to: URL(fileURLWithPath: d.walkthroughs[0].path))
        #expect(SourceRevision.context(for: d) != htmlLinked)
    }

    @Test func sourceOrderingDoesNotResetContext() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = deck(dir)
        d.contextFiles = ["a.tex", "b.tex"]
        d.walkthroughs = [StudyPage(title: "A", path: "a.html"), StudyPage(title: "B", path: "b.html")]
        let revision = SourceRevision.context(for: d)
        d.contextFiles.reverse()
        d.walkthroughs.reverse()
        #expect(SourceRevision.context(for: d) == revision)
    }
}
