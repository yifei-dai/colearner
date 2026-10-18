import AppKit
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct ChatSearchUITests {
    private func query(_ text: String, in web: ChatWebFixture) async throws {
        let json = try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])
        _ = try await web.evaluate("document.querySelector('#search-input').value = \(String(decoding: json, as: UTF8.self)); document.querySelector('#search-input').dispatchEvent(new Event('input')); null;")
    }

    private func response(_ request: [String: Any], results: [[String: Any]] = [], error: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["query": request["query"]!, "requestID": request["requestID"]!, "results": results]
        if let error { payload["error"] = error }
        return payload
    }

    private func result(id: String = "hit", messageID: String = "target") -> [String: Any] {
        ["id": id, "deckTitle": "Information Theory and Learning", "courseName": "Machine Learning",
         "deckPath": "/tmp/search-deck.pdf", "conversationID": "found-chat", "messageID": messageID,
         "page": 3, "role": "assistant", "provider": "claude", "snippet": "Entropy measures uncertainty in a distribution.",
         "created": 1_792_320_000]
    }

    private func thread() -> [String: Any] {
        ["hasDeck": true, "deckTitle": "Information Theory and Learning", "deckPath": "/tmp/search-deck.pdf",
         "page": 1, "pageCount": 20, "provider": "claude", "pages": [1, 3], "history": [],
         "conversation": ["id": "found-chat"], "area": NSNull(),
         "messages": [["id": "intro", "role": "user", "page": 1, "text": "What is uncertainty?", "status": "done"],
                      ["id": "target", "role": "assistant", "provider": "claude", "page": 3,
                       "text": "Entropy measures uncertainty. Compare slide 12.", "status": "done"]]]
    }

    @Test func searchAvailableWithoutDeckDebouncesAndRejectsStaleReplies() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        #expect(try await web.evaluate("document.querySelector('#head-actions').hidden") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('#btn-search').getBoundingClientRect().width > 0") as? Bool == true)
        _ = try await web.evaluate("document.querySelector('#btn-search').click(); null;")
        #expect(try await web.evaluate("document.activeElement.id") as? String == "search-input")
        #expect(try await web.evaluate("document.querySelector('#search-status').textContent") as? String == "Type to search your saved chats.")

        try await query("old", in: web)
        let old = try await web.waitForMessage(type: "searchChats")
        web.clearMessages()
        try await query("ent", in: web)
        try await query(" entropy ", in: web)
        let latest = try await web.waitForMessage(type: "searchChats")
        try await Task.sleep(for: .milliseconds(250))
        #expect(web.messages.filter { $0["type"] as? String == "searchChats" }.count == 1)
        #expect(latest["query"] as? String == "entropy")
        #expect(latest["requestID"] as? Int != old["requestID"] as? Int)
        try await web.call("setSearchResults", response(old, results: [result(id: "stale")]))
        #expect(try await web.evaluate("document.querySelectorAll('.search-result').length") as? Int == 0)
        #expect(try await web.evaluate("document.querySelector('#search-status').textContent") as? String == "Searching…")

        var hostile = result()
        hostile["deckTitle"] = "<img src=x onerror=alert(1)>"
        hostile["snippet"] = "Entropy <script>window.searchInjected = true</script>"
        try await web.call("setSearchResults", response(latest, results: [hostile]))
        #expect(try await web.evaluate("document.querySelectorAll('.search-result').length") as? Int == 1)
        #expect(try await web.evaluate("document.querySelectorAll('#search-results img, #search-results script').length") as? Int == 0)
        #expect(try await web.evaluate("document.querySelector('.search-result-title').textContent") as? String == hostile["deckTitle"] as? String)
        #expect(try await web.evaluate("document.querySelector('#search-results mark').textContent") as? String == "Entropy")

        _ = try await web.evaluate("document.querySelector('#search-input').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true})); null;")
        #expect(try await web.evaluate("document.querySelector('#search-layer').hidden") as? Bool == true)
        #expect(try await web.evaluate("document.activeElement.id") as? String == "btn-search")
        try await web.call("openSearch", NSNull())
        try await web.call("setSearchResults", response(latest, results: [result(id: "late")]))
        #expect(try await web.evaluate("document.querySelectorAll('.search-result').length") as? Int == 0)
    }

    @Test func emptyAndFailedOpenRecoverBeforeRevealingMatchedMessage() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("openSearch", NSNull())
        try await query("missing", in: web)
        let empty = try await web.waitForMessage(type: "searchChats")
        try await web.call("setSearchResults", response(empty))
        #expect(try await web.evaluate("document.querySelector('#search-status').textContent.includes('No matches')") as? Bool == true)

        web.clearMessages()
        try await query("entropy", in: web)
        let request = try await web.waitForMessage(type: "searchChats")
        try await web.call("setSearchResults", response(request, results: [result()]))
        _ = try await web.evaluate("document.querySelector('.search-result').click(); null;")
        let open = try await web.waitForMessage(type: "openSearchResult")
        #expect(open["id"] as? String == "hit")
        #expect(open.count == 2) // Only the native-issued ID is sent back, never a path from rendered text.
        #expect(try await web.evaluate("document.querySelector('#search-layer').hidden") as? Bool == false)
        #expect(try await web.evaluate("document.querySelector('#search-input').disabled") as? Bool == true)

        try await web.call("setSearchResults", response(request, error: "The PDF could not be opened. Try again."))
        #expect(try await web.evaluate("document.querySelector('#search-status').classList.contains('error')") as? Bool == true)
        #expect(try await web.evaluate("document.querySelectorAll('.search-result').length") as? Int == 1)
        #expect(try await web.evaluate("document.querySelector('.search-result').disabled || document.querySelector('#search-input').disabled") as? Bool == false)

        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('.search-result').click(); null;")
        _ = try await web.waitForMessage(type: "openSearchResult")
        try await web.call("setThread", thread())
        try await web.call("revealMessage", ["messageID": "target"])
        try await web.waitFor("document.activeElement.dataset.messageId === 'target'")
        #expect(try await web.evaluate("document.querySelector('#search-layer').hidden") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('#viewseg [data-v=all]').classList.contains('on')") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('.search-highlight').dataset.messageId") as? String == "target")
        #expect(try await web.evaluate("document.querySelectorAll('#log .msg').length") as? Int == 2)
        #expect(try await web.evaluate("document.querySelector('#log').inert") as? Bool == false)
    }

    @Test func revealWaitsForThreadAndHighlightSurvivesStreamingUpdate() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("revealMessage", ["messageID": "target"])
        try await web.call("setThread", thread())
        try await web.waitFor("document.activeElement.dataset.messageId === 'target'")
        try await web.call("upsertMessage", ["id": "target", "role": "assistant", "provider": "claude", "page": 3,
                                             "text": "A refreshed entropy explanation.", "status": "done"])
        try await web.waitFor("document.querySelector('.search-highlight .body').textContent.includes('refreshed')")
        try await web.call("revealMessage", ["messageID": "intro"])
        try await web.waitFor("document.activeElement.dataset.messageId === 'intro'")
        #expect(try await web.evaluate("document.querySelectorAll('.search-highlight').length") as? Int == 1)
    }

    @Test func narrowSearchFitsAndKeepsKeyboardWithinDialog() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        web.webView.frame.size = NSSize(width: 420, height: 700)
        try await web.load()
        try await web.call("openSearch", NSNull())
        try await query("entropy", in: web)
        let request = try await web.waitForMessage(type: "searchChats")
        try await web.call("setSearchResults", response(request, results: [result(), result(id: "second")]))
        #expect(try await web.evaluate("document.documentElement.scrollWidth <= window.innerWidth") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('#search-dialog').getBoundingClientRect().right <= window.innerWidth") as? Bool == true)
        #expect(try await web.evaluate("document.querySelector('#search-results').scrollWidth <= document.querySelector('#search-results').clientWidth") as? Bool == true)
        _ = try await web.evaluate("document.querySelector('.search-result:last-child').focus(); document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true})); null;")
        #expect(try await web.evaluate("document.activeElement.id") as? String == "search-close")
        web.clearMessages()
        _ = try await web.evaluate("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true,cancelable:true})); null;")
        try await Task.sleep(for: .milliseconds(50))
        #expect(web.messages.allSatisfy { $0["type"] as? String != "turn" })

        if ProcessInfo.processInfo.environment["COLEARNER_TEST_SNAPSHOTS"] != nil {
            try await web.snapshot(to: URL(fileURLWithPath: "/tmp/colearner-v017-search.png"))
        }
    }
}
