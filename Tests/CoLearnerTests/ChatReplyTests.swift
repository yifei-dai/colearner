import Foundation
import Testing
@testable import CoLearner

/// "Reply" on part of an answer: the button and the text it takes from the shipped chat page (real KaTeX), and the
/// quote and prompt the app makes of it.
@Suite(.serialized)
@MainActor
struct ChatReplyTests {
    private let answer = "The takeaway: $R^\\top R = I$ for any rotation.\n\nSo\n\n$$\nR^{-1} = R^\\top\n$$\n\n"
        + "- columns are orthonormal\n- $\\det R = 1$\n\nSee slide 12."

    private var messages: [[String: Any]] {
        [["id": "q1", "role": "user", "text": "Why is the inverse the transpose?", "status": "done", "page": 5],
         ["id": "a1", "role": "assistant", "provider": "claude", "text": answer, "status": "done", "page": 5],
         ["id": "a2", "role": "assistant", "provider": "codex", "text": "A second answer about $x$.", "status": "done", "page": 5],
         ["id": "a3", "role": "assistant", "provider": "codex", "text": "Still writing this", "status": "streaming", "page": 5]]
    }

    private func thread(quote: Any = NSNull()) -> [String: Any] {
        ["hasDeck": true, "deckTitle": "Kinematics", "deckPath": "/tmp/reply-deck.pdf", "page": 5, "pageCount": 30,
         "provider": "claude", "pages": [5], "history": [], "conversation": ["id": "reply-chat"],
         "area": NSNull(), "messages": messages, "images": [], "quote": quote]
    }

    private func page() async throws -> ChatWebFixture {
        let web = ChatWebFixture()
        try await web.load()
        try await web.call("setThread", thread())
        try await web.waitFor("document.querySelectorAll('.msg').length === 4 && !!document.querySelector('.katex-display')")
        return web
    }

    /// Selects from the first text in `from` to the end of the last text in `to` (CSS selectors), then lets go.
    private func select(_ from: String, _ to: String, in web: ChatWebFixture) async throws {
        _ = try await web.evaluate("""
        (function () {
          const texts = (n) => { const w = document.createTreeWalker(n, NodeFilter.SHOW_TEXT), out = []; let t;
                                 while ((t = w.nextNode())) if (t.nodeValue.trim()) out.push(t); return out; };
          const a = texts(document.querySelector(\(json(from))))[0], b = texts(document.querySelector(\(json(to)))).pop();
          const r = document.createRange();
          r.setStart(a, 0); r.setEnd(b, b.length);
          const s = getSelection(); s.removeAllRanges(); s.addRange(r);
          document.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, button: 0 }));
          return null;
        })()
        """)
        try await Task.sleep(for: .milliseconds(60))
    }

    private func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func buttonShown(_ web: ChatWebFixture) async throws -> Bool {
        try await web.evaluate("!document.querySelector('#reply-btn').hidden") as? Bool == true
    }

    @Test func replyQuotesThePartOfAnAnswerWithItsTeX() async throws {
        let web = try await page()
        defer { web.close() }
        try await select(".msg[data-message-id=a1] .body p", ".msg[data-message-id=a1] .body li:last-child", in: web)
        #expect(try await buttonShown(web))
        // Next to the selection, inside the conversation.
        let placed = try await web.evaluate("""
        (function () { const b = document.querySelector('#reply-btn').getBoundingClientRect(),
                              l = document.querySelector('#log').getBoundingClientRect();
          return b.width > 20 && b.left >= l.left && b.right <= l.right && b.top >= l.top && b.bottom <= l.bottom; })()
        """) as? Bool
        #expect(placed == true)
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#reply-btn').click(); null;")
        let sent = try await web.waitForMessage(type: "quoteReply")
        #expect(sent["messageID"] as? String == "a1")
        let text = try #require(sent["text"] as? String)
        #expect(text == "The takeaway: $R^\\top R = I$ for any rotation.\nSo\n$$R^{-1} = R^\\top$$\n- columns are orthonormal\n- $\\det R = 1$")
        #expect(try await web.evaluate("getSelection().rangeCount === 0 || getSelection().isCollapsed") as? Bool == true)
        #expect(try await !buttonShown(web))
        #expect(try await web.evaluate("document.activeElement === document.querySelector('#input')") as? Bool == true)
        #expect(web.javaScriptErrors.isEmpty)
    }

    @Test func aSelectionInsideOneFormulaTakesAllOfIt() async throws {
        let web = try await page()
        defer { web.close() }
        try await select(".msg[data-message-id=a1] .katex-display .katex-html", ".msg[data-message-id=a1] .katex-display .katex-html", in: web)
        #expect(try await buttonShown(web))
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#reply-btn').click(); null;")
        #expect(try await web.waitForMessage(type: "quoteReply")["text"] as? String == "$$R^{-1} = R^\\top$$")
    }

    @Test func noReplyOutsideOneFinishedAnswer() async throws {
        let web = try await page()
        defer { web.close() }
        // Across two answers, in the question, in an answer still being written.
        for (from, to) in [(".msg[data-message-id=a1] .body p", ".msg[data-message-id=a2] .body p"),
                           (".msg[data-message-id=q1] .bubble", ".msg[data-message-id=q1] .bubble"),
                           (".msg[data-message-id=a3] .body", ".msg[data-message-id=a3] .body")] {
            try await select(from, to, in: web)
            #expect(try await !buttonShown(web), "Reply offered for \(from) … \(to)")
        }
        // Esc and a collapsed selection put it away.
        try await select(".msg[data-message-id=a2] .body p", ".msg[data-message-id=a2] .body p", in: web)
        #expect(try await buttonShown(web))
        _ = try await web.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); null;")
        #expect(try await !buttonShown(web))
        try await select(".msg[data-message-id=a2] .body p", ".msg[data-message-id=a2] .body p", in: web)
        #expect(try await buttonShown(web))
        // A click elsewhere: the press puts it away, and the empty selection left on release doesn't bring it back.
        _ = try await web.evaluate("""
        document.querySelector('#log').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 }));
        getSelection().collapseToStart();
        document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, button: 0 })); null;
        """)
        try await Task.sleep(for: .milliseconds(60))
        #expect(try await !buttonShown(web))
        // A redrawn conversation (another chat, another deck) takes the selection and the button with it.
        try await select(".msg[data-message-id=a2] .body p", ".msg[data-message-id=a2] .body p", in: web)
        #expect(try await buttonShown(web))
        try await web.call("setThread", thread().merging(["conversation": ["id": "other-chat"]]) { $1 })
        try await web.waitFor("document.querySelector('#reply-btn').hidden")
        #expect(web.javaScriptErrors.isEmpty)
    }

    @Test func aQuotedPartOfAnAnswerChangesTheButtonsAndStatusLine() async throws {
        let web = try await page()
        defer { web.close() }
        let quote: [String: Any] = ["id": "r1", "source": "Claude’s answer", "section": "slide 5",
                                    "text": "R^{-1} = R^T because the columns are orthonormal.", "kind": "reply"]
        try await web.call("setAttachments", ["images": [], "quote": quote])
        #expect(try await web.evaluate("document.querySelector('.chip[data-action=explain]').textContent") as? String == "Explain this part")
        #expect(try await web.evaluate("document.querySelector('.chip[data-action=visualize]').textContent") as? String == "Visualize this part")
        #expect(try await web.evaluate("document.querySelector('#attach').textContent") as? String
                == "Slide 5 and the quoted part of the answer go with your question")
        #expect(try await web.evaluate("document.querySelector('#input').placeholder") as? String
                == "Ask about the quoted part…  (Enter to send, Shift+Enter for a new line)")
        #expect(try await web.evaluate("document.querySelector('.att-q-from').textContent") as? String == "From Claude’s answer › slide 5")
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('.chip[data-action=explain]').click(); null;")
        let sent = try await web.waitForMessage(type: "send")
        #expect(sent["quoteID"] as? String == "r1")
        #expect((sent["text"] as? String)?.hasPrefix("Explain the part of the answer I quoted in more depth.") == true)
    }

    // MARK: the app side

    @Test func theQuoteNamesWhoseAnswerAndItsSlide() {
        let answer = ChatMessage(role: .assistant, provider: .claude, text: "full answer", page: 5)
        let q = ChatController.replyQuote(text: "  part of it \n", to: answer)
        #expect(q?.source == "Claude’s answer" && q?.section == "slide 5" && q?.text == "part of it")
        #expect(q?.kind == "reply" && q?.provider == .claude)
        let codex = ChatMessage(role: .assistant, provider: .codex, text: "answer", page: nil)
        #expect(ChatController.replyQuote(text: "x", to: codex)?.source == "ChatGPT’s answer")
        #expect(ChatController.replyQuote(text: "x", to: codex)?.section == nil)
        #expect(ChatController.replyQuote(text: String(repeating: "y", count: 9_000), to: answer)?.text.count == ChatQuote.maxText)
        #expect(ChatController.replyQuote(text: "x", to: ChatMessage(role: .user, text: "question")) == nil)
        #expect(ChatController.replyQuote(text: "x", to: ChatMessage(role: .assistant, provider: .claude, text: "", status: .streaming)) == nil)
        #expect(ChatController.replyQuote(text: " \n ", to: answer) == nil)
    }

    @Test func theExcerptSaysWhoseEarlierAnswerItIs() {
        let q = ChatQuote(source: "Claude’s answer", section: "slide 5", text: "R^{-1} = R^T", kind: "reply", provider: .claude)
        #expect(DeckContext.excerpt(q, for: .claude) == "The student selected this part of your earlier answer in this chat:\n"
                + "<answer_excerpt from=\"Claude’s answer\" where=\"slide 5\">\nR^{-1} = R^T\n</answer_excerpt>\n")
        #expect(DeckContext.excerpt(q, for: .codex).hasPrefix("The student selected this part of Claude’s earlier answer in this chat:\n"))
        #expect(DeckContext.excerpt(q).hasPrefix("The student selected this part of Claude’s earlier answer in this chat:\n"))
        // Old quote kinds read as before.
        let walk = ChatQuote(source: "Walkthrough", section: nil, text: "t", kind: "selection")
        #expect(DeckContext.excerpt(walk, for: .claude) == DeckContext.excerpt(walk))
    }
}
