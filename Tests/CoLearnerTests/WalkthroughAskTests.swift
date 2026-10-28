import AppKit
import CoreText
import PDFKit
import Testing
import WebKit
@testable import CoLearner

/// Asking the chat about the walkthrough: walkthrough_ask.js running in a real (nonpersistent) WebKit view next to the
/// indexer, injected the way the app does, on a fixture page with fake MathJax 3 records and KaTeX markup; the
/// controller's checks on what pages send; and asking about notes PDFs.
@Suite(.serialized)
@MainActor
struct WalkthroughAskTests {
    // MARK: extraction and sections

    @Test func extractionKeepsTeXSkipsHiddenAndAssistiveTextAndBreaksBlocks() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('intro'))")
                == #"A rotation $R(\theta)$ turns the plane."#)
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('props'))") == #"""
            Properties
            Its inverse is its transpose:
            $$R^{-1} = R^{\top}$$
            and $\det R = 1$ always.
            Unlisted x math.
            Composition
            Rotations add angles.
            - first
            - second
            a | b
            Show more
            """#)
        // A selection that starts and ends inside text, across a formula and a block boundary.
        let partial = try await page.string("""
            (function () {
              var r = document.createRange();
              r.setStart(document.getElementById('intro').firstChild, 2);
              r.setEnd(document.getElementById('p1').firstChild, 11);
              return __coLearnerAsk.textOf(r);
            })()
            """)
        #expect(partial == "rotation $R(\\theta)$ turns the plane.\nProperties\nIts inverse")
        // Starting inside a formula takes the whole formula.
        #expect(try await page.string("""
            (function () {
              var r = document.createRange();
              r.selectNodeContents(document.querySelector('#intro mjx-assistive-mml'));
              return __coLearnerAsk.textOf(r);
            })()
            """) == #"$R(\theta)$"#)
        // Long passages are capped.
        let capped = try await page.string("__coLearnerAsk.textOf(document.getElementById('props'), 40)")
        #expect(capped.count <= 40 && capped.hasSuffix("…"))
    }

    @Test func sectionPathFollowsTheIndexedSectionsAndHeadingSpans() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        func section(_ selector: String) async throws -> String {
            try await page.string("__coLearnerAsk.sectionOf(document.querySelector('\(selector)'))")
        }
        #expect(try await section("#intro") == "Topic 3 · 2D rotation")
        #expect(try await section("#p1") == "Topic 3 · 2D rotation › Properties")
        #expect(try await section("#p3") == "Topic 3 · 2D rotation › Properties › Composition")
        #expect(try await section("#h1") == "Topic 4 · Homogeneous transforms")
        #expect(try await section("#lede") == "Fixture walkthrough")
        #expect(try await section(".topnav a") == "")
        // The heading span ends at the end of its block (nothing after it in the subsection).
        #expect(try await page.string("(function () { var e = __coLearnerWT.entryAt(document.getElementById('p3')); return e.kind + ':' + (e.end === null) + ':' + e.block.id; })()")
                == "heading:true:props")
        // A point of the view in the margin under a paragraph hits the subsection's own box; the span still counts.
        #expect(try await page.string("""
            (function () {
              var p = document.getElementById('p3'); p.scrollIntoView({block: 'center'});
              var r = p.getBoundingClientRect(), x = r.left + 40, y = r.bottom + 4;
              if (document.elementFromPoint(x, y).id !== 'props') return 'not in the margin';
              return __coLearnerAsk.sectionAt(x, y);
            })()
            """) == "Topic 3 · 2D rotation › Properties › Composition")
    }

    @Test func collectReturnsTheSelectionOrElseTheSectionInView() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        try await page.select("p3")
        let selected = try await page.json("__coLearnerAsk.collect()")
        #expect(selected?["kind"] as? String == "selection")
        #expect(selected?["text"] as? String == "Rotations add angles.")
        #expect(selected?["section"] as? String == "Topic 3 · 2D rotation › Properties › Composition")

        // No selection: the section a third of the way down the view, below the sticky top bar.
        _ = try await page.evaluate("getSelection().removeAllRanges(); document.getElementById('hom').scrollIntoView(); true")
        let reading = try await page.json("__coLearnerAsk.collect()")
        #expect(reading?["kind"] as? String == "section")
        #expect(reading?["section"] as? String == "Topic 4 · Homogeneous transforms")
        #expect(reading?["text"] as? String == "Topic 4 · Homogeneous transforms\nStack rotation and translation.")

        // The heading span being read runs from its heading to the end of its block. The reading point is a third
        // of the way down below the 40 px top bar; put the paragraph's line there.
        _ = try await page.evaluate("""
            var y0 = 40 + (innerHeight - 40) / 3;
            window.scrollTo(0, document.getElementById('p3').getBoundingClientRect().top + pageYOffset - y0 + 10); true
            """)
        let span = try await page.json("__coLearnerAsk.collect()")
        #expect(span?["section"] as? String == "Topic 3 · 2D rotation › Properties › Composition")
        #expect(span?["text"] as? String == "Composition\nRotations add angles.\n- first\n- second\na | b\nShow more")

        // Text selected in an answer box is not a passage of the page.
        _ = try await page.evaluate("var i = document.getElementById('answer'); i.focus(); i.setSelectionRange(0, 3); true")
        #expect(try await page.json("__coLearnerAsk.collect()")?["kind"] as? String == "section")
    }

    // MARK: the floating button

    @Test func buttonAppearsNextToSelectionAndPostsItToTheApp() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        try await page.select("p3")
        try await page.mouseUp(on: "p3")
        try await page.waitFor(AskPage.buttonShown)
        let state = try await page.json(AskPage.buttonState)
        let button = try #require(state)
        #expect(button["hit"] as? Bool == true, "the button is on top where it is drawn")
        #expect(button["closed"] as? Bool == true, "page scripts and CSS can't reach inside it")
        #expect(button["text"] as? String == "", "its label is never part of the page's text")
        #expect(try await page.evaluate("getSelection().toString()") as? String == "Rotations add angles.")
        let selection = try await page.json("JSON.parse(JSON.stringify(getSelection().getRangeAt(0).getBoundingClientRect()))")
        let end = try #require(selection)
        let top = try #require(button["top"] as? Double), left = try #require(button["left"] as? Double)
        let width = try #require(button["width"] as? Double), bottom = try #require(end["bottom"] as? Double)
        let right = try #require(end["right"] as? Double)
        #expect(top >= bottom && top <= bottom + 20, "just below the line where the selection ends")
        #expect(abs(left + width - 12 - right) < 1)

        // The page's arrow keys still turn the slides while it is up.
        _ = try await page.evaluate("document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowRight', bubbles: true})); true")
        try await page.waitUntil { page.turns == [1] }
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == true)

        _ = try await page.evaluate("document.querySelector('colearner-ask').dispatchEvent(new MouseEvent('click', {bubbles: true})); true")
        try await page.waitUntil { page.asks.count == 1 }
        #expect(page.asks.first?["kind"] as? String == "selection")
        #expect(page.asks.first?["text"] as? String == "Rotations add angles.")
        #expect(page.asks.first?["section"] as? String == "Topic 3 · 2D rotation › Properties › Composition")
        #expect(try await page.evaluate("getSelection().isCollapsed") as? Bool == true)
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == false)
    }

    @Test func buttonFollowsTheEndOfSelectionsThatEndInAParentOrRunBackwards() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        // Ends after the display formula, i.e. in the formula's parent (as a drag past an equation does): below the
        // formula's right end, not at the start.
        let end = try await page.json("""
            (function () {
              var p1 = document.getElementById('p1'), eq = document.querySelector('mjx-container[display]');
              p1.scrollIntoView({block: 'center'});
              var r = document.createRange(); r.setStart(p1.firstChild, 0); r.setEndAfter(eq);
              var s = getSelection(); s.removeAllRanges(); s.addRange(r);
              return JSON.parse(JSON.stringify(eq.getBoundingClientRect()));
            })()
            """)
        try await page.mouseUp(on: "p1")
        try await page.waitFor(AskPage.buttonShown)
        let state = try await page.json(AskPage.buttonState)
        let after = try #require(state), formula = try #require(end)
        let top = try #require(after["top"] as? Double), bottom = try #require(formula["bottom"] as? Double)
        #expect(top >= bottom && top <= bottom + 20, "below the formula the selection ends with")
        #expect(try #require(after["left"] as? Double) > 300, "at the right end, where the drag let go")

        // Made backwards (from the end of p3 to its start): above the line, at its left end.
        let line = try await page.json("""
            (function () {
              var t = document.getElementById('p3').firstChild;
              getSelection().setBaseAndExtent(t, t.length, t, 0);
              return JSON.parse(JSON.stringify(getSelection().getRangeAt(0).getBoundingClientRect()));
            })()
            """)
        try await page.mouseUp(on: "p3")
        try await page.waitFor("""
            document.querySelector('colearner-ask').getBoundingClientRect().bottom <= document.getElementById('p3').getBoundingClientRect().top
            """)
        let backState = try await page.json(AskPage.buttonState)
        let back = try #require(backState), text = try #require(line)
        let backTop = try #require(back["top"] as? Double), backHeight = try #require(back["height"] as? Double)
        let lineTop = try #require(text["top"] as? Double), lineLeft = try #require(text["left"] as? Double)
        #expect(abs(backTop + backHeight + 6 - lineTop) < 1, "just above the line")
        #expect(abs(try #require(back["left"] as? Double) - max(6, lineLeft - 12)) < 1)
    }

    @Test func buttonHidesOnEscapeCollapseAndClicksElsewhere() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        for hide in ["document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))",
                     "getSelection().removeAllRanges()",
                     "document.getElementById('lede').dispatchEvent(new MouseEvent('mousedown', {bubbles: true}))"] {
            try await page.select("p1")
            try await page.mouseUp(on: "p1")
            try await page.waitFor(AskPage.buttonShown)
            _ = try await page.evaluate(hide + "; true")
            try await page.waitFor("!(\(AskPage.buttonShown))")
        }
        #expect(page.asks.isEmpty)
    }

    @Test func noButtonForSelectionsInsideTextFields() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        _ = try await page.evaluate("var i = document.getElementById('answer'); i.focus(); i.setSelectionRange(0, 3); true")
        try await page.mouseUp(on: "answer")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == false)
        // Page text right after still gets it.
        _ = try await page.evaluate("document.getElementById('answer').blur(); true")
        try await page.select("p1")
        try await page.mouseUp(on: "p1")
        try await page.waitFor(AskPage.buttonShown)
    }

    // MARK: the controller

    @Test func controllerTurnsOnlyValidAskMessagesFromItsPageIntoQuotes() async throws {
        let page = try AskPage(handlers: false)
        defer { page.close() }
        let controller = WalkthroughController(webView: page.webView)
        var quotes: [ChatQuote] = []
        controller.onAsk = { quotes.append($0) }
        controller.show(StudyPage(title: "Fixture Walkthrough", path: page.url.path), slide: 1, follow: false)
        try await page.waitFor(AskPage.ready)

        _ = try await page.evaluate("""
            var h = window.webkit.messageHandlers.clask;
            [null, "text", 5, [], {}, {kind: "selection"}, {kind: "selection", text: ""}, {kind: "selection", text: " \\n "},
             {kind: "quote", text: "x"}, {kind: "selection", text: 7}, {kind: "section", text: "ok", section: 3}]
              .forEach(function (b) { h.postMessage(b); });
            h.postMessage({kind: "section", text: "  Hello  ", section: "A \\u203a B"});
            h.postMessage({kind: "selection", text: "x".repeat(9000), section: "y".repeat(400)});
            h.postMessage({kind: "selection", text: "no section", section: null});
            true
            """)
        try await page.waitUntil { quotes.count == 3 }
        #expect(quotes[0].source == "Fixture Walkthrough")
        #expect(quotes[0].kind == "section" && quotes[0].text == "Hello" && quotes[0].section == "A › B")
        #expect(quotes[1].text.count == ChatQuote.maxText && quotes[1].section?.count == 300)
        #expect(quotes[2].section == nil && quotes[2].text == "no section")

        // A frame inside the page has the handler too, but doesn't count.
        _ = try await page.evaluate("""
            window.addEventListener('message', function () { window.__frameDone = true; });
            var f = document.createElement('iframe');
            f.srcdoc = "<script>window.webkit.messageHandlers.clask.postMessage({kind: 'selection', text: 'from a frame'});" +
                       "parent.postMessage('done', '*');<\\/script>";
            document.body.appendChild(f);
            true
            """)
        try await page.waitFor("window.__frameDone === true")
        try await Task.sleep(for: .milliseconds(100))
        #expect(quotes.count == 3)

        // The Ask button: the selection, checked the same way.
        try await page.select("p3")
        let asked = try await withCheckedThrowingContinuation { (c: CheckedContinuation<ChatQuote?, Error>) in
            controller.collectQuote { c.resume(returning: $0) }
        }
        #expect(asked?.kind == "selection" && asked?.text == "Rotations add angles.")
        #expect(asked?.section == "Topic 3 · 2D rotation › Properties › Composition")
        #expect(asked?.source == "Fixture Walkthrough")

        // Once the page is gone, what the web view sends is ignored.
        controller.show(nil, slide: 1, follow: false)
        try await page.waitFor("location.href === 'about:blank' && document.readyState === 'complete'")
        _ = try await page.evaluate("window.webkit.messageHandlers.clask.postMessage({kind: 'selection', text: 'late'}); true")
        try await Task.sleep(for: .milliseconds(150))
        #expect(quotes.count == 3)
        #expect(controller.quote(from: ["kind": "selection", "text": "x"]) == nil)
    }

    @Test func captureSnapshotsTheBoxAndNamesItsSection() async throws {
        let page = try AskPage(html: AskPage.colors, handlers: false)
        defer { page.close() }
        let controller = WalkthroughController(webView: page.webView)
        controller.show(StudyPage(title: "Colors", path: page.url.path), slide: 1, follow: false)
        try await page.waitFor(AskPage.ready)
        let (image, section) = await withCheckedContinuation { (c: CheckedContinuation<(CGImage?, String?), Never>) in
            controller.capture(CGRect(x: 300, y: 100, width: 200, height: 100)) { c.resume(returning: ($0, $1)) }
        }
        let shot = try #require(image)
        #expect(shot.width == 600 && shot.height == 300, "about 3 pixels per point")
        // Color management tints pure blue a little (about 0.02, 0.2, 1 back in sRGB): compare, don't match.
        let center = try #require(NSBitmapImageRep(cgImage: shot).colorAt(x: 300, y: 150)?.usingColorSpace(.sRGB))
        #expect(center.blueComponent > 0.9 && center.blueComponent > center.greenComponent + 0.5
                    && center.blueComponent > center.redComponent + 0.5,
                "the blue box: the rect is read top-down (bottom-up would give the green one)")
        #expect(section == "Colors")
    }

    // MARK: notes PDFs

    @Test func notesAskQuotesTheSelectionElseRendersThePage() throws {
        let notes = try NotesPDF()
        defer { notes.remove() }
        let viewer = StudyPDFController()
        viewer.show(StudyPage(title: "L09 notes", path: notes.url.path), deckFile: "deck.pdf", slide: 1, follow: false)
        let doc = try #require(viewer.view.document)
        #expect(viewer.selectionQuote() == nil)

        let shot = try #require(viewer.pageImage())
        #expect(shot.page == 1)
        #expect(max(shot.image.width, shot.image.height) == Int(SlideImages.longEdge))

        let second = try #require(doc.page(at: 1))
        viewer.view.setCurrentSelection(second.selection(for: second.bounds(for: .cropBox)), animate: false)
        let quote = try #require(viewer.selectionQuote())
        #expect(quote.kind == "notes" && quote.source == "L09 notes" && quote.section == "page 2")
        #expect(quote.text.contains("rotation matrices"))

        let area = try #require(viewer.areaImage(page: second, rect: CGRect(x: 72, y: 690, width: 200, height: 40)))
        #expect(area.page == 2 && area.image.width == 800 && area.image.height == 160)
        #expect(viewer.areaImage(page: second, rect: CGRect(x: 2000, y: 2000, width: 50, height: 50)) == nil)
        #expect(viewer.areaImage(page: PDFPage(), rect: CGRect(x: 0, y: 0, width: 50, height: 50)) == nil)
    }
}

/// A study page in a temporary folder, in a nonpersistent WebKit view with the scripts the app injects. With
/// `handlers`, it records what the page posts to "clask" and "clnav" (otherwise a WalkthroughController can).
@MainActor
private final class AskPage: NSObject, WKScriptMessageHandler {
    let directory: URL
    let webView: WKWebView
    private(set) var asks: [[String: Any]] = []
    private(set) var turns: [Int] = []
    private let handlers: Bool
    var url: URL { directory.appendingPathComponent("Ask Fixture.html") }

    static let ready = "!!window.__coLearnerAsk && !!window.__coLearnerWT && document.readyState === 'complete'"
    static let buttonShown = "(function () { var h = document.querySelector('colearner-ask'); return !!h && getComputedStyle(h).display !== 'none'; })()"
    static let buttonState = """
        (function () {
          var h = document.querySelector('colearner-ask'), r = h.getBoundingClientRect();
          return {top: r.top, left: r.left, width: r.width, height: r.height, closed: h.shadowRoot === null,
                  text: h.textContent, hit: document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) === h};
        })()
        """

    init(html: String = AskPage.walkthrough, handlers: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoLearner-Ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        WalkthroughController.installPageScripts(in: config.userContentController)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        self.handlers = handlers
        super.init()
        try html.write(to: url, atomically: true, encoding: .utf8)
        if handlers {
            config.userContentController.add(self, name: "clask")
            config.userContentController.add(self, name: "clnav")
        }
    }

    func load() async throws {
        webView.loadFileURL(url, allowingReadAccessTo: directory)
        try await waitFor(Self.ready)
    }

    func close() {
        webView.stopLoading()
        if handlers {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "clask")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "clnav")
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func evaluate(_ script: String) async throws -> Any? { try await webView.evaluateJavaScript(script) }

    func string(_ script: String) async throws -> String { try await evaluate(script) as? String ?? "<not a string>" }

    /// An object result, through JSON (nil for null).
    func json(_ script: String) async throws -> [String: Any]? {
        let s = try await string("JSON.stringify(\(script))")
        return try JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) as? [String: Any]
    }

    /// Selects an element's text, scrolled into the middle of the view.
    func select(_ id: String) async throws {
        _ = try await evaluate("""
            (function () {
              var e = document.getElementById('\(id)'); e.scrollIntoView({block: 'center'});
              var r = document.createRange(); r.selectNodeContents(e);
              var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            })()
            """)
    }

    /// The end of a mouse selection, as the page sees it.
    func mouseUp(on id: String) async throws {
        _ = try await evaluate("document.getElementById('\(id)').dispatchEvent(new MouseEvent('mouseup', {bubbles: true, button: 0})); true")
    }

    func waitFor(_ condition: String) async throws {
        for _ in 0..<150 {
            if try await evaluate(condition) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Timeout(what: condition)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Timeout(what: "native condition")
    }

    struct Timeout: Error { let what: String }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        if message.name == "clask", let body = message.body as? [String: Any] { asks.append(body) }
        if message.name == "clnav", let d = message.body as? Int { turns.append(d) }
    }

    /// Sections, a subsection with a heading span, a sticky top bar, formulas as MathJax 3 and KaTeX leave them in
    /// the page (MathJax's records faked like 3.2.2's startup.document.math: a linked list that is only iterable,
    /// including a record of a formula no longer in the page), and things a reader doesn't see or that aren't text:
    /// an assistive copy of each formula, a hidden answer, a folded <details>, a button, a text field.
    nonisolated static let walkthrough = #"""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Ask fixture</title>
        <style>
          body { margin: 0; font: 16px/1.5 -apple-system, sans-serif; }
          .topnav { position: sticky; top: 0; height: 40px; background: #ddd; }
          section { padding: 0 20px; }
          mjx-container[display="true"] { display: block; text-align: center; }
          mjx-assistive-mml, .katex-mathml { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(1px, 1px, 1px, 1px); }
          .tall { height: 900px; }
        </style></head>
        <body>
        <nav class="topnav"><a href="#rot">Rotation</a> <a href="#hom">Homogeneous</a></nav>
        <main class="page">
        <header class="hero" id="top">
          <p class="eyebrow">Robotics · Lecture 1 · deck 01b</p>
          <h1>Fixture walkthrough</h1>
          <p id="lede">Hero text.</p>
        </header>
        <section class="topic" id="rot">
          <h2>Topic 3 · 2D rotation</h2>
          <p id="intro">A rotation <mjx-container class="MathJax" jax="SVG"><svg width="40" height="16"><text y="12">R</text></svg><mjx-assistive-mml><math><mi>R</mi><mo>(</mo><mi>θ</mi><mo>)</mo></math></mjx-assistive-mml></mjx-container> turns the plane.</p>
          <div class="sub" id="props">
            <h3>Properties</h3>
            <p id="p1">Its inverse is its transpose:</p>
            <mjx-container class="MathJax" jax="SVG" display="true"><svg width="80" height="20"></svg><mjx-assistive-mml display="block"><math><mi>R</mi></math></mjx-assistive-mml></mjx-container>
            <p id="p2">and <span class="katex"><span class="katex-mathml"><math><semantics><mrow><mn>1</mn></mrow><annotation encoding="application/x-tex">\det R = 1</annotation></semantics></math></span><span class="katex-html" aria-hidden="true">detR=1</span></span> always.</p>
            <p id="p4">Unlisted <mjx-container class="MathJax" jax="SVG"><svg width="10" height="10"></svg><mjx-assistive-mml><math><mi>x</mi></math></mjx-assistive-mml></mjx-container> math.</p>
            <h4>Composition</h4>
            <p id="p3">Rotations add angles.</p>
            <ul><li>first</li><li>second</li></ul>
            <table><tr><td>a</td><td>b</td></tr></table>
            <p id="hidden" hidden>Hidden answer</p>
            <details><summary>Show more</summary><p>Folded text</p></details>
            <button>Reset</button>
            <div class="tall"></div>
          </div>
          <p><input id="answer" value="cos theta"></p>
        </section>
        <section class="topic" id="hom">
          <h2>Topic 4 · Homogeneous transforms</h2>
          <div class="tall"><p id="h1">Stack rotation and translation.</p></div>
        </section>
        </main>
        <script>
          var c = document.querySelectorAll("mjx-container");
          var items = [
            { typesetRoot: c[0], math: "R(\\theta)", display: false },
            { typesetRoot: c[1], math: "R^{-1} = R^{\\top}", display: true },
            { typesetRoot: document.createElement("mjx-container"), math: "x_{stale}", display: false }
          ];
          var list = {};
          list[Symbol.iterator] = function* () { for (var i = 0; i < items.length; i++) yield items[i]; };
          window.MathJax = { startup: { document: { math: list } } };
        </script>
        </body></html>
        """#

    /// Colored boxes at known places in a section (in a 800 x 600 view, green is where blue's box would be if the
    /// capture rect were read from the bottom).
    nonisolated static let colors = """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>body { margin: 0; }</style></head>
        <body>
        <section class="topic" id="colors"><h2 style="margin: 0; height: 40px">Colors</h2>
          <div style="position: absolute; left: 0; top: 100px; width: 200px; height: 100px; background: rgb(255, 0, 0)"></div>
          <div style="position: absolute; left: 300px; top: 100px; width: 200px; height: 100px; background: rgb(0, 0, 255)"></div>
          <div style="position: absolute; left: 300px; top: 400px; width: 200px; height: 100px; background: rgb(0, 255, 0)"></div>
        </section>
        </body></html>
        """
}

/// A two-page notes PDF with real text, in a temporary folder.
private struct NotesPDF {
    let directory: URL
    var url: URL { directory.appendingPathComponent("notes.pdf") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoLearner-AskNotes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for text in ["First page of the notes", "Second page: rotation matrices"] {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)]))
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
