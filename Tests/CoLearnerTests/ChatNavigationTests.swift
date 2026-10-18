import Foundation
import Testing
@testable import CoLearner

@MainActor
struct ChatNavigationTests {
    @Test func slideReferencesRequireValidPagesAndMatchingContext() {
        func page(_ request: [String: Any], deck: String? = "lecture.pdf", count: Int = 12) -> Int? {
            ChatNavigation.slide(from: request, deckPath: deck, conversationID: "current", pageCount: count)
        }
        #expect(page(["page": 12, "deckPath": "lecture.pdf", "conversationID": "current"]) == 12)
        #expect(page(["page": 1]) == 1) // existing slide tags remain compatible
        for invalid: Any in [0, -1, 13, "4", 2.5, NSNull()] {
            #expect(page(["page": invalid]) == nil)
        }
        #expect(page(["page": 1], deck: nil) == nil)
        #expect(page(["page": 1], count: 0) == nil)
        #expect(page(["page": 3, "deckPath": "other.pdf", "conversationID": "current"]) == nil)
        #expect(page(["page": 3, "deckPath": "lecture.pdf", "conversationID": "old"]) == nil)
        #expect(page(["page": 3, "deckPath": "lecture.pdf"]) == nil)
        #expect(page(["page": 3, "conversationID": "current"]) == nil)
    }

    @Test func savedSearchDestinationReopensExactHistoryAndSlide() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colearner-navigation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChatStore(directory: dir)
        let deck = Deck(path: dir.appendingPathComponent("lecture.pdf").path, title: "Harris corners", courseID: "cv",
                        courseName: "Computer Vision", walkthroughs: [], contextFiles: ["notes.tex"])
        let history = store.current(deck.path).id
        store.update(deck.path, history) {
            $0.messages = [ChatMessage(id: "answer", role: .assistant, provider: .claude, text: "Two large eigenvalues", page: 7)]
        }
        #expect(store.save(deck.path))
        store.startNew(deck.path)
        let current = store.current(deck.path).id
        let reopened = ChatStore(directory: dir)
        let results = await reopened.search(query: "eigenvalues")
        let hit = try #require(results.first)
        let destination = try #require(ChatNavigation.destination(for: hit, store: reopened, decks: [deck]))
        #expect(destination.deck == deck) // preserve two-up layout and linked context metadata
        #expect(destination.conversationID == history)
        #expect(destination.messageID == "answer")
        #expect(destination.page == 7)
        #expect(reopened.current(deck.path).id == current) // resolution alone never changes selection
        reopened.setCurrent(destination.deck.path, destination.conversationID)
        #expect(reopened.current(deck.path).id == history)

        let fallback = try #require(ChatNavigation.destination(for: hit, store: reopened, decks: []))
        #expect(fallback.deck.path == deck.path)
        #expect(fallback.deck.title == "lecture")
        reopened.delete(deck.path, history)
        #expect(ChatNavigation.destination(for: hit, store: reopened, decks: [deck]) == nil)
    }
}
