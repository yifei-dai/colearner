import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct SlideLinkTests {
    private func thread(_ text: String, pageCount: Int = 30, role: String = "assistant", status: String = "done") -> [String: Any] {
        ["hasDeck": true, "deckTitle": "Reference test", "deckPath": "/tmp/reference-test.pdf",
         "page": 1, "pageCount": pageCount, "provider": "claude", "pages": [1], "history": [],
         "conversation": ["id": "reference-chat"], "area": NSNull(),
         "messages": [["id": "answer", "role": role, "provider": "claude", "page": 1, "text": text, "status": status]]]
    }

    private func links(_ web: ChatWebFixture) async throws -> [Int] {
        try await web.evaluate("Array.from(document.querySelectorAll('#log button.slide-ref'), b => Number(b.dataset.slide))") as? [Int] ?? []
    }

    @Test func plainBoldListsAndRangesBecomeBoundedSlideButtons() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        let prose = "See slide 12, slide **13**, and slides 3 and 5. Compare slides 7–9, 11 through 14, and 16 to 18. Slide #20 helps."
        try await web.call("setThread", thread(prose))
        #expect(try await links(web) == [12, 13, 3, 5, 7, 9, 11, 14, 16, 18, 20])
        #expect(try await web.evaluate("document.querySelector('#log .body').textContent.trim()") as? String == prose.replacingOccurrences(of: "**", with: ""))
        #expect(try await web.evaluate("!!document.querySelector('strong > button.slide-ref[data-slide=\"13\"]')") as? Bool == true)
        #expect(try await web.evaluate("Array.from(document.querySelectorAll('button.slide-ref')).every(b => b.type === 'button' && b.getAttribute('aria-label') === 'Go to slide ' + b.dataset.slide)") as? Bool == true)
    }

    @Test func clickingReferencePostsItsDeckAndConversation() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setThread", thread("Compare slide 12 with slide 3."))
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('button.slide-ref[data-slide=\"12\"]').click(); null;")
        let message = try await web.waitForMessage(type: "gotoSlide")
        #expect(message["page"] as? Int == 12)
        #expect(message["deckPath"] as? String == "/tmp/reference-test.pdf")
        #expect(message["conversationID"] as? String == "reference-chat")
        #expect(try await web.evaluate("document.querySelector('#viewseg button.on').dataset.v") as? String == "all")
        var navigated = thread("Compare slide 12 with slide 3.")
        navigated["page"] = 12
        try await web.call("setThread", navigated)
        #expect(try await links(web) == [12, 3])
        #expect(try await web.evaluate("document.querySelector('#log .body').textContent.trim()") as? String == "Compare slide 12 with slide 3.")
    }

    @Test func codeMathExistingLinksVisualsAndUserMessagesStayUnlinked() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        let prose = """
        `slide 4` and [slide 5](https://example.com) are excluded.

        Do not combine the prefix with protected markup: slide `12`, slide $13$, slide [14](https://example.com).

        $\\text{slide 6}$

        ```text
        slide 7
        ```

        ```html
        <p>slide 8</p>
        ```

        Outside: slide 9.
        """
        try await web.call("setThread", thread(prose))
        #expect(try await links(web) == [9])
        #expect(try await web.evaluate("!!document.querySelector('#log iframe')") as? Bool == true)
        try await web.call("setThread", thread("Please compare slide 12 and slide 13.", role: "user"))
        #expect(try await links(web).isEmpty)
    }

    @Test func invalidAndExplicitForeignReferencesStayPlainText() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        let prose = """
        Slide 0, slide 31, slide 4.5, slide 1,000, and slide 6a are invalid. Standalone numbers 2 and 3 are not references.

        Slides 7–4 and slides 2–999 are not valid ranges.

        Lecture 2 slides 8 and 9. Other deck slide 10. Slide 11 from lecture 3.

        For this deck, slide 12 and slides 15, 17 and 19 apply.
        """
        try await web.call("setThread", thread(prose))
        #expect(try await links(web) == [12, 15, 17, 19])
    }

    @Test func repeatedDecorationAndStreamUpdatesDoNotDuplicateButtons() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setThread", thread("See slide 12.", status: "streaming"))
        _ = try await web.evaluate("CLSlideLinks.decorate(document.querySelector('#log .body'), {pageCount:30,deckPath:'/tmp/reference-test.pdf',conversationID:'reference-chat'}); null;")
        #expect(try await links(web) == [12])
        try await web.call("upsertMessage", ["id": "answer", "role": "assistant", "provider": "claude", "page": 1,
                                           "status": "done", "text": "See slide 12 and slide 13."])
        try await web.waitFor("document.querySelectorAll('#log button.slide-ref').length === 2")
        #expect(try await links(web) == [12, 13])
    }

    @Test func slideReferencesFitNarrowChatPanels() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        web.webView.frame.size.width = 420
        try await web.load()
        try await web.call("setThread", thread("Compare slide **12** with slides 3, 5, 7–9 and 11 through 14. These references should wrap naturally within the explanation when the chat panel is narrow."))
        #expect(try await links(web) == [12, 3, 5, 7, 9, 11, 14])
        #expect(try await web.evaluate("Array.from(document.querySelectorAll('#log, #log .body')).every(e => e.scrollWidth <= e.clientWidth + 1)") as? Bool == true)
        if ProcessInfo.processInfo.environment["COLEARNER_TEST_SNAPSHOTS"] != nil {
            try await web.snapshot(to: URL(fileURLWithPath: "/tmp/colearner-v017-citations.png"))
        }
    }
}
