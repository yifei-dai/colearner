import AppKit
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

    private func thread(quote: Any = NSNull(), messages: [[String: Any]]? = nil) -> [String: Any] {
        ["hasDeck": true, "deckTitle": "Kinematics", "deckPath": "/tmp/reply-deck.pdf", "page": 5, "pageCount": 30,
         "provider": "claude", "pages": [5], "history": [], "conversation": ["id": "reply-chat"],
         "area": NSNull(), "messages": messages ?? self.messages, "images": [], "quote": quote]
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

    /// Clicks Reply and returns the quote it sends.
    private func reply(_ web: ChatWebFixture) async throws -> String? {
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#reply-btn').click(); null;")
        return try await web.waitForMessage(type: "quoteReply")["text"] as? String
    }

    /// The page in a borderless window that is never shown, so mouse events reach WebKit the way AppKit hands them over
    /// and a triple-click selects what a real one does.
    private func windowed(_ web: ChatWebFixture) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 520, height: 820), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        web.webView.frame = NSRect(x: 0, y: 0, width: 520, height: 820)
        window.contentView = web.webView
        return window
    }

    /// Readies the page for a gesture (no selection or Reply, mouse-ups counted), scrolls `show` into view and returns the
    /// page points that `points` computes. In it, `at(selector, word)` is the box of the first letter of `word` in
    /// `selector` (outside formulas), `box(selector)` an element's box and `mid(box)` its vertical middle.
    private func points(_ points: String, show: String, _ web: ChatWebFixture) async throws -> [Double] {
        try #require(try await web.evaluate("""
        (function () {
          getSelection().removeAllRanges();
          document.querySelector('#reply-btn').hidden = true;
          if (!window.countingMouseUps) { window.countingMouseUps = true; document.addEventListener('mouseup', () => { window.mouseUps++; }); }
          window.mouseUps = 0;
          document.querySelector(\(json(show))).scrollIntoView({ block: 'center' });
          const box = (s) => document.querySelector(s).getBoundingClientRect(), mid = (b) => (b.top + b.bottom) / 2;
          const at = (s, word) => {
            const w = document.createTreeWalker(document.querySelector(s), NodeFilter.SHOW_TEXT);
            let t;
            while ((t = w.nextNode()) && (t.nodeValue.indexOf(word) < 0 || t.parentElement.closest('.katex')));
            const i = t.nodeValue.indexOf(word), r = document.createRange();
            r.setStart(t, i); r.setEnd(t, i + 1);
            return r.getBoundingClientRect();
          };
          return \(points);
        })()
        """) as? [Double])
    }

    /// A mouse event at a page point, handed to the web view the way AppKit does.
    private func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, clicks: Int = 1, _ web: ChatWebFixture,
                       _ window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: Double(web.webView.bounds.height) - y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
        switch type {
        case .leftMouseDown: web.webView.mouseDown(with: event)
        case .leftMouseDragged: web.webView.mouseDragged(with: event)
        default: web.webView.mouseUp(with: event)
        }
    }

    /// Triple-clicks the first letter of `word` in `selector` (outside formulas), then waits for the page to handle it.
    private func tripleClick(_ word: String, in selector: String, _ web: ChatWebFixture, _ window: NSWindow) async throws {
        try await tripleClick(at: "(b => [b.left + b.width / 2, mid(b)])(at(\(json(selector)), \(json(word))))", show: selector, web, window)
    }

    /// Triple-clicks the point `point` computes (see points()), then waits for the page to handle it.
    private func tripleClick(at point: String, show: String, _ web: ChatWebFixture, _ window: NSWindow) async throws {
        let at = try await points(point, show: show, web)
        for clicks in 1...3 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                try mouse(type, at[0], at[1], clicks: clicks, web, window)
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        try await web.waitFor("window.mouseUps === 3")
        try await Task.sleep(for: .milliseconds(100))   // the page reads the selection after the mouseup
    }

    /// Presses at the first point of `points` ([x0, y0, x1, y1], see points()), drags to the second in small steps and
    /// lets go there, then waits for the page to handle it.
    private func drag(_ points: String, show: String, _ web: ChatWebFixture, _ window: NSWindow) async throws {
        let p = try await self.points(points, show: show, web)
        try mouse(.leftMouseDown, p[0], p[1], web, window)
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(20))
            let f = Double(step) / 10
            try mouse(.leftMouseDragged, p[0] + (p[2] - p[0]) * f, p[1] + (p[3] - p[1]) * f, web, window)
        }
        try await Task.sleep(for: .milliseconds(20))
        try mouse(.leftMouseUp, p[2], p[3], web, window)
        try await web.waitFor("window.mouseUps === 1")
        try await Task.sleep(for: .milliseconds(100))
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

    @Test func aSelectionQuotesOnlyWhatItCovers() async throws {
        let web = ChatWebFixture()
        defer { web.close() }
        try await web.load()
        let loose = "Three steps:\n\n1. Write the rotation as $R = R_z(\\theta)$.\n\n2. Multiply on the right for the current frame.\n\n"
            + "3. Check that $\\det R = 1$.\n\nDone."
        try await web.call("setThread", thread(messages: [messages[0], messages[1],
            ["id": "a5", "role": "assistant", "provider": "claude", "text": loose, "status": "done", "page": 5]]))
        try await web.waitFor("document.querySelectorAll('.msg').length === 3 && !!document.querySelector('[data-message-id=a5] li .katex')")
        // `setup` sets the ends of r, as WebKit leaves them after a triple-click or a drag that overshoots.
        func quote(_ setup: String) async throws -> String? {
            _ = try await web.evaluate("""
            (function () {
              const a1 = document.querySelector('[data-message-id=a1] .body'), a5 = document.querySelector('[data-message-id=a5] .body');
              const text = (e, word) => { const w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT); let t;
                while ((t = w.nextNode()) && (t.nodeValue.indexOf(word) < 0 || t.parentElement.closest('.katex'))); return t; };
              const r = document.createRange();
              \(setup)
              const s = getSelection(); s.removeAllRanges(); s.addRange(r);
              document.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, button: 0 }));
              return null;
            })()
            """)
            try await Task.sleep(for: .milliseconds(60))
            guard try await buttonShown(web) else { return nil }
            return try await reply(web)
        }
        // Ending at the very start of the next item or of a display formula's MathML: nothing of it.
        #expect(try await quote("r.setStart(text(a1, 'columns'), 0); r.setEnd(a1.querySelectorAll('li')[1], 0);")
                == "- columns are orthonormal")
        #expect(try await quote("r.setStart(text(a1, 'So'), 0); r.setEnd(a1.querySelector('.katex-display .katex-mathml mi'), 0);")
                == "So")
        // A drag that stops by a formula ends where the formula as shown starts (its first strut, or its first letter).
        #expect(try await quote("r.setStart(text(a1, 'So'), 0); r.setEnd(a1.querySelector('.katex-display .strut'), 0);") == "So")
        #expect(try await quote("r.setStart(text(a1, 'columns'), 0); r.setEnd(a1.querySelectorAll('li')[1].querySelector('.mop').firstChild, 0);")
                == "- columns are orthonormal")
        // From the end of a line to there: nothing highlighted, so no Reply.
        #expect(try await quote("r.setStart(text(a1, 'So'), 2); r.setEnd(a1.querySelector('.katex-display .strut'), 0);") == nil)
        // Starting at the very end of an item: not its marker.
        #expect(try await quote("r.setStart(text(a1, 'columns'), 'columns are orthonormal'.length); r.setEnd(a1.querySelectorAll('li')[1], 1);")
                == "- $\\det R = 1$")
        // Ending on the answer's Copy row: up to the end of the answer, without "Copy".
        #expect(try await quote("r.setStart(text(a1, 'See'), 0); r.setEnd(document.querySelector('[data-message-id=a1] .tools button').firstChild, 4);")
                == "See slide 12.")
        #expect(try await quote("r.setStart(text(a1, 'The'), 0); r.setEnd(document.querySelector('[data-message-id=a1] .tools button'), 0);")
                == "The takeaway: $R^\\top R = I$ for any rotation.\nSo\n$$R^{-1} = R^\\top$$\n- columns are orthonormal\n- $\\det R = 1$\nSee slide 12.")
        // A loose list (each item a paragraph): the marker stays on the item's line.
        #expect(try await quote("r.setStart(text(a5, 'Write'), 0); r.setEnd(text(a5, 'Check').parentElement.lastChild, 1);")
                == "1. Write the rotation as $R = R_z(\\theta)$.\n2. Multiply on the right for the current frame.\n3. Check that $\\det R = 1$.")
        #expect(try await quote("r.setStart(text(a5, 'Three'), 0); r.setEnd(text(a5, 'Done'), 5);")
                == "Three steps:\n1. Write the rotation as $R = R_z(\\theta)$.\n2. Multiply on the right for the current frame.\n"
                + "3. Check that $\\det R = 1$.\nDone.")
        #expect(web.javaScriptErrors.isEmpty)
    }

    // MARK: real triple-clicks

    @Test func aTripleClickOnAnAnswersLastParagraphOffersReplyWithoutTheCopyRow() async throws {
        let web = ChatWebFixture()
        let window = windowed(web)
        defer { web.close(); window.contentView = nil; window.close() }
        try await web.load()
        let one = "Rotations compose by multiplying their matrices."
        try await web.call("setThread", thread(messages: [messages[0], messages[1],
            ["id": "a4", "role": "assistant", "provider": "codex", "text": one, "status": "done", "page": 5]]))
        try await web.waitFor("document.querySelectorAll('.msg').length === 3 && !!document.querySelector('.katex-display')")
        // WebKit ends both selections on the answer's own Copy button.
        for (word, selector, quote) in [("See", ".msg[data-message-id=a1] .body > p:last-child", "See slide 12."),
                                        ("Rotations", ".msg[data-message-id=a4] .body", one)] {
            try await tripleClick(word, in: selector, web, window)
            #expect(try await buttonShown(web), "no Reply after a triple-click on “\(word)”")
            #expect(try await web.evaluate("String(getSelection()).includes('Copy')") as? Bool == false)
            #expect(try await reply(web) == quote)
        }
        #expect(web.javaScriptErrors.isEmpty)
    }

    @Test func aTripleClickRepliesWithThatParagraph() async throws {
        let web = ChatWebFixture()
        let window = windowed(web)
        defer { web.close(); window.contentView = nil; window.close() }
        try await web.load()
        try await web.call("setThread", thread())
        try await web.waitFor("document.querySelectorAll('.msg').length === 4 && !!document.querySelector('.katex-display')")
        let a1 = ".msg[data-message-id=a1] .body"
        let takeaway = "The takeaway: $R^\\top R = I$ for any rotation."
        // A list item without the next item's marker; the line before a display formula without the formula; a paragraph
        // with inline math, clicked before or after the formula, all of it (WebKit alone stops at the formula's MathML).
        for (word, selector, quote) in [("columns", "\(a1) li", "- columns are orthonormal"),
                                        ("So", "\(a1) > p:nth-of-type(2)", "So"),
                                        ("The", "\(a1) > p", takeaway),
                                        ("rotation", "\(a1) > p", takeaway)] {
            try await tripleClick(word, in: selector, web, window)
            #expect(try await buttonShown(web), "no Reply after a triple-click on “\(word)”")
            if quote == takeaway {   // the highlight shows the whole paragraph too
                #expect(try await web.evaluate("(s => s.startsWith('The takeaway') && s.includes('for any rotation.'))(String(getSelection()))") as? Bool == true)
            }
            #expect(try await reply(web) == quote, "triple-click on “\(word)”")
        }
        #expect(web.javaScriptErrors.isEmpty)
    }

    @Test func aTripleClickTakesOnlyTheLineWebKitSelects() async throws {
        let web = ChatWebFixture()
        let window = windowed(web)
        defer { web.close(); window.contentView = nil; window.close() }
        try await web.load()
        // Nested lists as answers write them, a tight item with a display formula under it, lines with hard breaks (also
        // in bold), a display formula inside a paragraph.
        let answers = [("aN", "Here is how the pieces fit:\n\n- **Rotation matrices** are orthogonal:\n  - their columns are orthonormal\n"
                              + "  - their determinant is $+1$\n- **Homogeneous transforms** add a translation\n\nThat's the core idea."),
                       ("aO", "1. Step one\n   - detail a\n   - detail b\n2. Step two"),
                       ("aD", "- The rotation:\n  $$R = I$$\n- next item"),
                       ("aB", "Line one has $x$ in it  \nLine two has $y$ too  \nLine three\n\nPlain one  \nPlain two  \nPlain three\n\n"
                              + "**Bold one $c$  \nbold two** tail."),
                       ("aI", "Before the formula $$x^2$$ after it.")]
        try await web.call("setThread", thread(messages: [messages[0]] + answers.map { (id, text) in
            ["id": id, "role": "assistant", "provider": "claude", "text": text, "status": "done", "page": 5] as [String: Any] }))
        try await web.waitFor("document.querySelectorAll('.msg').length === 6 && !!document.querySelector('[data-message-id=aI] .katex-display')")
        try await Task.sleep(for: .milliseconds(150))   // the conversation settles at its end first, or it would follow it there again
        // A parent item without its sub-items, an item without the formula under it, one line of a paragraph; also where
        // a formula in the line stopped WebKit early (it ends at "$y$" for "two", starts there for "too").
        for (word, selector, quote, notShown) in [
            ("are orthogonal", "[data-message-id=aN] .body > ul > li", "Rotation matrices are orthogonal:", "their"),
            ("columns", "[data-message-id=aN] li li", "- their columns are orthonormal", "determinant"),
            ("Step", "[data-message-id=aO] li", "Step one", "detail"),
            ("rotation", "[data-message-id=aD] li", "The rotation:", "="),
            ("two", "[data-message-id=aB] p", "Line two has $y$ too", "Line one|Line three"),
            ("too", "[data-message-id=aB] p", "Line two has $y$ too", "Line one|Line three"),
            ("three", "[data-message-id=aB] p", "Line three", "Line two|Plain"),
            ("Plain two", "[data-message-id=aB] p:nth-of-type(2)", "Plain two", "Plain one|Plain three"),
            ("one", "[data-message-id=aB] p:last-child", "Bold one $c$", "bold two"),
        ] {
            try await tripleClick(word, in: ".msg\(selector)", web, window)
            #expect(try await buttonShown(web), "no Reply after a triple-click on “\(word)”")
            // the highlight shows the same
            #expect(try await web.evaluate("new RegExp(\(json(notShown))).test(String(getSelection()))") as? Bool == false,
                    "triple-click on “\(word)” highlights more")
            #expect(try await reply(web) == quote, "triple-click on “\(word)”")
        }
        // A display formula inside a paragraph is a line of its own.
        try await tripleClick(at: "(b => [b.left + b.width / 2, mid(b)])(box('.msg[data-message-id=aI] .katex-display .katex-html'))",
                              show: ".msg[data-message-id=aI] .katex-display", web, window)
        #expect(try await web.evaluate("/Before|after/.test(String(getSelection()))") as? Bool == false)
        #expect(try await reply(web) == "$$x^2$$")
        #expect(web.javaScriptErrors.isEmpty)
    }

    @Test func aDragThatStopsByAFormulaQuotesOnlyWhatItHighlights() async throws {
        let web = ChatWebFixture()
        let window = windowed(web)
        defer { web.close(); window.contentView = nil; window.close() }
        try await web.load()
        let facts = "Facts:\n\n- $R^\\top R = I$ always holds\n- $\\det R = 1$ for proper rotations\n\nDone."
        try await web.call("setThread", thread(messages: [messages[0], messages[1],
            ["id": "aF", "role": "assistant", "provider": "claude", "text": facts, "status": "done", "page": 5]]))
        try await web.waitFor("document.querySelectorAll('.msg').length === 3 && !!document.querySelector('.katex-display')")
        try await Task.sleep(for: .milliseconds(150))   // the conversation settles at its end first, or it would follow it there again
        let a1 = ".msg[data-message-id=a1] .body", so = "\(a1) > p:nth-of-type(2)", item2 = "\(a1) li:nth-child(2)"
        // WebKit ends these where the formula as shown starts: nothing of it (or of the next item) is highlighted.
        // From "So" down to the display formula's line, left of the centered formula:
        try await drag("(s => [s.left + 1, mid(s), box('\(a1)').left + 10, mid(box('\(a1) .katex-display .katex-html'))])(at('\(so)', 'So'))",
                       show: "\(a1) .katex-display", web, window)
        #expect(try await buttonShown(web))
        // Reply stands under "So", not by the formula's hidden MathML further down.
        #expect(try await web.evaluate("""
            (() => { const t = document.createRange(); t.selectNodeContents(document.querySelector('\(so)'));
                     return Math.abs(document.querySelector('#reply-btn').getBoundingClientRect().top - t.getBoundingClientRect().bottom - 6) <= 1; })()
            """) as? Bool == true)
        #expect(try await reply(web) == "So")
        // From the first item to the second one's bullet:
        try await drag("(c => [c.left + 1, mid(c), box('\(item2)').left - 8, mid(box('\(item2)'))])(at('\(a1) li', 'columns'))",
                       show: item2, web, window)
        #expect(try await reply(web) == "- columns are orthonormal")
        // From the end of "Facts:" to the first item's bullet: something is selected (the formula's hidden MathML), but
        // nothing shows, so no Reply.
        let f = ".msg[data-message-id=aF] .body"
        try await drag("(c => [c.right + 1, mid(c), box('\(f) li').left - 8, mid(box('\(f) li'))])(at('\(f) > p', ':'))",
                       show: f, web, window)
        #expect(try await web.evaluate("String(getSelection()).trim().length > 0") as? Bool == true)
        #expect(try await !buttonShown(web))
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
        // Asked in another chat (New chat or History since the Reply): the answer is not in this conversation.
        #expect(DeckContext.excerpt(q, for: .claude, otherChat: true) == "The student selected this part of your answer in an earlier "
                + "chat about this deck (not part of this conversation):\n"
                + "<answer_excerpt from=\"Claude’s answer\" where=\"slide 5\">\nR^{-1} = R^T\n</answer_excerpt>\n")
        #expect(DeckContext.excerpt(q, for: .codex, otherChat: true).hasPrefix("The student selected this part of Claude’s answer in an "
                + "earlier chat about this deck (not part of this conversation):\n"))
        // Old quote kinds read as before.
        let walk = ChatQuote(source: "Walkthrough", section: nil, text: "t", kind: "selection")
        #expect(DeckContext.excerpt(walk, for: .claude) == DeckContext.excerpt(walk))
        #expect(DeckContext.excerpt(walk, for: .claude, otherChat: true) == DeckContext.excerpt(walk))
    }
}
