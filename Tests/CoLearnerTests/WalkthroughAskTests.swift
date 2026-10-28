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
            Reset
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
        #expect(span?["text"] as? String == "Composition\nRotations add angles.\n- first\n- second\na | b\nShow more\nReset")

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

    @Test func scrollingHidesTheButtonUntilThePageIsStill() async throws {
        let page = try AskPage()
        defer { page.close() }
        try await page.load()
        try await page.select("p3")
        try await page.mouseUp(on: "p3")
        try await page.waitFor(AskPage.buttonShown)
        // Scroll events only hide it: placing it looks under it with hit tests, too slow for every event of a big page.
        let during = try await page.evaluate("""
            (function () {
              window.scrollBy(0, 30);
              for (var i = 0; i < 20; i++) window.dispatchEvent(new Event('scroll'));
              return getComputedStyle(document.querySelector('colearner-ask')).visibility;
            })()
            """) as? String
        #expect(during == "hidden")
        // Once the page is still, it is placed again, just below the line where the selection now ends.
        try await page.waitFor(AskPage.buttonShown)
        let state = try #require(try await page.json(AskPage.buttonState))
        let line = try #require(try await page.json("JSON.parse(JSON.stringify(getSelection().getRangeAt(0).getBoundingClientRect()))"))
        let top = try #require(state["top"] as? Double), bottom = try #require(line["bottom"] as? Double)
        #expect(state["hit"] as? Bool == true)
        #expect(top >= bottom && top <= bottom + 20)
        // The same after a resize.
        #expect(try await page.evaluate("""
            window.dispatchEvent(new Event('resize')); getComputedStyle(document.querySelector('colearner-ask')).visibility
            """) as? String == "hidden")
        try await page.waitFor(AskPage.buttonShown)
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

    // MARK: study pages as they are (checkpoints, demos, long sections, page macros)

    @Test func aSelectionOfOnlyFormulasCounts() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        // A drag across a display formula selects inside its container; MathJax's SVG has no text to show for it.
        let shown = try await page.evaluate("""
            (function () {
              var eq = document.querySelector('#derive mjx-container'); eq.scrollIntoView({block: 'center'});
              getSelection().setBaseAndExtent(eq, 0, eq, 1);
              return getSelection().toString();
            })()
            """) as? String
        #expect(shown == "")
        try await page.mouseUp(on: "derive")
        try await page.waitFor(AskPage.buttonShown)
        let one = try await page.json("__coLearnerAsk.collect()")
        #expect(one?["kind"] as? String == "selection")
        #expect(one?["text"] as? String == "$$x = 1$$")
        #expect(one?["section"] as? String == "Topic 2 · Notation")
        // Two stacked lines with only white space between them.
        _ = try await page.evaluate("""
            var c = document.querySelectorAll('#derive mjx-container'); getSelection().setBaseAndExtent(c[0], 0, c[1], 1); true
            """)
        #expect(try await page.evaluate("getSelection().toString().trim()") as? String == "")
        #expect(try await page.json("__coLearnerAsk.collect()")?["text"] as? String == "$$x = 1$$\n$$y = 2$$")
    }

    @Test func answerChoicesAndOtherButtonsKeepTheirText() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        // A choice's key and text sit side by side (the button is a flex row): "A. ...", with its math.
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('cp1'))") == #"""
            Checkpoint
            Which matrix undoes a rotation?
            A. Its transpose $R^{\top}$
            B. Its negative
            Check
            """#)
        // Selected from inside a choice; other flex rows keep a line per item.
        #expect(try await page.string("""
            (function () {
              var b = document.querySelector('#cp1 .q-opt'), r = document.createRange();
              r.setStart(b.querySelector('.k').firstChild, 0); r.setEnd(b.querySelector('.t').firstChild, 3);
              return __coLearnerAsk.textOf(r);
            })()
            """) == "A. Its")
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('q-1'))")
                == "Q1\nTopic 1 · Frames\nWhich is a rotation?")
    }

    @Test func supAndSubAreWrittenAsTeX() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('sup'))")
                == "The inverse is T^{−1} = [R^{T}, −R^{T}p]; error drops to 10^{-3} at x_{a}.")
    }

    @Test func aSelectionThatOnlyTouchesTheNextBlockLeavesItOut() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        func text(_ range: String) async throws -> String {
            try await page.string("(function () { var r = document.createRange(); \(range); return __coLearnerAsk.textOf(r); })()")
        }
        // Triple clicks end at the start of the next block: its display formula or list marker isn't selected.
        #expect(try await text("r.setStart(document.getElementById('tri').firstChild, 0); r.setEnd(document.querySelector('.eq mjx-container'), 0)")
                == "Only the frame's orientation matters.")
        #expect(try await text("r.setStart(document.getElementById('pre-list').firstChild, 0); r.setEnd(document.getElementById('li1'), 0)")
                == "See slides 8 to 10.")
        #expect(try await text("r.setStart(document.getElementById('pre-list').firstChild, 0); r.setEnd(document.getElementById('li1').firstChild, 0)")
                == "See slides 8 to 10.")
        // A drag from the margin after a list item starts at its very end.
        #expect(try await text("r.setStart(document.getElementById('li1'), 1); r.setEnd(document.getElementById('post-list').firstChild, 10)")
                == "Next line.")
        // As a selection: the formula's macros don't come along either.
        _ = try await page.evaluate("""
            var t = document.getElementById('tri'); t.scrollIntoView({block: 'center'});
            getSelection().setBaseAndExtent(t.firstChild, 0, document.querySelector('.eq mjx-container'), 0); true
            """)
        #expect(try await page.json("__coLearnerAsk.collect()")?["text"] as? String == "Only the frame's orientation matters.")
    }

    @Test func aLongSectionIsQuotedFromThePartOnScreen() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('long-sub'), 20000)").count > 6000)
        // Paragraph 25 starts just below the 40 px top bar: far past the first 6000 characters of the subsection.
        _ = try await page.evaluate("window.scrollTo(0, document.getElementById('l25').getBoundingClientRect().top + pageYOffset - 41); true")
        let long = try #require(try await page.json("__coLearnerAsk.collect()"))
        #expect(long["kind"] as? String == "section")
        #expect(long["section"] as? String == "Topic 3 · A long section › Many paragraphs")
        let text = try #require(long["text"] as? String)
        #expect(text.hasPrefix("Many paragraphs\n…\nParagraph 25: lorem ipsum"), "its title, then from the first paragraph on screen")
        #expect(text.contains("Paragraph 30: ") && !text.contains("Paragraph 24: ") && text.count <= 6000)

        // A section that fits is quoted whole, even with its heading under the top bar.
        _ = try await page.evaluate("""
            window.scrollTo(0, document.querySelector('#notation h2').getBoundingClientRect().bottom + pageYOffset - 30); true
            """)
        let short = try #require(try await page.json("__coLearnerAsk.collect()"))
        #expect(short["section"] as? String == "Topic 2 · Notation")
        #expect((short["text"] as? String)?.hasPrefix("Topic 2 · Notation\nThe inverse is T^{−1}") == true)
    }

    @Test func aSelectionScrolledOutOfViewGivesWayToTheSectionOnScreen() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        try await page.select("tri")
        try await page.mouseUp(on: "tri")
        try await page.waitFor(AskPage.buttonShown)
        #expect(try await page.json("__coLearnerAsk.collect()")?["kind"] as? String == "selection")
        // The page moves on (Follow slides scrolls it): the button hides, and can't be clicked where it was.
        _ = try await page.evaluate("window.scrollTo(0, document.getElementById('l10').getBoundingClientRect().top + pageYOffset - 41); true")
        try await page.waitFor("getComputedStyle(document.querySelector('colearner-ask')).visibility === 'hidden'")
        #expect(try await page.json(AskPage.buttonState)?["hit"] as? Bool == false)
        let quote = try await page.json("__coLearnerAsk.collect()")
        #expect(quote?["kind"] as? String == "section")
        #expect(quote?["section"] as? String == "Topic 3 · A long section › Many paragraphs")
        #expect(try await page.evaluate("getSelection().toString()") as? String == "Only the frame's orientation matters.")
        // Text in the sticky top bar is on screen although it sits above the bar's bottom edge.
        _ = try await page.evaluate("""
            var r = document.createRange(); r.selectNodeContents(document.querySelector('.topnav a'));
            getSelection().removeAllRanges(); getSelection().addRange(r); true
            """)
        let bar = try await page.json("__coLearnerAsk.collect()")
        #expect(bar?["kind"] as? String == "selection" && bar?["text"] as? String == "Checkpoints")
    }

    @Test func buttonKeepsOffControlsAndStaysAwayOnceDismissed() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        // A checkpoint's question: the answer choices are right below its line, so the button goes above it.
        try await page.select("cpq")
        try await page.mouseUp(on: "cpq")
        try await page.waitFor(AskPage.buttonShown)
        let state = try #require(try await page.json(AskPage.buttonState))
        #expect(state["hit"] as? Bool == true)
        let covered = try await page.evaluate("""
            (function () {
              var b = document.querySelector('colearner-ask').getBoundingClientRect();
              return Array.from(document.querySelectorAll('#cp1 button')).filter(function (x) {
                var r = x.getBoundingClientRect();
                return r.left < b.right && b.left < r.right && r.top < b.bottom && b.top < r.bottom;
              }).length;
            })()
            """) as? Int
        #expect(covered == 0, "no answer choice under the button")
        let line = try #require(try await page.json("JSON.parse(JSON.stringify(getSelection().getRangeAt(0).getBoundingClientRect()))"))
        let top = try #require(state["top"] as? Double), height = try #require(state["height"] as? Double)
        #expect(abs(top + height + 6 - (try #require(line["top"] as? Double))) < 1, "just above the line")

        // Answering (WebKit keeps the selection when a button is clicked): the button doesn't come back.
        _ = try await page.evaluate("""
            var b = document.querySelectorAll('#cp1 .q-opt')[1];
            ['mousedown', 'mouseup', 'click'].forEach(function (t) { b.dispatchEvent(new MouseEvent(t, {bubbles: true, button: 0})); });
            true
            """)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == false)
        #expect(try await page.evaluate("getSelection().toString()") as? String == "Which matrix undoes a rotation?")

        // A new selection brings it back; the app's hide() sends it away the same way.
        try await page.select("tri")
        try await page.mouseUp(on: "tri")
        try await page.waitFor(AskPage.buttonShown)
        #expect(try await page.evaluate("__coLearnerAsk.hide()") as? Bool == true)
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == false)
        try await page.mouseUp(on: "tri")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == false)
        #expect(page.asks.isEmpty)
    }

    @Test func quotesEndWithThePageMacrosTheyUse() async throws {
        let page = try AskPage(html: AskPage.practice)
        defer { page.close() }
        try await page.load()
        // The definitions of the macros used, then of those they use; none the quote doesn't use.
        try await page.select("macro")
        #expect(try await page.json("__coLearnerAsk.collect()")?["text"] as? String == #"""
            Turn with $\Rot(R)\,\Trans(d)$, then $\bm{p}\Qfree$.

            Macros used above (defined by this page): \Rot = \operatorname{Rot}; \Trans = \operatorname{Trans}; \bm{#1} = \boldsymbol{#1}; \Qfree = \Qsp_{\text{free}}; \Qsp = \mathcal{Q}
            """#)
        try await page.select("cpq")
        #expect(try await page.json("__coLearnerAsk.collect()")?["text"] as? String == "Which matrix undoes a rotation?")
        // Before MathJax has started, window.MathJax is still the page's configuration.
        _ = try await page.evaluate(#"window.__mj = window.MathJax; window.MathJax = { tex: { macros: { tp: '^{\\top}' } } }; true"#)
        try await page.select("raw")
        #expect(try await page.json("__coLearnerAsk.collect()")?["text"] as? String
                == #"Before typesetting: $v\tp$"# + "\n\n" + #"Macros used above (defined by this page): \tp = ^{\top}"#)
        // A page without MathJax: no line.
        _ = try await page.evaluate("delete window.MathJax; true")
        #expect(try await page.json("__coLearnerAsk.collect()")?["text"] as? String == #"Before typesetting: $v\tp$"#)
    }

    @Test func checkedAnswersAreQuotedWithTheStudentsAnswerAndThePagesMarks() async throws {
        let page = try AskPage(html: AskPage.more)
        defer { page.close() }
        try await page.load()
        func text(_ id: String) async throws -> String {
            try await page.string("__coLearnerAsk.textOf(document.getElementById('\(id)'))")
        }
        #expect(try await text("mc") == "Checkpoint\nWhich pair fits a Roomba?\nA. Mobile, wheeled\nB. Fixed manipulator\nC. Airborne")
        // Picking C: the page marks it wrong and A right, and its feedback only points at the colors.
        _ = try await page.evaluate("document.querySelectorAll('#mc .q-opt')[2].click(); true")
        #expect(try await text("mc") == """
            Checkpoint
            Which pair fits a Roomba?
            A. Mobile, wheeled (correct answer)
            B. Fixed manipulator
            C. Airborne (the student's answer)
            Not quite. The highlighted option is right.
            """)
        // Typed answers: what is in each box, then how the page marked it once checked (an empty box it marked too).
        #expect(try await text("num") == "Checkpoint\nWhere is the point in {b}?\nfirst entry\nsecond entry\nCheck")
        _ = try await page.evaluate("document.getElementById('num-x').value = ' 3 '; document.querySelector('#num [data-check]').click(); true")
        #expect(try await text("num") == """
            Checkpoint
            Where is the point in {b}?
            first entry
            [3] (marked right)
            second entry
            [] (marked wrong)
            Check
            Not yet. Red boxes are off.
            """)
        // A box in a sentence, typed but not checked; checkboxes are still left out.
        #expect(try await text("inline") == "The step is long, rounded.")
        _ = try await page.evaluate("document.getElementById('step').value = '2.5'; true")
        #expect(try await text("inline") == "The step is [2.5] long, rounded.")
        // As a selection, the way the button sends it.
        try await page.select("mc")
        #expect((try await page.json("__coLearnerAsk.collect()")?["text"] as? String)?.contains("C. Airborne (the student's answer)") == true)
    }

    @Test func listingsKeepTheirLineNumbersAndIndentation() async throws {
        let page = try AskPage(html: AskPage.more)
        defer { page.close() }
        try await page.load()
        // counter(ln), with a comment line that isn't numbered (lines are counted as the page draws them).
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('min'))") == """
            /* the child with the lowest utility */
            1  function MINIMIZE(state)
            2    if TERMINAL-TEST(state):
            3      return ⟨NULL, EVAL(state)⟩
            """)
        #expect(try await page.string("""
            (function () {
              var li = document.querySelectorAll('#min li'), r = document.createRange();
              r.setStartBefore(li[2]); r.setEndAfter(li[3]);
              return __coLearnerAsk.textOf(r);
            })()
            """) == "2    if TERMINAL-TEST(state):\n3      return ⟨NULL, EVAL(state)⟩")
        // attr(data-l) and padding steps: two spaces a step beyond the least indented numbered line.
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('merge'))") == """
            Input: two trees
            1  for i = 1 to ℓ do
            2    extend T_{1}
            First, extend one tree
            3      return merged
            6, 7    swap the trees
            8  return failure
            """)
    }

    @Test func calloutLabelsAreSetOffFromTheirText() async throws {
        let page = try AskPage(html: AskPage.more)
        defer { page.close() }
        try await page.load()
        #expect(try await page.string("__coLearnerAsk.textOf(document.getElementById('trap'))")
                == "Trap Do not subtract the origin from a velocity, undo it.")
    }

    @Test func sectionPathKeepsMathInHeadingsAsTeX() async throws {
        let page = try AskPage(html: AskPage.more)
        defer { page.close() }
        try await page.load()
        #expect(try await page.string("__coLearnerAsk.sectionOf(document.getElementById('cost'))")
                == "Topic 3 · Minimax › Cost of minimax › Where $b^m$ and $bm$ come from")
        try await page.select("cost")
        let quote = try await page.json("__coLearnerAsk.collect()")
        #expect(quote?["section"] as? String == "Topic 3 · Minimax › Cost of minimax › Where $b^m$ and $bm$ come from")
        // The index keeps its plain titles (matching slides and the "Showing:" line use them).
        #expect(try await page.string("""
            __coLearnerWT.index().entries.filter(function (e) { return e.kind === 'heading' && /^Where/.test(e.title); })[0].title
            """) == "Where bm and bm come from")
        // A page macro in a title is defined at the end of the quote, like one in the text.
        _ = try await page.evaluate(#"items[0].math = '\\bm{b}^m'; MathJax.config = { tex: { macros: { bm: ['\\boldsymbol{#1}', 1] } } }; true"#)
        let macro = try await page.json("__coLearnerAsk.collect()")
        #expect(macro?["section"] as? String == #"Topic 3 · Minimax › Cost of minimax › Where $\bm{b}^m$ and $bm$ come from"#)
        #expect(macro?["text"] as? String == "A uniform tree of depth m has many leaves.\n\n"
                + #"Macros used above (defined by this page): \bm{#1} = \boldsymbol{#1}"#)
    }

    @Test func labelsOfAFigureAloneAreNoSelection() async throws {
        let page = try AskPage(html: AskPage.more)
        defer { page.close() }
        try await page.load()
        // A drag that misses a demo's handle selects the drawing's labels: they have text to copy, but no button
        // comes up and Ask quotes the section being read.
        let copied = try await page.evaluate("""
            (function () {
              var plot = document.getElementById('plot'), t = plot.querySelectorAll('text');
              plot.scrollIntoView({block: 'center'});
              getSelection().setBaseAndExtent(plot, 0, t[2].firstChild, 1);
              return getSelection().toString().trim();
            })()
            """) as? String
        #expect(copied?.isEmpty == false)
        try await page.mouseUp(on: "plot")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == false)
        #expect(try await page.json("__coLearnerAsk.collect()")?["kind"] as? String == "section")
        // Inside one label.
        _ = try await page.evaluate("var t = document.querySelector('#plot text').firstChild; getSelection().setBaseAndExtent(t, 0, t, 3); true")
        try await page.mouseUp(on: "plot")
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await page.evaluate(AskPage.buttonShown) as? Bool == false)
        #expect(try await page.json("__coLearnerAsk.collect()")?["kind"] as? String == "section")
        // From the drawing into its caption: the caption is the quote.
        _ = try await page.evaluate("""
            var q = document.querySelectorAll('#plot text')[2].firstChild, cap = document.getElementById('cap').firstChild;
            getSelection().setBaseAndExtent(q, 0, cap, cap.length); true
            """)
        try await page.mouseUp(on: "cap")
        try await page.waitFor(AskPage.buttonShown)
        #expect(try await page.json("__coLearnerAsk.collect()")?["text"] as? String == "Drag the round handle.")
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
    /// Up and visible: not hidden while the page scrolls or with its selection scrolled away.
    static let buttonShown = """
        (function () {
          var h = document.querySelector('colearner-ask'), cs = h && getComputedStyle(h);
          return !!h && cs.display !== 'none' && cs.visibility !== 'hidden';
        })()
        """
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

    /// Selects an element's text, scrolled into the middle of the view, once the page has had the scroll event (a
    /// scroll hides the button until the page is still, and one landing after it showed would hide it again).
    func select(_ id: String) async throws {
        _ = try await evaluate("""
            (function () {
              var e = document.getElementById('\(id)'), y = pageYOffset;
              window.__scrolled = false;
              e.scrollIntoView({block: 'center'});
              if (pageYOffset === y) window.__scrolled = true;
              else window.addEventListener('scroll', function () { window.__scrolled = true; }, {once: true});
              var r = document.createRange(); r.selectNodeContents(e);
              var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            })()
            """)
        try await waitFor("window.__scrolled === true")
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
    /// including a record of a formula no longer in the page), things a reader doesn't see or that aren't text (an
    /// assistive copy of each formula, a hidden answer, a folded <details>, a text field) and a button, whose text is.
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

    /// What real study pages have that the fixture above doesn't: a checkpoint (answer choices are flex-row buttons with
    /// a key, one with a formula, then a Check button) and a quiz card head, <sup>/<sub> in prose, a paragraph followed
    /// by a display formula and one by a list, formulas that use the page's own macros (MathJax.config.tex.macros),
    /// stacked display formulas, raw TeX not yet typeset, and a subsection of 30 paragraphs (over 9000 characters).
    /// MathJax's assistive copies can't be selected, as on real pages.
    nonisolated static let practice = #"""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Ask practice fixture</title>
        <style>
          body { margin: 0; font: 16px/1.5 -apple-system, sans-serif; }
          .topnav { position: sticky; top: 0; height: 40px; background: #ddd; }
          section { padding: 0 20px; }
          mjx-container[display="true"] { display: block; text-align: center; }
          mjx-assistive-mml { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(1px, 1px, 1px, 1px);
            -webkit-user-select: none; user-select: none; }
          .cp-opts { display: grid; gap: 8px; }
          .q-opt { display: flex; gap: 12px; align-items: baseline; width: 100%; text-align: left; font: inherit; padding: 10px 12px; }
          .q-head { display: flex; gap: 10px; }
          .tall { height: 900px; }
        </style></head>
        <body>
        <nav class="topnav"><a href="#cp">Checkpoints</a> <a href="#long">Long</a></nav>
        <main>
        <section class="topic" id="cp">
          <h2>Topic 1 · Checkpoints</h2>
          <div class="cp" id="cp1">
            <p class="cp-h">Checkpoint</p>
            <p class="cp-q" id="cpq">Which matrix undoes a rotation?</p>
            <div class="cp-opts">
              <button class="q-opt" type="button"><span class="k">A</span><span class="t">Its transpose <mjx-container class="MathJax" jax="SVG"><svg width="30" height="16"></svg><mjx-assistive-mml><math><mi>R</mi></math></mjx-assistive-mml></mjx-container></span></button>
              <button class="q-opt" type="button"><span class="k">B</span><span class="t">Its negative</span></button>
            </div>
            <div class="cp-row"><button class="btn" type="button">Check</button></div>
          </div>
          <article class="q" id="q-1"><div class="q-head"><span class="q-num">Q1</span><span class="q-tag">Topic 1 · Frames</span></div>
            <p class="q-text">Which is a rotation?</p></article>
        </section>
        <section class="topic" id="notation">
          <h2>Topic 2 · Notation</h2>
          <p id="sup">The inverse is T<sup>−1</sup> = [R<sup>T</sup>, −R<sup>T</sup>p]; error drops to 10<sup>-3</sup> at x<sub>a</sub>.</p>
          <p id="tri">Only the frame's orientation matters.</p>
          <div class="eq"><mjx-container class="MathJax" jax="SVG" display="true"><svg width="80" height="20"></svg><mjx-assistive-mml display="block"><math><mi>v</mi></math></mjx-assistive-mml></mjx-container></div>
          <p id="pre-list">See slides 8 to 10.</p>
          <ul><li id="li1">first item</li></ul>
          <p id="post-list">Next line.</p>
          <p id="macro">Turn with <mjx-container class="MathJax" jax="SVG"><svg width="60" height="16"></svg><mjx-assistive-mml><math><mi>T</mi></math></mjx-assistive-mml></mjx-container>, then <mjx-container class="MathJax" jax="SVG"><svg width="30" height="16"></svg><mjx-assistive-mml><math><mi>p</mi></math></mjx-assistive-mml></mjx-container>.</p>
          <div class="derive" id="derive"><mjx-container class="MathJax" jax="SVG" display="true"><svg width="60" height="20"></svg><mjx-assistive-mml display="block"><math><mi>x</mi></math></mjx-assistive-mml></mjx-container>
          <mjx-container class="MathJax" jax="SVG" display="true"><svg width="60" height="20"></svg><mjx-assistive-mml display="block"><math><mi>y</mi></math></mjx-assistive-mml></mjx-container></div>
          <p id="raw">Before typesetting: $v\tp$</p>
        </section>
        <section class="topic" id="long">
          <h2>Topic 3 · A long section</h2>
          <div class="sub" id="long-sub"><h3>Many paragraphs</h3></div>
        </section>
        <div class="tall"></div>
        </main>
        <script>
          var sub = document.getElementById("long-sub");
          for (var i = 1; i <= 30; i++) {
            var p = document.createElement("p");
            p.id = "l" + i;
            p.textContent = "Paragraph " + i + ": " + "lorem ipsum dolor sit amet ".repeat(11).trim();
            sub.appendChild(p);
          }
          var c = document.querySelectorAll("mjx-container");
          var items = [
            { typesetRoot: c[0], math: "R^{\\top}", display: false },
            { typesetRoot: c[1], math: "v^b = R(\\theta)\\tp\\, v^a", display: true },
            { typesetRoot: c[2], math: "\\Rot(R)\\,\\Trans(d)", display: false },
            { typesetRoot: c[3], math: "\\bm{p}\\Qfree", display: false },
            { typesetRoot: c[4], math: "x = 1", display: true },
            { typesetRoot: c[5], math: "y = 2", display: true }
          ];
          var list = {};
          list[Symbol.iterator] = function* () { for (var i = 0; i < items.length; i++) yield items[i]; };
          window.MathJax = {
            config: { tex: { macros: { tp: "^{\\top}", Rot: "\\operatorname{Rot}", Trans: "\\operatorname{Trans}",
              bm: ["\\boldsymbol{#1}", 1], Qsp: "\\mathcal{Q}", Qfree: "\\Qsp_{\\text{free}}", unused: "\\text{never}" } } },
            startup: { document: { math: list } }
          };
        </script>
        </body></html>
        """#

    /// More of what study pages have: checkpoints whose own script marks the answer (copied from the pages: the right
    /// choice gets .correct, a wrong pick .wrong, a checked box .good or .wrongc), a text box in a sentence, a callout
    /// label set off by its margin, pseudocode listings numbered with CSS (counter() with an unnumbered comment line,
    /// attr(data-l) with padding steps, a caption and a less indented Input line), a heading with formulas, and a demo
    /// figure whose SVG labels can be selected.
    nonisolated static let more = #"""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Ask more fixture</title>
        <style>
          body { margin: 0; font: 16px/1.5 -apple-system, sans-serif; }
          .topnav { position: sticky; top: 0; height: 40px; background: #ddd; }
          section { padding: 0 20px; }
          mjx-assistive-mml { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(1px, 1px, 1px, 1px);
            -webkit-user-select: none; user-select: none; }
          .cp-opts { display: grid; gap: 8px; }
          .q-opt { display: flex; gap: 12px; align-items: baseline; width: 100%; text-align: left; font: inherit; padding: 10px 12px; }
          .cp-row { display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: center; }
          .num-in { width: 5em; }
          .tl { font-weight: 700; margin-right: 8px; }
          ol.pseudo { list-style: none; counter-reset: ln; padding: 0; font: 13.5px/1.6 monospace; }
          ol.pseudo li { counter-increment: ln; position: relative; padding-left: 3.6em; white-space: pre; }
          ol.pseudo li::before { content: counter(ln); position: absolute; left: 0; width: 2.4em; text-align: right; }
          ol.pseudo li:first-child { counter-increment: none; white-space: normal; }
          ol.pseudo li:first-child::before { content: none; }
          ol.code { list-style: none; padding: 0; font-size: 14px; }
          ol.code li { position: relative; padding-left: 2.6em; }
          ol.code li[data-l]::before { content: attr(data-l); position: absolute; left: 0.5em; }
          ol.code li.io { padding-left: 10px; }
          ol.code li.in1 { padding-left: 3.6em; }
          ol.code li.in2 { padding-left: 4.6em; }
          ol.code .cap { display: block; font-style: italic; }
          .tall { height: 900px; }
        </style></head>
        <body>
        <nav class="topnav"><a href="#check">Checkpoints</a> <a href="#code">Listings</a></nav>
        <main>
        <section class="topic" id="check">
          <h2>Topic 1 · Checkpoints</h2>
          <div class="cp" data-cp="mc" data-ans="0" id="mc">
            <p class="cp-h">Checkpoint</p>
            <p class="cp-q">Which pair fits a Roomba?</p>
            <div class="cp-opts">
              <button class="q-opt" type="button"><span class="k">A</span><span class="t">Mobile, wheeled</span></button>
              <button class="q-opt" type="button"><span class="k">B</span><span class="t">Fixed manipulator</span></button>
              <button class="q-opt" type="button"><span class="k">C</span><span class="t">Airborne</span></button>
            </div>
            <div class="cp-fb" hidden><p class="verdict"></p></div>
          </div>
          <div class="cp" data-cp="num" data-ans="3,-1" id="num">
            <p class="cp-h">Checkpoint</p>
            <p class="cp-q">Where is the point in {b}?</p>
            <div class="cp-row">
              <label class="ctl-label" for="num-x">first entry</label><input class="num-in" id="num-x" autocomplete="off">
              <label class="ctl-label" for="num-y">second entry</label><input class="num-in" id="num-y" autocomplete="off">
              <button class="btn" type="button" data-check>Check</button>
            </div>
            <div class="cp-fb" hidden><p class="verdict"></p></div>
          </div>
          <p id="inline">The step is <input class="num-in" id="step"> long, <input type="checkbox" checked> rounded.</p>
          <p class="trap" id="trap"><span class="tl">Trap</span>Do not subtract the origin from a velocity, <span>un</span>do it.</p>
        </section>
        <section class="topic" id="code">
          <h2>Topic 2 · Listings</h2>
          <ol class="pseudo" id="min">
            <li>/* the child with the lowest utility */</li>
            <li>function MINIMIZE(state)</li>
            <li>  if TERMINAL-TEST(state):</li>
            <li>    return ⟨NULL, EVAL(state)⟩</li>
          </ol>
          <ol class="code" id="merge">
            <li class="io">Input: two trees</li>
            <li data-l="1">for i = 1 to ℓ do</li>
            <li data-l="2" class="in1">extend T<sub>1</sub><span class="cap">First, extend one tree</span></li>
            <li data-l="3" class="in2">return merged</li>
            <li data-l="6, 7" class="in1">swap the trees</li>
            <li data-l="8">return failure</li>
          </ol>
        </section>
        <section class="topic" id="figs">
          <h2>Topic 3 · Minimax</h2>
          <div class="sub" id="cost-sub">
            <h3>Cost of minimax</h3>
            <h4>Where <mjx-container class="MathJax" jax="SVG"><svg width="20" height="16"></svg><mjx-assistive-mml><math><msup><mi>b</mi><mi>m</mi></msup></math></mjx-assistive-mml></mjx-container> and <mjx-container class="MathJax" jax="SVG"><svg width="20" height="16"></svg><mjx-assistive-mml><math><mi>b</mi><mi>m</mi></math></mjx-assistive-mml></mjx-container> come from</h4>
            <p id="cost">A uniform tree of depth m has many leaves.</p>
            <figure class="fig" id="demo">
              <div class="plot" id="plot"><svg width="300" height="120"><circle cx="40" cy="60" r="8"></circle><text x="70" y="40">{c}</text><text x="70" y="80">p</text><text x="140" y="80">q</text></svg></div>
              <figcaption id="cap">Drag the round handle.</figcaption>
            </figure>
          </div>
        </section>
        <div class="tall"></div>
        </main>
        <script>
          document.querySelectorAll(".cp[data-cp]").forEach(function (cp) {
            var fb = cp.querySelector(".cp-fb"), verdict = cp.querySelector(".verdict");
            function say(msg) { fb.hidden = false; verdict.textContent = msg; }
            if (cp.dataset.cp === "mc") {
              var ans = +cp.dataset.ans, btns = Array.from(cp.querySelectorAll(".cp-opts .q-opt"));
              btns.forEach(function (b, j) {
                b.addEventListener("click", function () {
                  btns.forEach(function (x) { x.disabled = true; x.classList.remove("correct", "wrong"); });
                  btns[ans].classList.add("correct");
                  if (j !== ans) b.classList.add("wrong");
                  say(j === ans ? "Correct." : "Not quite. The highlighted option is right.");
                });
              });
            } else {
              var want = cp.dataset.ans.split(",").map(Number), ins = Array.from(cp.querySelectorAll("input.num-in"));
              cp.querySelector("[data-check]").addEventListener("click", function () {
                var ok = true;
                ins.forEach(function (inp, i) {
                  var good = inp.value.trim() !== "" && Number(inp.value) === want[i];
                  inp.classList.toggle("good", good); inp.classList.toggle("wrongc", !good);
                  if (!good) ok = false;
                });
                say(ok ? "Correct." : "Not yet. Red boxes are off.");
              });
            }
          });
          var c = document.querySelectorAll("mjx-container");
          var items = [{ typesetRoot: c[0], math: "b^m", display: false }, { typesetRoot: c[1], math: "bm", display: false }];
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
