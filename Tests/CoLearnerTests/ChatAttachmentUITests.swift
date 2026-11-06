import AppKit
import Foundation
import Testing
import WebKit
@testable import CoLearner

/// Screenshots and walkthrough quotes in the shipped chat page: the composer, its header, quick buttons, paste,
/// drop and the question bubbles. The app side is played by the test (setThread / setAttachments and the posts).
@Suite(.serialized)
@MainActor
struct ChatAttachmentUITests {
    private static let visRules =
        "Make ONE self-contained interactive visual as a single ```html code block (inline SVG or canvas + vanilla JS, " +
        "sliders or buttons where they help, no external files). After the block, say in 2-3 sentences what to look at and what to try."
    private static let hint = "…  (Enter to send, Shift+Enter for a new line)"

    /// A small PNG data URL, like the JPEG previews the app makes.
    private func picture(width: Int = 160, height: Int = 90, hue: CGFloat = 0.6) -> String {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.25, brightness: 0.97, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 10, y: 10, width: width / 2, height: height / 3))
        ctx.fill(CGRect(x: 10, y: height * 2 / 3 - 4, width: width - 20, height: 6))
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func image(_ id: String, _ label: String, hue: CGFloat = 0.6) -> [String: Any] {
        ["id": id, "label": label, "thumb": picture(hue: hue)]
    }

    private let walkthroughQuote: [String: Any] = [
        "id": "quote-1", "source": "Lecture 3 Walkthrough", "section": "Topic 2 › Rotation matrices",
        "text": "A rotation matrix R has orthonormal columns, so its inverse is its transpose: R⁻¹ = Rᵀ.", "kind": "selection"]
    private let notesQuote: [String: Any] = [
        "id": "quote-2", "source": "L03_notes", "text": "The Jacobian maps joint velocities to the end-effector twist.",
        "kind": "notes"]

    private func thread(images: [[String: Any]] = [], quote: Any = NSNull(), area: Any = NSNull(),
                        messages: [[String: Any]] = [], hasDeck: Bool = true) -> [String: Any] {
        ["hasDeck": hasDeck, "deckTitle": "Kinematics", "deckPath": "/tmp/attachment-deck.pdf", "page": 4, "pageCount": 30,
         "provider": "claude", "pages": [4], "history": [], "conversation": ["id": "attachment-chat"],
         "area": area, "messages": messages, "images": images, "quote": quote]
    }

    private func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func text(_ selector: String, in web: ChatWebFixture) async throws -> String? {
        try await web.evaluate("(document.querySelector(\(json(selector))) || {}).textContent ?? null") as? String
    }

    private func flag(_ script: String, in web: ChatWebFixture) async throws -> Bool {
        try await web.evaluate(script) as? Bool == true
    }

    private func posts(_ type: String, in web: ChatWebFixture) -> [[String: Any]] {
        web.messages.filter { $0["type"] as? String == type }
    }

    private func waitForPosts(_ type: String, count: Int, in web: ChatWebFixture) async throws -> [[String: Any]] {
        for _ in 0..<150 {
            let found = posts(type, in: web)
            if found.count >= count { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ChatWebFixture.FixtureError.timeout("\(count) × \(type)")
    }

    /// Clicks a quick button and returns what it sent.
    private func quickSend(_ action: String, in web: ChatWebFixture) async throws -> [String: Any] {
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('.chip[data-action=\(action)]').click(); null;")
        return try await web.waitForMessage(type: "send")
    }

    // MARK: composer

    @Test func chipsAndQuoteCardFollowTheAppsAttachments() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        #expect(try await flag("document.querySelector('#attachbox').hidden", in: web))

        let label = "Screenshot 2026-10-28 at 9.41.07 AM.png"
        try await web.call("setThread", thread(images: [image("a", label), image("b", "Pasted image", hue: 0.1)], quote: walkthroughQuote))
        #expect(try await flag("!document.querySelector('#attachbox').hidden", in: web))
        #expect(try await web.evaluate("Array.from(document.querySelectorAll('.att-pic .att-label'), e => e.textContent)") as? [String]
                == [label, "Pasted image"])
        #expect(try await web.evaluate("document.querySelector('.att-pic').title") as? String == label)
        #expect(try await flag("Array.from(document.querySelectorAll('.att-pic img')).every(i => i.src.startsWith('data:image/png;base64,'))", in: web))
        #expect(try await web.evaluate("document.querySelector('.att-pic img').getBoundingClientRect().height") as? Double == 46)
        #expect(try await text(".att-q-from", in: web) == "From Lecture 3 Walkthrough › Topic 2 › Rotation matrices")
        #expect(try await text(".att-q-text", in: web) == walkthroughQuote["text"] as? String)
        // The area box comes first, then the pictures and the quote, then the text box.
        #expect(try await flag("document.querySelector('#areabox').nextElementSibling.id === 'attachbox' && document.querySelector('#attachbox').nextElementSibling.id === 'inputwrap'", in: web))

        try await web.call("setAttachments", ["images": [image("b", "Pasted image")], "quote": notesQuote])
        #expect(try await web.evaluate("document.querySelectorAll('.att-pic').length") as? Int == 1)
        #expect(try await text(".att-q-from", in: web) == "From L03_notes")

        try await web.call("setAttachments", ["images": [], "quote": NSNull()])
        #expect(try await flag("document.querySelector('#attachbox').hidden && !document.querySelector('#attachbox').children.length", in: web))

        // Pictures wait for the next question whatever the deck: still shown (and removable) with no deck open.
        try await web.call("setThread", thread(images: [image("a", label)], hasDeck: false))
        #expect(try await web.evaluate("document.querySelectorAll('.att-pic').length") as? Int == 1)
        #expect(try await flag("!document.querySelector('.att-pic .att-x').disabled", in: web))
    }

    @Test func removeButtonsPostTheirIDsAndKeepTheKeyboardThere() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setThread", thread(images: [image("a", "one.png"), image("b", "Pasted image")], quote: walkthroughQuote))
        #expect(try await web.evaluate("document.querySelectorAll('.att-pic .att-x')[1].title") as? String == "Remove")
        #expect(try await web.evaluate("document.querySelectorAll('.att-pic .att-x')[1].getAttribute('aria-label')") as? String == "Remove Pasted image")
        #expect(try await web.evaluate("document.querySelector('.att-quote .att-x').title") as? String == "Remove the quoted passage")

        web.clearMessages()
        _ = try await web.evaluate("document.querySelectorAll('.att-pic .att-x')[1].click(); null;")
        let removed = try await web.waitForMessage(type: "removeImage")
        #expect(removed["id"] as? String == "b")
        #expect(removed.count == 2)
        _ = try await web.evaluate("document.querySelector('.att-quote .att-x').click(); null;")
        let cleared = try await web.waitForMessage(type: "clearQuote")
        #expect(cleared.count == 1)

        // The app answers with what is left; the focus moves to the next x, then back to the text box.
        _ = try await web.evaluate("document.querySelector('.att-pic .att-x').focus(); null;")
        try await web.call("setAttachments", ["images": [image("b", "Pasted image")], "quote": walkthroughQuote])
        #expect(try await flag("document.activeElement === document.querySelector('.att-pic .att-x')", in: web))
        try await web.call("setAttachments", ["images": [], "quote": NSNull()])
        #expect(try await web.evaluate("document.activeElement.id") as? String == "input")
    }

    @Test func attachButtonPostsChooseImagesAndStaysUsableWhileAnswering() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        #expect(try await text("#btn-attach", in: web) == "📎 Screenshot")
        #expect(try await web.evaluate("document.querySelector('#btn-attach').className") as? String == "chip ghostchip")
        #expect(try await web.evaluate("document.querySelector('#btn-attach').title") as? String
                == "Attach screenshots or other pictures (or paste one with ⌘V, or drop files on the chat)")
        #expect(try await web.evaluate("document.querySelector('#btn-area').nextElementSibling.id") as? String == "btn-attach")
        #expect(try await flag("document.querySelector('#btn-attach').disabled", in: web))

        try await web.call("setThread", thread())
        #expect(try await flag("!document.querySelector('#btn-attach').disabled", in: web))
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#btn-attach').click(); null;")
        let choose = try await web.waitForMessage(type: "chooseImages")
        #expect(choose.count == 1)

        try await web.call("upsertMessage", ["id": "answer", "role": "assistant", "provider": "claude", "page": 4, "text": "", "status": "streaming"])
        #expect(try await text("#btn-send", in: web) == "Stop")
        #expect(try await flag("!document.querySelector('#btn-attach').disabled && !document.querySelector('#btn-area').disabled", in: web))
        #expect(try await flag("document.querySelector('.chip[data-action=explain]').disabled && document.querySelector('.chip[data-action=visualize]').disabled", in: web))
    }

    // MARK: quick buttons and sending

    @Test func quickButtonsAndPlaceholderFollowPrecedence() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        let area: [String: Any] = ["page": 4, "thumb": picture()]
        let one = [image("a", "one.png")], two = [image("a", "one.png"), image("b", "two.png")]
        // (images, quote, area) → explain, visualize, placeholder (what goes with a question shows above the box and in
        // the placeholder; there is no status line for it)
        let cases: [([[String: Any]], Any, Any, String, String, String)] = [
            ([], NSNull(), NSNull(), "Explain this slide", "Visualize this slide", "this slide"),
            (one, NSNull(), NSNull(), "Explain the screenshot", "Visualize the screenshot", "the screenshot"),
            (two, NSNull(), NSNull(), "Explain the screenshots", "Visualize the screenshots", "the screenshots"),
            ([], walkthroughQuote, NSNull(), "Explain this passage", "Visualize this passage", "the passage"),
            ([], notesQuote, NSNull(), "Explain this passage", "Visualize this passage", "the passage"),
            (one, walkthroughQuote, NSNull(), "Explain this passage", "Visualize this passage", "the passage"),
            ([], NSNull(), area, "Explain this area", "Visualize this area", "the selected area"),
            (one, NSNull(), area, "Explain this area", "Visualize this area", "the selected area"),
            (two, walkthroughQuote, area, "Explain this area", "Visualize this area", "the selected area"),
        ]
        for (images, quote, selected, explain, visualize, about) in cases {
            try await web.call("setThread", thread(images: images, quote: quote, area: selected))
            #expect(try await text(".chip[data-action=explain]", in: web) == explain)
            #expect(try await text(".chip[data-action=visualize]", in: web) == visualize)
            #expect(try await web.evaluate("document.querySelector('#input').placeholder") as? String == "Ask about " + about + Self.hint)
        }

        // Prompts, in precedence order. The area's and the slide's are unchanged.
        try await web.call("setThread", thread(images: two, quote: walkthroughQuote))
        var sent = try await quickSend("explain", in: web)
        #expect(sent["display"] as? String == "Explain this passage")
        #expect(sent["text"] as? String == "Explain the passage I quoted from the walkthrough. Start with the one-sentence takeaway. "
            + "Then go through it piece by piece: define every symbol and say in words what each equation means. Connect it to the "
            + "slides where that helps, and say so if it disagrees with them.")
        sent = try await quickSend("visualize", in: web)
        #expect(sent["text"] as? String == "Visualize the idea in the passage I quoted from the walkthrough. " + Self.visRules)

        try await web.call("setAttachments", ["images": two, "quote": notesQuote])
        sent = try await quickSend("explain", in: web)
        #expect((sent["text"] as? String)?.hasPrefix("Explain the passage I quoted from the notes. Start with") == true)
        sent = try await quickSend("visualize", in: web)
        #expect(sent["text"] as? String == "Visualize the idea in the passage I quoted from the notes. " + Self.visRules)

        try await web.call("setAttachments", ["images": one, "quote": NSNull()])
        sent = try await quickSend("explain", in: web)
        #expect(sent["display"] as? String == "Explain the screenshot")
        #expect(sent["text"] as? String == "Explain the attached screenshot. Start with the one-sentence takeaway. Then go through it "
            + "piece by piece: define every symbol and say in words what each equation or figure means. Relate it to this deck's "
            + "slides where that helps.")
        sent = try await quickSend("visualize", in: web)
        #expect(sent["display"] as? String == "Visualize the screenshot")
        #expect(sent["text"] as? String == "Visualize the key idea in the attached screenshot. " + Self.visRules)

        try await web.call("setAttachments", ["images": two, "quote": NSNull()])
        sent = try await quickSend("explain", in: web)
        #expect(sent["display"] as? String == "Explain the screenshots")
        #expect(sent["text"] as? String == "Explain the attached screenshots. Start with the one-sentence takeaway. Then go through them "
            + "piece by piece: define every symbol and say in words what each equation or figure means. Relate them to this deck's "
            + "slides where that helps.")
        sent = try await quickSend("visualize", in: web)
        #expect(sent["text"] as? String == "Visualize the key idea in the attached screenshots. " + Self.visRules)

        try await web.call("setArea", area)
        sent = try await quickSend("explain", in: web)
        #expect(sent["display"] as? String == "Explain this area")
        #expect((sent["text"] as? String)?.hasPrefix("Explain the selected area of this slide (the attached crop).") == true)
        #expect(sent["useArea"] as? Bool == true)
        try await web.call("setArea", NSNull())
        try await web.call("setAttachments", ["images": [], "quote": NSNull()])
        sent = try await quickSend("visualize", in: web)
        #expect(sent["text"] as? String == "Visualize the key idea of this slide. " + Self.visRules)
    }

    @Test func sendPostsThePicturesAndQuoteOnScreen() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setThread", thread(images: [image("a", "one.png"), image("b", "two.png")], quote: walkthroughQuote))
        web.clearMessages()
        _ = try await web.evaluate("""
            const i = document.querySelector('#input'); i.value = 'Why is the inverse the transpose?';
            i.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true})); null;
            """)
        let typed = try await web.waitForMessage(type: "send")
        #expect(typed["text"] as? String == "Why is the inverse the transpose?")
        #expect(typed["imageIDs"] as? [String] == ["a", "b"])
        #expect(typed["quoteID"] as? String == "quote-1")
        #expect(typed["useArea"] as? Bool == false)
        #expect(typed["display"] is NSNull)
        #expect(try await web.evaluate("document.querySelector('#input').value") as? String == "")

        let quick = try await quickSend("explain", in: web)
        #expect(quick["imageIDs"] as? [String] == ["a", "b"])
        #expect(quick["quoteID"] as? String == "quote-1")

        try await web.call("setAttachments", ["images": [], "quote": NSNull()])
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#input').value = 'And now?'; document.querySelector('#btn-send').click(); null;")
        let plain = try await web.waitForMessage(type: "send")
        #expect(plain["imageIDs"] as? [String] == [])
        #expect(plain["quoteID"] is NSNull)
    }

    @Test func anEmptyBoxWithSomethingAttachedAsksToExplainIt() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        let enter = "{ const i = document.querySelector('#input'); i.value = '  '; "
            + "i.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true})); } null;"
        // Nothing attached: an empty box sends nothing, as before.
        try await web.call("setThread", thread())
        web.clearMessages()
        _ = try await web.evaluate(enter)
        try await Task.sleep(for: .milliseconds(80))
        #expect(posts("send", in: web).isEmpty)
        // A picture waiting: Enter is "Explain the screenshot", with the picture.
        try await web.call("setAttachments", ["images": [image("a", "one.png")], "quote": NSNull()])
        _ = try await web.evaluate(enter)
        let sent = try await web.waitForMessage(type: "send")
        #expect(sent["display"] as? String == "Explain the screenshot")
        #expect(sent["imageIDs"] as? [String] == ["a"])
        // A quoted passage: "Explain this passage", from Send too.
        try await web.call("setAttachments", ["images": [], "quote": walkthroughQuote])
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#input').value = ''; document.querySelector('#btn-send').click(); null;")
        #expect(try await web.waitForMessage(type: "send")["display"] as? String == "Explain this passage")
    }

    @Test func aQuestionWaitsForPicturesStillBeingPrepared() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setThread", thread(images: [image("a", "one.png")]))
        try await web.call("setAttachments", ["images": [image("a", "one.png")], "quote": NSNull(), "processing": 2])
        #expect(try await text(".att-wait", in: web) == "Preparing 2 pictures…")
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#input').value = 'What is this?'; document.querySelector('#btn-send').click(); null;")
        try await Task.sleep(for: .milliseconds(80))
        #expect(posts("send", in: web).isEmpty)
        #expect(try await text("#note", in: web) == "A picture is still being prepared. Send again in a moment.")
        #expect(try await web.evaluate("document.querySelector('#input').value") as? String == "What is this?")
        // In: the chip goes, the question goes with both pictures.
        try await web.call("setAttachments", ["images": [image("a", "one.png"), image("b", "two.png")], "quote": NSNull(), "processing": 0])
        #expect(try await flag("!document.querySelector('.att-wait')", in: web))
        _ = try await web.evaluate("document.querySelector('#btn-send').click(); null;")
        #expect(try await web.waitForMessage(type: "send")["imageIDs"] as? [String] == ["a", "b"])
        // Only pictures being prepared still show the box.
        try await web.call("setAttachments", ["images": [], "quote": NSNull(), "processing": 1])
        #expect(try await flag("!document.querySelector('#attachbox').hidden", in: web))
        #expect(try await text(".att-wait", in: web) == "Preparing a picture…")
        // Enter on the empty box (Explain the picture just pasted) waits too, and says so.
        web.clearMessages()
        _ = try await web.evaluate("""
            { document.querySelector('#note').textContent = ''; const i = document.querySelector('#input'); i.value = '';
              i.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true})); } null;
            """)
        try await Task.sleep(for: .milliseconds(80))
        #expect(posts("send", in: web).isEmpty)
        #expect(try await text("#note", in: web) == "A picture is still being prepared. Send again in a moment.")
    }

    @Test func keyboardFocusStaysOnTheSameRemoveButtonWhenAPictureArrives() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setThread", thread(images: [image("a", "one.png")], quote: walkthroughQuote))
        _ = try await web.evaluate("document.querySelector('.att-quote .att-x').focus(); null;")
        try await web.call("setAttachments", ["images": [image("a", "one.png"), image("b", "two.png")], "quote": walkthroughQuote])
        #expect(try await flag("document.activeElement === document.querySelector('.att-quote .att-x')", in: web))
        web.clearMessages()
        _ = try await web.evaluate("document.activeElement.click(); null;")
        #expect(try await web.waitForMessage(type: "clearQuote")["type"] as? String == "clearQuote")
        #expect(posts("removeImage", in: web).isEmpty)
    }

    @Test func thumbnailsCannotBeDraggedBackIntoTheChat() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        let messages: [[String: Any]] = [["id": "q", "role": "user", "page": 4, "text": "These?", "status": "done",
                                          "areaThumb": picture(), "images": [["label": "one.png", "thumb": picture()]]],
                                         ["id": "a", "role": "assistant", "provider": "claude", "page": 4, "status": "done",
                                          "text": "Like this one: ![sketch](\(picture()))"]]
        try await web.call("setThread", thread(images: [image("a", "one.png")], area: ["page": 4, "thumb": picture()], messages: messages))
        // The area box, the waiting pictures, the questions' pictures and pictures in answers.
        let images = "Array.from(document.querySelectorAll('#areabox img, #attachbox img, .bubble img, .msg.assistant .body img'))"
        #expect(try await flag("\(images).length === 5", in: web))
        #expect(try await flag("\(images).every(i => i.draggable === false)", in: web))
    }

    @Test func aStreamingAnswerIsStillFollowedWhenSomethingIsAttached() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        web.webView.frame.size = NSSize(width: 420, height: 760)
        try await web.load()
        let earlier = (1...40).map { "Line \($0) of an earlier answer about rotations." }.joined(separator: "\n\n")
        var paragraphs = ["The answer starts."]
        func answer() -> [String: Any] {
            ["id": "a2", "role": "assistant", "provider": "claude", "page": 4, "status": "streaming", "text": paragraphs.joined(separator: "\n\n")]
        }
        try await web.call("setThread", thread(messages: [
            ["id": "q1", "role": "user", "page": 4, "text": "Why?", "status": "done"],
            ["id": "a1", "role": "assistant", "provider": "claude", "page": 4, "text": earlier, "status": "done"],
            ["id": "q2", "role": "user", "page": 4, "text": "And then?", "status": "done"], answer()]))
        func stream() async throws {
            paragraphs.append("More of the answer arrives.")
            try await web.call("upsertMessage", answer())
            try await web.waitFor("document.querySelectorAll('[data-message-id=a2] .body p').length === \(paragraphs.count)")
        }
        /// At the end of the conversation once the page has caught up (it pins the conversation when it next draws).
        func atEnd() async -> Bool {
            (try? await web.waitFor("(l => l.scrollHeight - l.scrollTop - l.clientHeight < 1)(document.querySelector('#log'))")) != nil
        }
        try await stream()
        #expect(await atEnd())
        // A three-line quote (Reply, ⇧⌘L), then two rows of pictures (they widen as they load), while the answer streams.
        var quote = walkthroughQuote
        quote["text"] = String(repeating: "Rotations about the current frame multiply on the right. ", count: 6)
        try await web.call("setAttachments", ["images": [], "quote": quote])
        for _ in 0..<3 { try await stream() }
        #expect(await atEnd(), "stopped following after a quote")
        try await web.call("setAttachments", ["images": (1...4).map { image("p\($0)", "Screenshot \($0).png") }, "quote": quote])
        for _ in 0..<3 { try await stream() }
        #expect(await atEnd(), "stopped following after pictures")
        // Scrolled up to read: it stays where it was.
        _ = try await web.evaluate("document.querySelector('#log').scrollTop = 200; null;")
        try await Task.sleep(for: .milliseconds(50))
        try await web.call("setAttachments", ["images": [], "quote": NSNull()])
        try await stream()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await web.evaluate("document.querySelector('#log').scrollTop") as? Double == 200)
    }

    @Test func theAppLearnsWhenTheSearchBoxIsOpen() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        web.clearMessages()
        _ = try await web.evaluate("CL.openSearch(); null;")
        #expect(try await web.waitForMessage(type: "searchState")["open"] as? Bool == true)
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('#search-close').click(); null;")
        #expect(try await web.waitForMessage(type: "searchState")["open"] as? Bool == false)
    }

    // MARK: question bubbles

    @Test func questionBubblesShowPicturesAndAnExpandableQuote() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        web.webView.frame.size = NSSize(width: 420, height: 700)
        try await web.load()
        let long = (1...14).map { "Line \($0): the frame {B} is rotated about z by θ, so ᴬR_B = Rot(z, θ)." }.joined(separator: "\n")
        var quote = walkthroughQuote
        quote["text"] = long
        let messages: [[String: Any]] = [
            ["id": "q1", "role": "user", "page": 4, "text": "Explain this passage prompt", "display": "Explain this passage", "status": "done",
             "images": [["label": "board.png", "thumb": picture()], ["label": "Pasted image", "thumb": picture(hue: 0.1)]], "quote": quote],
            ["id": "a1", "role": "assistant", "provider": "claude", "page": 4, "text": "**Takeaway:** rotations compose.", "status": "done"],
            ["id": "q2", "role": "user", "page": 4, "text": "Short one?", "status": "done", "quote": notesQuote],
        ]
        try await web.call("setThread", thread(messages: messages))
        try await web.waitFor("document.querySelector('[data-message-id=q1] .q-block').classList.contains('more')")
        let first = "document.querySelector('[data-message-id=q1] .bubble')"
        #expect(try await web.evaluate("Array.from(\(first).querySelectorAll('img.shot'), i => [i.alt, i.title])") as? [[String]]
                == [["board.png", "board.png"], ["Pasted image", "Pasted image"]])
        #expect(try await flag("Array.from(\(first).querySelectorAll('img.shot')).every(i => i.getBoundingClientRect().height <= 140)", in: web))
        #expect(try await web.evaluate("\(first).querySelector('.q-from').textContent") as? String
                == "From Lecture 3 Walkthrough › Topic 2 › Rotation matrices")
        #expect(try await web.evaluate("\(first).querySelector('.q-text').textContent") as? String == long)
        #expect(try await web.evaluate("\(first).lastChild.textContent") as? String == "Explain this passage")
        // Pictures, then the quote, then the question.
        #expect(try await web.evaluate("Array.from(\(first).children, c => c.className)") as? [String] == ["shots", "q-block more"])

        // Clamped to about six lines; a click shows it all, another click folds it again.
        let block = "\(first).querySelector('.q-block')"
        let textEl = "\(first).querySelector('.q-text')"
        #expect(try await flag("\(textEl).scrollHeight > \(textEl).clientHeight + 1", in: web))
        #expect(try await web.evaluate("\(block).getAttribute('role') + ' ' + \(block).getAttribute('aria-expanded') + ' ' + \(block).tabIndex") as? String == "button false 0")
        _ = try await web.evaluate("\(block).click(); null;")
        #expect(try await flag("\(block).classList.contains('open') && \(block).getAttribute('aria-expanded') === 'true'", in: web))
        #expect(try await flag("\(textEl).scrollHeight <= \(textEl).clientHeight + 1", in: web))
        _ = try await web.evaluate("\(block).click(); null;")
        #expect(try await flag("!\(block).classList.contains('open') && \(textEl).scrollHeight > \(textEl).clientHeight + 1", in: web))
        // The keyboard opens it too, and it stays open when the conversation is redrawn.
        _ = try await web.evaluate("\(block).focus(); \(block).dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true})); null;")
        #expect(try await flag("\(block).classList.contains('open')", in: web))
        _ = try await web.evaluate("document.querySelector('#viewseg [data-v=all]').click(); null;")
        #expect(try await flag("\(block).classList.contains('open')", in: web))

        // A passage that fits is not a button; clicking it changes nothing.
        let short = "document.querySelector('[data-message-id=q2] .q-block')"
        try await web.waitFor("\(short).isConnected")
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await web.evaluate("\(short).querySelector('.q-from').textContent") as? String == "From L03_notes")
        #expect(try await flag("!\(short).classList.contains('more') && !\(short).hasAttribute('role') && !\(short).hasAttribute('tabindex')", in: web))
        _ = try await web.evaluate("\(short).click(); null;")
        #expect(try await flag("!\(short).classList.contains('open')", in: web))
        // Answers are unchanged.
        #expect(try await web.evaluate("document.querySelectorAll('[data-message-id=a1] .shots, [data-message-id=a1] .q-block').length") as? Int == 0)
        #expect(try await web.evaluate("document.querySelector('[data-message-id=a1] .body strong').textContent") as? String == "Takeaway:")
    }

    @Test func untrustedLabelsQuotesAndSourcesRenderAsText() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        let label = "<img src=x onerror=\"window.pwned=1\">.png"
        let hostile: [String: Any] = ["id": "evil", "source": "<i onmouseover=\"window.pwned=2\">Walkthrough</i>",
                                      "section": "<a href=\"https://example.com\">Topic</a>",
                                      "text": "<script>window.pwned=3</script><b>bold</b> &amp; R⁻¹", "kind": "selection"]
        let images: [[String: Any]] = [["id": "h", "label": label, "thumb": picture()],
                                       ["id": "remote", "label": "remote.png", "thumb": "https://example.com/pixel.png"]]
        let message: [String: Any] = ["id": "u", "role": "user", "page": 4, "text": "<svg onload=\"window.pwned=4\">", "status": "done",
                                      "images": [["label": label, "thumb": picture()], ["label": "x", "thumb": "javascript:window.pwned=5"]],
                                      "quote": hostile]
        try await web.call("setThread", thread(images: images, quote: hostile, messages: [message]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await web.evaluate("document.querySelectorAll('#attachbox script, #attachbox b, #attachbox i, #attachbox a, #attachbox svg').length") as? Int == 0)
        #expect(try await web.evaluate("document.querySelectorAll('#log script, #log b, #log i, #log a, #log svg').length") as? Int == 0)
        // Only the app's own data URL previews load.
        #expect(try await web.evaluate("document.querySelectorAll('#attachbox img').length") as? Int == 1)
        #expect(try await web.evaluate("document.querySelectorAll('#log img').length") as? Int == 1)
        #expect(try await flag("Array.from(document.querySelectorAll('img')).every(i => !i.getAttribute('src') || i.getAttribute('src').startsWith('data:image/'))", in: web))
        #expect(try await web.evaluate("Array.from(document.querySelectorAll('.att-label'), e => e.textContent)") as? [String] == [label, "remote.png"])
        #expect(try await text(".att-q-from", in: web) == "From " + (hostile["source"] as! String) + " › " + (hostile["section"] as! String))
        #expect(try await text(".att-q-text", in: web) == hostile["text"] as? String)
        #expect(try await text("#log .q-text", in: web) == hostile["text"] as? String)
        #expect(try await web.evaluate("document.querySelector('#log img.shot').alt") as? String == label)
        #expect(try await web.evaluate("document.querySelector('#log .bubble').lastChild.textContent") as? String == "<svg onload=\"window.pwned=4\">")
        #expect(try await web.evaluate("typeof window.pwned") as? String == "undefined")
    }

    // MARK: paste and drop

    @Test func aPasteReachingThePageReadsItsOwnPicturesWhileTextPastesNormally() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        // Returns whether the page took the paste over.
        func paste(file: String? = nil, text: String? = nil, into target: String = "#input") async throws -> Bool {
            try await flag("""
                (() => {
                  const dt = new DataTransfer();
                  \(file.map { "dt.items.add(new File([new Uint8Array([137, 80, 78, 71])], \(json($0)), {type: 'image/png'}));" } ?? "")
                  \(text.map { "dt.setData('text/plain', \(json($0)));" } ?? "")
                  const ev = new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true});
                  document.querySelector(\(json(target))).dispatchEvent(ev);
                  return ev.defaultPrevented;
                })()
                """, in: web)
        }
        #expect(try await paste(file: "image.png") == false)   // no deck open: nothing to attach to
        try await web.call("setThread", thread())
        web.clearMessages()
        // A copied picture (WebKit names it image.png) is read here and goes to the app as a "Pasted image".
        #expect(try await paste(file: "image.png"))
        let pasted = try await waitForPosts("attachImageData", count: 1, in: web)
        #expect(pasted.first?["name"] as? String == "Pasted image")
        #expect((pasted.first?["data"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        // A copied file keeps its name.
        web.clearMessages()
        #expect(try await paste(file: "Screenshot 2026-10-28 at 2.31.05 PM.png"))
        #expect(try await waitForPosts("attachImageData", count: 1, in: web).first?["name"] as? String
                == "Screenshot 2026-10-28 at 2.31.05 PM.png")
        // Text pastes as usual, also text that comes with a picture; a blank text doesn't count.
        web.clearMessages()
        #expect(try await paste(text: "R = Rot(z, θ)") == false)
        #expect(try await paste(file: "image.png", text: "copied text with a picture") == false)
        #expect(try await paste(file: "image.png", text: "   ") == true)
        _ = try await waitForPosts("attachImageData", count: 1, in: web)
        try await Task.sleep(for: .milliseconds(50))
        #expect(posts("attachImageData", in: web).count == 1)
        // The search box pastes as usual.
        try await web.call("openSearch", NSNull())
        web.clearMessages()
        #expect(try await paste(file: "image.png", into: "#search-input") == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(posts("attachImageData", in: web).isEmpty)
    }

    @Test func droppedPicturesAreReadInOrderAndOtherFilesAreSkipped() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        // Files: [name, type, bytes]. Returns whether the page took the drop over.
        func drop(_ files: [(String, String, [UInt8])]) async throws -> Bool {
            let make = files.map { "dt.items.add(new File([new Uint8Array(\(json($0.2)))], \(json($0.0)), {type: \(json($0.1))}));" }
            return try await flag("""
                (() => {
                  const dt = new DataTransfer();
                  \(make.joined(separator: "\n"))
                  const ev = new DragEvent('drop', {dataTransfer: dt, bubbles: true, cancelable: true});
                  document.querySelector('#log').dispatchEvent(ev);
                  return ev.defaultPrevented;
                })()
                """, in: web)
        }
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        #expect(try await drop([("shot.png", "image/png", png)]))   // no deck: taken, and ignored
        try await Task.sleep(for: .milliseconds(50))
        #expect(posts("attachImageData", in: web).isEmpty)

        try await web.call("setThread", thread())
        web.clearMessages()
        #expect(try await drop([("first.png", "image/png", png), ("IMG_2041.HEIC", "", [1, 2, 3])]))
        let read = try await waitForPosts("attachImageData", count: 2, in: web)
        #expect(read.map { $0["name"] as? String } == ["first.png", "IMG_2041.HEIC"])
        #expect((read[0]["data"] as? String) == "data:image/png;base64," + Data(png).base64EncodedString())
        #expect(read.allSatisfy { ($0["data"] as? String)?.hasPrefix("data:") == true && $0.count == 3 })

        web.clearMessages()
        #expect(try await drop([("notes.pdf", "application/pdf", [37, 80, 68, 70])]))
        #expect(try await text("#note", in: web) == "Only pictures can be attached (skipped “notes.pdf”).")
        #expect(try await flag("document.querySelector('#note').classList.contains('error')", in: web))
        try await Task.sleep(for: .milliseconds(50))
        #expect(posts("attachImageData", in: web).isEmpty)

        web.clearMessages()
        #expect(try await drop([("a.txt", "text/plain", [65]), ("diagram.jpeg", "image/jpeg", [255, 216, 255]), ("b.key", "", [1]), ("c.zip", "application/zip", [1])]))
        #expect(try await waitForPosts("attachImageData", count: 1, in: web).first?["name"] as? String == "diagram.jpeg")
        #expect(try await text("#note", in: web) == "Only pictures can be attached (skipped “a.txt”, “b.key” and 1 more).")

        // Promised files (a browser's picture): the app reads the drag itself.
        web.clearMessages()
        #expect(try await flag("""
            (() => {
              const ev = new Event('drop', {bubbles: true, cancelable: true});
              Object.defineProperty(ev, 'dataTransfer', {value: {types: ['Files', 'text/uri-list'], files: []}});
              document.querySelector('#log').dispatchEvent(ev);
              return ev.defaultPrevented;
            })()
            """, in: web))
        _ = try await web.waitForMessage(type: "dropImages")
        #expect(posts("attachImageData", in: web).isEmpty)

        // Too large files are skipped unread; no more than eight pictures go with one question.
        web.clearMessages()
        try await web.call("setAttachments", ["images": (1...6).map { image("p\($0)", "p\($0).png") }, "quote": NSNull()])
        _ = try await web.evaluate("""
            (() => {
              const big = {name: 'huge.png', type: 'image/png', size: 41 * 1024 * 1024};
              const files = [big].concat(['x.png', 'y.png', 'z.png'].map(n => new File([new Uint8Array([1])], n, {type: 'image/png'})));
              const ev = new Event('drop', {bubbles: true, cancelable: true});
              Object.defineProperty(ev, 'dataTransfer', {value: {types: ['Files'], files}});
              document.querySelector('#log').dispatchEvent(ev);
            })(); null;
            """)
        let kept = try await waitForPosts("attachImageData", count: 2, in: web)
        #expect(kept.map { $0["name"] as? String } == ["x.png", "y.png"])
        #expect(try await text("#note", in: web) == "“huge.png” is too large to attach. At most 8 pictures go with one question.")
        try await Task.sleep(for: .milliseconds(50))
        #expect(posts("attachImageData", in: web).count == 2)
    }

    @Test func dropOverlayFollowsTheDragAndLeavesTextDragsAlone() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        _ = try await web.evaluate("""
            window.fileDrag = (type, selector) => {
              const dt = new DataTransfer();
              dt.items.add(new File([new Uint8Array([1])], 'a.png', {type: 'image/png'}));
              const ev = new DragEvent(type, {dataTransfer: dt, bubbles: true, cancelable: true});
              document.querySelector(selector).dispatchEvent(ev);
              return ev.defaultPrevented;
            };
            window.dropShown = () => !document.querySelector('#drop-layer').hidden;
            null;
            """)
        // Without a deck the overlay says what to do first.
        #expect(try await flag("fileDrag('dragenter', '#log') && dropShown()", in: web))
        #expect(try await text("#drop-text", in: web) == "Open a lecture first")
        #expect(try await flag("document.querySelector('#drop-layer').classList.contains('off')", in: web))
        #expect(try await flag("fileDrag('dragleave', '#log') === false && !dropShown()", in: web))

        try await web.call("setThread", thread())
        #expect(try await flag("fileDrag('dragenter', '#log') && dropShown()", in: web))
        #expect(try await text("#drop-text", in: web) == "Drop screenshots or pictures to attach")
        #expect(try await flag("!document.querySelector('#drop-layer').classList.contains('off')", in: web))
        // Moving between nested elements doesn't flicker; leaving the page hides it.
        #expect(try await flag("fileDrag('dragenter', '#drop-layer'); fileDrag('dragleave', '#log'); dropShown()", in: web))
        #expect(try await flag("fileDrag('dragover', '#drop-layer') && dropShown()", in: web))
        #expect(try await flag("fileDrag('dragleave', '#drop-layer'); !dropShown()", in: web))
        // A drop hides it too, and so does a drag that ended elsewhere.
        #expect(try await flag("fileDrag('dragenter', '#input'); fileDrag('drop', '#drop-layer') && !dropShown()", in: web))
        #expect(try await flag("fileDrag('dragenter', '#input'); document.dispatchEvent(new DragEvent('dragend', {bubbles: true})); !dropShown()", in: web))
        #expect(try await flag("fileDrag('dragenter', '#input'); document.querySelector('#log').dispatchEvent(new MouseEvent('mousemove', {bubbles: true})); !dropShown()", in: web))
        #expect(try await flag("document.querySelector('#drop-layer').getBoundingClientRect().width > 0 === false", in: web))

        // Dragging text keeps the browser's own handling (e.g. into the chat box).
        #expect(try await flag("""
            (() => {
              const dt = new DataTransfer();
              dt.setData('text/plain', 'some words');
              const results = ['dragenter', 'dragover', 'drop'].map(type => {
                const ev = new DragEvent(type, {dataTransfer: dt, bubbles: true, cancelable: true});
                document.querySelector('#input').dispatchEvent(ev);
                return ev.defaultPrevented;
              });
              return results.every(r => r === false) && !dropShown();
            })()
            """, in: web))
    }

    @Test func notesShowForAFewSeconds() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await web.load()
        try await web.call("setThread", thread())
        #expect(try await web.evaluate("document.querySelector('#note').getBoundingClientRect().height") as? Double == 0)
        // Catch the page's timer so the test doesn't wait five seconds.
        _ = try await web.evaluate("""
            window.noteTimers = [];
            window.realSetTimeout = window.setTimeout;
            window.setTimeout = (fn, ms) => { window.noteTimers.push({fn, ms}); return 0; };
            CL.showNote({text: 'Couldn’t read “IMG_2041.HEIC” as an image.', error: true});
            window.setTimeout = window.realSetTimeout;
            null;
            """)
        #expect(try await text("#note", in: web) == "Couldn’t read “IMG_2041.HEIC” as an image.")
        #expect(try await flag("document.querySelector('#note').classList.contains('error')", in: web))
        #expect(try await web.evaluate("document.querySelector('#note').getAttribute('role')") as? String == "status")
        #expect(try await web.evaluate("noteTimers.map(t => t.ms)") as? [Int] == [5000])
        _ = try await web.evaluate("noteTimers[0].fn(); null;")
        #expect(try await text("#note", in: web) == "")
        #expect(try await flag("!document.querySelector('#note').classList.contains('error')", in: web))

        try await web.call("showNote", ["text": "Attached.", "error": false])
        #expect(try await text("#note", in: web) == "Attached.")
        #expect(try await flag("!document.querySelector('#note').classList.contains('error')", in: web))
    }

    // MARK: layout

    @Test func attachmentsFitNarrowPanels() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        web.webView.frame.size = NSSize(width: 420, height: 760)
        try await web.load()
        let efforts = [["id": "medium", "label": "Medium"], ["id": "high", "label": "High"]]
        try await web.call("setConfig", [
            "claude": ["models": [["id": "opus", "label": "Opus 5.5"]], "model": "opus", "efforts": efforts, "effort": "medium"],
            "codex": ["models": [["id": "gpt", "label": "GPT-6 Astra"]], "model": "gpt", "efforts": efforts, "effort": "high", "fastMode": true],
        ])
        let images = [image("a", "Screenshot 2026-10-28 at 9.41.07 AM.png"), image("b", "Pasted image", hue: 0.1),
                      image("c", "homework-3-problem-2-rotation-matrices-with-a-very-long-name.png", hue: 0.35)]
        var quote = walkthroughQuote
        quote["section"] = "Topic 2 › Rotation matrices › Composition of rotations about the fixed and current frames"
        quote["text"] = "Rotations about the current frame multiply on the right: R = R₁R₂. Rotations about the fixed frame "
            + "multiply on the left: R = R₂R₁. https://example.com/a/very/long/link/without/any/spaces/that/must/still/wrap/inside/the/card"
        let messages: [[String: Any]] = [
            ["id": "q1", "role": "user", "page": 4, "text": "x", "display": "Explain the screenshots", "status": "done",
             "images": images.map { ["label": $0["label"]!, "thumb": $0["thumb"]!] }],
            ["id": "a1", "role": "assistant", "provider": "claude", "page": 4, "text": "The first screenshot shows **R = Rot(z, θ)**.", "status": "done"],
            ["id": "q2", "role": "user", "page": 4, "text": "Which side do they multiply on?", "status": "done", "quote": quote],
        ]
        var t = thread(images: images, quote: quote, area: ["page": 4, "thumb": picture(width: 240, height: 120, hue: 0.8)], messages: messages)
        t["provider"] = "both"
        try await web.call("setThread", t)
        try await web.call("showNote", ["text": "Only pictures can be attached (skipped “Lecture 4 handout (annotated).pdf”).", "error": true])

        for width in [420.0, 340.0] {
            web.webView.frame.size.width = width
            try await web.waitFor("window.innerWidth === \(Int(width))")
            try await Task.sleep(for: .milliseconds(50))
            #expect(try await flag("document.documentElement.scrollWidth <= window.innerWidth", in: web), "page scrolls sideways at \(width)")
            #expect(try await flag("""
                Array.from(document.querySelectorAll('#composer *, #log .bubble, #log .bubble *')).every(e => {
                  const r = e.getBoundingClientRect();
                  return r.width === 0 || (r.left >= -0.5 && r.right <= window.innerWidth + 0.5);
                })
                """, in: web), "something sticks out at \(width)")
            // Clamped quotes clip what overflows: a long link must wrap rather than run off to the right unseen.
            #expect(try await flag("['#composer', '#attachbox', '.att-pics', '.att-quote', '.att-q-text', '#quick', '#log', '#log .q-text'].every(s => { const e = document.querySelector(s); return e.scrollWidth <= e.clientWidth + 1; })", in: web), "overflow at \(width)")
            #expect(try await flag("new Set(Array.from(document.querySelectorAll('.att-pic'), e => Math.round(e.getBoundingClientRect().top))).size > 1", in: web), "chips don't wrap at \(width)")
            #expect(try await flag("(() => { const t = document.querySelector('.att-q-text'); return t.scrollHeight > t.clientHeight + 1; })()", in: web))
            if width == 420, ProcessInfo.processInfo.environment["COLEARNER_TEST_SNAPSHOTS"] != nil {
                try await web.snapshot(to: URL(fileURLWithPath: "/tmp/colearner-v019-attachments.png"))
            }
        }
    }

    /// The row with Stop on screen, and the chat box's own rows whole: the first (the chips) not cut off at the top.
    private let chatBoxWhole = """
        (() => { const r = (s) => document.querySelector(s).getBoundingClientRect(), c = r('#composer');
                 return r('#quick').top >= c.top + 8.5 && ['#btn-send', '#providers'].every(s => { const b = r(s);
                   return b.height > 0 && b.top >= 0 && b.bottom <= innerHeight; }); })()
        """

    /// The page with both assistants' model pickers in the bar, as in the app (they wrap it to two rows at 340 px).
    private func shortChat(_ web: ChatWebFixture) async throws {
        try await web.load()
        let efforts = [["id": "medium", "label": "Medium"], ["id": "high", "label": "High"]]
        try await web.call("setConfig", [
            "claude": ["models": [["id": "opus", "label": "Opus 5.5"]], "model": "opus", "efforts": efforts, "effort": "medium"],
            "codex": ["models": [["id": "gpt", "label": "GPT-6 Astra"]], "model": "gpt", "efforts": efforts, "effort": "high"],
        ])
    }

    /// A question and its answer still streaming (Send reads Stop).
    private let streaming: [[String: Any]] = [["id": "q", "role": "user", "page": 4, "text": "Why?", "status": "done"],
                                              ["id": "a", "role": "assistant", "provider": "claude", "page": 4, "text": "So far", "status": "streaming"]]

    @Test func waitingAttachmentsGiveWayInAShortNarrowChat() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await shortChat(web)
        let area: [String: Any] = ["page": 4, "thumb": picture(width: 240, height: 120, hue: 0.8)]
        // (width, height, provider, pictures), each with an area and a walkthrough quote while an answer streams.
        for (width, height, provider, count) in [(340.0, 600.0, "both", 2), (420.0, 700.0, "claude", 8)] {
            web.webView.frame.size = NSSize(width: width, height: height)
            var t = thread(images: (1...count).map { image("p\($0)", "Screenshot 2026-10-28 at 9.4\($0).07 AM.png") },
                           quote: walkthroughQuote, area: area, messages: streaming)
            t["provider"] = provider
            try await web.call("setThread", t)
            try await web.waitFor("window.innerWidth === \(Int(width)) && window.innerHeight === \(Int(height))")
            let size = "\(Int(width))×\(Int(height))"
            #expect(try await text("#btn-send", in: web) == "Stop")
            // Stop and the rest of the chat box stay on screen, the conversation keeps a quarter of the window,
            #expect(try await flag(chatBoxWhole, in: web), "chat box cut off at \(size)")
            #expect(try await flag("document.querySelector('#log').getBoundingClientRect().height >= innerHeight / 4 - 0.5", in: web),
                    "conversation squeezed at \(size)")
            // and the pictures and the quote scroll instead.
            #expect(try await flag("(b => b.clientHeight > 0 && b.scrollHeight > b.clientHeight)(document.querySelector('#attachbox'))", in: web),
                    "nothing gave way at \(size)")
        }
    }

    @Test func theChatBoxStaysWholeWhereAQuarterForTheConversationDoesNotFit() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await shortChat(web)
        let box = "document.querySelector('#attachbox')"
        // Under 520 px there is no room for a quarter and what waits: as before, one picture shows whole and a quote's
        // card at least down to its ✕ (it scrolls), next to all of the chat box.
        for (height, provider, images, quote) in [(450.0, "both", 1, false), (420.0, "claude", 0, true)] {
            web.webView.frame.size = NSSize(width: 340, height: height)
            var t = thread(images: (0..<images).map { image("p\($0)", "Screenshot 2026-10-28 at 9.4\($0).07 AM.png") },
                           quote: quote ? walkthroughQuote : NSNull(), messages: streaming)
            t["provider"] = provider
            try await web.call("setThread", t)
            try await web.waitFor("window.innerWidth === 340 && window.innerHeight === \(Int(height))")
            #expect(try await flag(chatBoxWhole, in: web), "chat box cut off at 340×\(Int(height))")
            #expect(try await flag(quote
                ? "(b => { const x = document.querySelector('.att-quote .att-x').getBoundingClientRect(); return x.top >= b.top && x.bottom <= b.bottom; })(\(box).getBoundingClientRect())"
                : "(b => b.clientHeight > 0 && b.scrollHeight <= b.clientHeight)(\(box))", in: web), "what waits is hidden at 340×\(Int(height))")
        }
        // Taller, where the chat box's rows and a quarter for the conversation don't both fit, the conversation gives way
        // to the rows, never the top of the chat box: with the other-slides row up (the decided load, 33 px less room),
        let log = "document.querySelector('#log').getBoundingClientRect().height"
        let atEnd = "(l => l.scrollHeight - l.scrollTop - l.clientHeight < 1)(document.querySelector('#log'))"
        let earlier = (1...30).map { "Line \($0) of an earlier answer." }.joined(separator: "\n\n")
        web.webView.frame.size = NSSize(width: 340, height: 700)
        var t = thread(images: [image("p1", "Screenshot 1.png"), image("p2", "Screenshot 2.png")], quote: walkthroughQuote,
                       area: ["page": 4, "thumb": picture(width: 240, height: 120, hue: 0.8)],
                       messages: [["id": "a0", "role": "assistant", "provider": "claude", "page": 4, "text": earlier, "status": "done"]] + streaming)
        t["provider"] = "both"
        t["pages"] = [3, 4, 7]
        try await web.call("setThread", t)
        try await web.waitFor("window.innerHeight === 700 && !document.querySelector('#others').hidden && document.querySelector('#area-img').complete")
        #expect(try await flag("\(log) >= innerHeight / 4 - 0.5", in: web))
        web.webView.frame.size = NSSize(width: 340, height: 600)
        try await web.waitFor("window.innerHeight === 600")
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await flag(chatBoxWhole, in: web), "chat box cut off with the other-slides row")
        #expect(try await flag("\(log) >= innerHeight / 5", in: web))
        // Measuring again (a note shows, the window says it resized) leaves the conversation where it was, at its end.
        #expect(try await flag(atEnd, in: web))
        try await web.call("showNote", ["text": "Only pictures can be attached.", "error": false])
        _ = try await web.evaluate("window.dispatchEvent(new Event('resize')); null;")
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await flag("\(chatBoxWhole) && \(atEnd)", in: web), "measuring the chat box moved the conversation")
        // and with a long question typed.
        web.webView.frame.size = NSSize(width: 340, height: 650)
        t["images"] = [image("p1", "Screenshot 1.png")]
        t["quote"] = NSNull()
        t["pages"] = [4]
        try await web.call("setThread", t)
        try await web.waitFor("window.innerHeight === 650 && document.querySelector('#others').hidden")
        #expect(try await flag("\(chatBoxWhole) && \(log) >= innerHeight / 4 - 0.5", in: web))
        _ = try await web.evaluate("""
            { const i = document.querySelector('#input'); i.value = Array(10).fill('a line of the question').join('\\n');
              i.dispatchEvent(new Event('input')); } null;
            """)
        try await web.waitFor("document.querySelector('#input').offsetHeight >= 170")
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await flag(chatBoxWhole, in: web), "chat box cut off by a long question")
        #expect(try await flag("\(log) >= 60", in: web))
        // Once nothing waits, the conversation takes the rest again.
        _ = try await web.evaluate("document.querySelector('#input').value = ''; null;")
        try await web.call("setAttachments", ["images": [], "quote": NSNull()])
        #expect(try await flag("document.querySelector('#log').style.minHeight === ''", in: web))
    }

    // MARK: the header and the bar

    /// The header has no deck title (the tab and window title show it): its view toggle and buttons, one height, sit
    /// together on the left and the plan usage at the right, as whole as the row allows. The chat box ends with the
    /// bar (no status line); an answer running on another slide is named next to Stop or, where that has no room, under it.
    @Test func theHeaderHoldsTheButtonsAndThePlanUsageAndTheBarNamesAnAnswerElsewhere() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await shortChat(web)
        try await web.call("setUsage", [
            "claude": ["windows": [["label": "5h", "percent": 1], ["label": "week", "percent": 0]], "updated": 0],
            "codex": ["windows": [["label": "5h", "percent": 0], ["label": "week", "percent": 7]], "updated": 0]])
        try await web.call("setThread", thread())
        #expect(try await flag("!document.querySelector('#where, #status, #attach')", in: web))
        #expect(try await flag("""
            (() => { const b = ['#viewseg', '#btn-history', '#btn-new', '#btn-search'].map(s => document.querySelector(s).getBoundingClientRect());
                     return b[0].left < 14 && b.every((r, i) => Math.abs(r.height - b[0].height) < 0.5 && Math.abs(r.top - b[0].top) < 0.5
                       && (i === 0 || r.left - b[i - 1].right < 8)); })()
            """, in: web), "the header's buttons differ in height or stand apart")
        #expect(try await text("#log .empty", in: web) == "Ask anything about slide 4.")
        #expect((try await web.evaluate("document.querySelector('#log .empty').title") as? String)?.isEmpty == false)
        #expect(try await web.evaluate("document.querySelector('#usage').title") as? String
                == "Plan usage: Claude 5h 1% · week 0%, ChatGPT 5h 0% · week 7%. Click for details")
        #expect(try await flag("(c => c.bottom - document.querySelector('#bar').getBoundingClientRect().bottom < 12)(document.querySelector('#composer').getBoundingClientRect())", in: web),
                "something under the bar")

        // Names, then dots for them ("wk" for "week"), then no windows' names; a narrow chat puts the whole line on a row of
        // its own.
        let usage = """
            (() => { const u = document.querySelector('#usage'), r = u.getBoundingClientRect(), s = document.querySelector('#btn-search').getBoundingClientRect(),
                       h = document.querySelector('#head').getBoundingClientRect();
                     return [u.dataset.form || 'whole', r.top < s.bottom ? 'beside' : 'below', r.right <= h.right - 11.5,
                             Math.round(h.height)].join(' '); })()
            """
        // (588 px: a 1512 pt wide window at 3 : 2)
        for (width, expected) in [(820.0, "whole beside true 41"), (640.0, "short beside true 41"), (588.0, "short beside true 41"),
                                  (530.0, "shorter beside true 41"), (420.0, "whole below true 71")] {
            web.webView.frame.size = NSSize(width: width, height: 700)
            try await web.waitFor("window.innerWidth === \(Int(width))")
            try await Task.sleep(for: .milliseconds(80))
            #expect(try await web.evaluate(usage) as? String == expected, "usage at \(Int(width)) px")
            #expect(try await flag("document.documentElement.scrollWidth <= window.innerWidth", in: web))
            if width == 588 { try await snapshot(web, "colearner-header-588.png") }
        }
        // Its card opens under the header.
        web.webView.frame.size = NSSize(width: 640, height: 700)
        try await web.waitFor("window.innerWidth === 640")
        try await Task.sleep(for: .milliseconds(80))
        try await snapshot(web, "colearner-header-640.png")
        _ = try await web.evaluate("document.querySelector('#usage').click(); null;")
        try await web.waitFor("!document.querySelector('.pop').hidden")
        #expect(try await flag("document.querySelector('.pop').getBoundingClientRect().top >= document.querySelector('#usage').getBoundingClientRect().bottom", in: web))
        _ = try await web.evaluate("document.querySelector('#usage').click(); null;")

        // An answer on slide 7, not on screen: next to Stop; with both model buttons in the bar, on a line under it.
        let question: [String: Any] = ["id": "q", "role": "user", "page": 7, "text": "Why?", "status": "done"]
        let claude: [String: Any] = ["id": "a", "role": "assistant", "provider": "claude", "page": 7, "text": "So far", "status": "streaming"]
        let codex: [String: Any] = ["id": "b", "role": "assistant", "provider": "codex", "page": 7, "text": "", "status": "streaming"]
        web.webView.frame.size = NSSize(width: 720, height: 700)
        try await web.waitFor("window.innerWidth === 720")
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await web.evaluate(usage) as? String == "whole beside true 41", "usage at 720 px after the card")
        var t = thread(messages: [question, claude])
        try await web.call("setThread", t)
        #expect(try await text("#btn-send", in: web) == "Stop")
        #expect(try await text("#away", in: web) == "Claude is answering on slide 7")
        #expect(try await flag("(a => !a.classList.contains('below') && a.scrollWidth <= a.clientWidth + 1)(document.querySelector('#away'))", in: web))
        t["provider"] = "both"
        t["messages"] = [question, claude, codex]
        try await web.call("setThread", t)
        #expect(try await text("#away", in: web) == "Claude and ChatGPT are answering on slide 7")
        #expect(try await flag("(a => a.classList.contains('below') && a.scrollWidth <= a.clientWidth + 1)(document.querySelector('#away'))", in: web))
        #expect(try await flag("document.querySelector('#away').getBoundingClientRect().top >= document.querySelector('#btn-send').getBoundingClientRect().bottom", in: web))
        // Once the answers are on screen (All), the note goes.
        _ = try await web.evaluate("document.querySelector('#viewseg [data-v=all]').click(); null;")
        try await web.waitFor("document.querySelector('#away').textContent === ''")
        _ = try await web.evaluate("document.querySelector('#viewseg [data-v=slide]').click(); null;")
        try await snapshot(web, "colearner-header-and-bar-720.png")
    }

    /// The usage line hides from the header (the app's View › Hide Plan Usage ⌥⌘U, Settings, or the link in its card)
    /// and comes back where it was.
    @Test func thePlanUsageCanBeHiddenAndShownAgain() async throws {
        let web = ChatWebFixture()
        defer { #expect(web.javaScriptErrors.isEmpty); web.close() }
        try await shortChat(web)
        let usage: [String: Any] = [
            "claude": ["windows": [["label": "5h", "percent": 1], ["label": "week", "percent": 0]], "updated": 0],
            "codex": ["windows": [["label": "5h", "percent": 0], ["label": "week", "percent": 7]], "updated": 0]]
        try await web.call("setUsage", usage)
        try await web.call("setThread", thread())
        // The card's link asks the app to hide the line.
        _ = try await web.evaluate("document.querySelector('#usage').click(); null;")
        try await web.waitFor("!!document.querySelector('.pop:not([hidden]) .u-hide .link')")
        try await snapshot(web, "colearner-usage-card.png")
        web.clearMessages()
        _ = try await web.evaluate("document.querySelector('.pop .u-hide .link').click(); null;")
        #expect(try await web.waitForMessage(type: "setUsageHidden")["hidden"] as? Bool == true)
        // The app's answer hides it and closes the card; the buttons stay where they were.
        let left = "document.querySelector('#btn-search').getBoundingClientRect().left"
        let search = try await web.evaluate(left) as? Double
        try await web.call("setUsageHidden", true)
        #expect(try await flag("document.querySelector('#usage').getBoundingClientRect().width === 0 && document.querySelector('.pop').hidden", in: web))
        #expect(try await web.evaluate(left) as? Double == search)
        // New numbers while it is hidden keep it hidden; shown again, it is back on the header's row.
        try await web.call("setUsage", usage)
        #expect(try await flag("document.querySelector('#usage').hidden", in: web))
        try await web.call("setUsageHidden", false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await flag("(u => u.width > 0 && u.top < document.querySelector('#btn-search').getBoundingClientRect().bottom)(document.querySelector('#usage').getBoundingClientRect())", in: web))
        #expect(try await text("#usage", in: web)?.contains("ChatGPT") == true)
    }

    /// With COLEARNER_TEST_SNAPSHOTS set, a picture of the page: in that folder when it names one, else in /tmp.
    private func snapshot(_ web: ChatWebFixture, _ name: String) async throws {
        guard let value = ProcessInfo.processInfo.environment["COLEARNER_TEST_SNAPSHOTS"] else { return }
        let folder = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(fileURLWithPath: "/tmp")
        try await web.snapshot(to: folder.appendingPathComponent(name))
    }
}

/// The chat's web view takes ⌘V / Edit › Paste for pictures itself (the only place macOS lets an app read the clipboard
/// without asking). These tests never touch the clipboard: the picture check is a stand-in.
@Suite(.serialized)
@MainActor
struct ChatPasteTests {
    @Test func pasteGoesToThePicturesFirstAndPasteStaysAvailable() {
        let view = PasteWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var asked = 0
        view.pastePictures = { asked += 1; return true }
        view.paste(nil)
        #expect(asked == 1)   // a picture was taken: WebKit's paste (which would read the clipboard) never ran
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(view.validateUserInterfaceItem(item))
        #expect(WKWebView.instancesRespond(to: #selector(NSText.paste(_:))))   // the paste it hands text to
    }
}
