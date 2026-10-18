import Foundation
import Testing
@testable import CoLearner

@Suite(.serialized)
@MainActor
struct ChatSearchTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colearner-search-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ chats: DeckChats, in directory: URL, suffix: String = ".chat2.json") throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(ChatArchiveFile.base(chats.deckPath) + suffix)
        try encoder.encode(chats).write(to: url)
        return url
    }

    private func message(_ id: String, _ text: String, at time: TimeInterval = 100, page: Int? = 1) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, createdAt: Date(timeIntervalSince1970: time), page: page)
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path).map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
    }

    @Test func searchesUnloadedDecksWithAllWordsAndUsefulMetadata() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = message("first", String(repeating: "unrelated words ", count: 30) + "Café gradient descent converges.", page: 4)
        var second = message("second", "The GRADIENT of the cafe example", at: 200, page: 7)
        second.role = .assistant
        second.provider = .codex
        let a = Conversation(id: "conversation-a", messages: [first, message("only-cafe", "cafe")])
        let b = Conversation(id: "conversation-b", messages: [second, message("only-gradient", "gradient")])
        try write(DeckChats(deckPath: "/decks/a.pdf", conversations: [a]), in: dir)
        try write(DeckChats(deckPath: "/decks/b.pdf", conversations: [b]), in: dir)

        let results = await ChatStore(directory: dir).search(query: "  CAFE   gradient ")
        #expect(results.map(\.messageID) == ["second", "first"])
        #expect(results[0].deckPath == "/decks/b.pdf")
        #expect(results[0].conversationID == "conversation-b")
        #expect(results[0].role == .assistant && results[0].provider == .codex)
        #expect(results[0].page == 7 && results[0].createdAt == second.createdAt)
        #expect(results[1].snippet.hasPrefix("…"))
        #expect(results[1].snippet.contains("Café gradient"))
        #expect(results[1].snippet.count <= 222)
    }

    @Test func includesUnsavedCachedMessagesAndHonorsCachedDeletions() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "/decks/active.pdf"
        try write(DeckChats(deckPath: path, conversations: [Conversation(id: "active", messages: [message("deleted", "needle old")])], current: "active"), in: dir)
        try write(DeckChats(deckPath: "/decks/unloaded.pdf", conversations: [Conversation(id: "unloaded", messages: [message("disk", "needle disk", at: 300)])]), in: dir)
        let store = ChatStore(directory: dir)
        store.update(path, store.current(path).id) { c in
            c.messages = [message("live", "needle streaming", at: 400)]
            c.messages[0].status = .streaming
        }
        let before = try snapshot(dir)
        let results = await store.search(query: "needle")
        #expect(results.map(\.messageID) == ["live", "disk"])
        #expect(try snapshot(dir) == before)
    }

    @Test func searchingLegacyAndUnreadableFilesNeverMigratesOrWrites() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "/decks/legacy.pdf"
        let legacy = DeckChats(deckPath: path, threads: ["6": ChatThread(page: 6, messages: [message("legacy-message", "needle legacy", page: nil)])])
        try write(legacy, in: dir, suffix: ".json")
        try Data("not valid JSON".utf8).write(to: dir.appendingPathComponent(ChatArchiveFile.base(path) + ".chat2.json"))
        try write(DeckChats(deckPath: path, conversations: [Conversation(messages: [message("backup", "needle backup")])]), in: dir, suffix: ".v1.json")
        let store = ChatStore(directory: dir)
        let before = try snapshot(dir)
        let first = await store.search(query: "needle")
        let second = await store.search(query: "needle")
        #expect(first.map(\.messageID) == ["legacy-message"])
        #expect(first.first?.conversationID == nil)
        #expect(first.first?.page == 6)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(try snapshot(dir) == before)

        // Clicking a legacy result, unlike searching, intentionally uses the real migration path.
        let located = store.locateMessage(deckPath: path, messageID: "legacy-message")
        #expect(located?.messages.first?.id == "legacy-message")
        #expect(located?.messages.first?.page == 6)
    }

    @Test func currentArchivesDeduplicateMigrationAndSuppressDeletedImports() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "/decks/migrated.pdf"
        let keep = message("kept", "needle kept")
        let removed = message("removed", "needle deleted")
        let fresh = message("fresh", "needle from old app", at: 300)
        let current = DeckChats(deckPath: path, conversations: [Conversation(id: "migrated", messages: [keep], legacy: true)],
                                current: "migrated", importedV1: [keep.id, removed.id])
        try write(current, in: dir)
        try write(DeckChats(deckPath: path, threads: ["3": ChatThread(page: 3, messages: [keep, removed, fresh])]), in: dir, suffix: ".json")
        try write(DeckChats(deckPath: path, conversations: [Conversation(messages: [removed])]), in: dir, suffix: ".chat2.unreadable-20.json")
        let store = ChatStore(directory: dir)
        let before = try snapshot(dir)
        let result = await store.search(query: "needle")
        #expect(result.map(\.messageID) == ["fresh", "kept"])
        #expect(result[0].conversationID == nil && result[1].conversationID == "migrated")
        #expect(try snapshot(dir) == before)
        #expect(store.locateMessage(deckPath: path, messageID: "fresh")?.messages.first?.id == "fresh")
        #expect(store.locateMessage(deckPath: path, messageID: "removed") == nil)
    }

    @Test func oldMigrationWithoutTombstonesUsesTheExistingDateRule() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "/decks/old-migration.pdf"
        let current = Conversation(id: "new-chat", created: Date(timeIntervalSince1970: 200), messages: [message("current", "needle current", at: 250)])
        try write(DeckChats(deckPath: path, conversations: [current]), in: dir)
        let thread = ChatThread(page: 9, messages: [message("deleted-at-migration", "needle old", at: 100), message("added-later", "needle new", at: 300)])
        try write(DeckChats(deckPath: path, threads: ["9": thread]), in: dir, suffix: ".json")
        let result = await ChatStore(directory: dir).search(query: "needle")
        #expect(result.map(\.messageID) == ["added-later", "current"])
    }

    @Test func recoverableArchivesMatchLoadingWithoutResurrectingConsumedBackups() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "/decks/recovered.pdf"
        let recovered = message("recovered", "needle recovery", at: 200)
        let leftover = message("leftover", "needle legacy", at: 100)
        try write(DeckChats(deckPath: path, conversations: [Conversation(id: "recovered-chat", messages: [recovered])]), in: dir, suffix: ".chat2.unreadable-20.json")
        try write(DeckChats(deckPath: path, threads: ["5": ChatThread(page: 5, messages: [recovered, leftover])]), in: dir, suffix: ".json")
        try write(DeckChats(deckPath: path, conversations: [Conversation(messages: [message("consumed", "needle consumed")])]), in: dir, suffix: ".chat2.recovered-10.json")
        let store = ChatStore(directory: dir)
        let before = try snapshot(dir)
        let result = await store.search(query: "needle")
        #expect(result.map(\.messageID) == ["recovered", "leftover"])
        #expect(result[0].conversationID == "recovered-chat")
        #expect(try snapshot(dir) == before)
        #expect(store.locateMessage(deckPath: path, messageID: "recovered")?.id == "recovered-chat")
        #expect(store.locateMessage(deckPath: path, messageID: "consumed") == nil)
    }

    @Test func displayLabelsEmptyQueriesAndResultLimitArePredictable() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "/decks/large.pdf"
        var messages = (0..<110).map { message("m-\($0)", "needle \($0)", at: Double($0)) }
        messages.append(ChatMessage(id: "label", role: .user, text: "Long internal prompt", display: "Visualize this slide", createdAt: Date(timeIntervalSince1970: 500)))
        try write(DeckChats(deckPath: path, conversations: [Conversation(messages: messages)]), in: dir)
        let store = ChatStore(directory: dir)
        let results = await store.search(query: "needle")
        #expect(results.count == 100)
        #expect(results.first?.messageID == "m-109" && results.last?.messageID == "m-10")
        let label = await store.search(query: "visualize")
        #expect(label.first?.messageID == "label")
        #expect(label.first?.snippet.contains("Visualize this slide") == true)
        let empty = await store.search(query: " \n\t ")
        #expect(empty.isEmpty)
    }
}
