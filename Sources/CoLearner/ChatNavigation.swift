import Foundation

/// Resolves links against the current deck and saved messages before changing the UI.
enum ChatNavigation {
    struct Destination {
        let deck: Deck
        let conversationID: String
        let messageID: String
        let page: Int?
    }

    static func slide(from request: [String: Any], deckPath: String?, conversationID: String?, pageCount: Int) -> Int? {
        guard deckPath != nil, let page = request["page"] as? Int, page >= 1, page <= pageCount else { return nil }
        // Older slide tags only carry a page. Answer citations also carry their deck and conversation,
        // so a click queued before a deck/chat switch cannot move the newly selected deck.
        if request["deckPath"] != nil || request["conversationID"] != nil {
            guard let sourceDeck = request["deckPath"] as? String, sourceDeck == deckPath,
                  let sourceConversation = request["conversationID"] as? String,
                  sourceConversation == conversationID else { return nil }
        }
        return page
    }

    @MainActor
    static func destination(for result: ChatSearchResult, store: ChatStore, decks: [Deck]) -> Destination? {
        // A legacy result may not have a conversation ID until it is opened and migrated.
        guard let conversation = store.locateMessage(deckPath: result.deckPath, messageID: result.messageID),
              let message = conversation.messages.first(where: { $0.id == result.messageID }) else { return nil }
        let deck = decks.first(where: { $0.path == result.deckPath }) ?? Deck(
            path: result.deckPath, title: URL(fileURLWithPath: result.deckPath).deletingPathExtension().lastPathComponent,
            courseID: "other", courseName: "Saved deck", walkthroughs: [], contextFiles: [])
        return Destination(deck: deck, conversationID: conversation.id, messageID: message.id, page: message.page)
    }
}
