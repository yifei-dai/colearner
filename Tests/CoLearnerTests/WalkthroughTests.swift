import AppKit
import JavaScriptCore
import Testing
import WebKit
@testable import CoLearner

@Suite(.serialized)
@MainActor
struct WalkthroughTests {
    private func page(_ name: String, numbering: String? = nil, map: [String: Int]? = nil) -> StudyPage {
        StudyPage(title: name, path: "/tmp/colearner-tests/\(name).html", numbering: numbering, map: map)
    }

    private func fixture() -> (WalkthroughController, StubWalkthroughWebView) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = StubWalkthroughWebView(frame: .zero, configuration: config)
        return (WalkthroughController(webView: web), web)
    }

    private func settleDebounce() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test func interactiveWidgetsKeepArrowKeys() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var listener, captures = false, turns = [];
        var document = { activeElement: null, addEventListener: function(kind, fn, capture) {
          listener = fn; captures = !!capture;
        }};
        var window = { webkit: { messageHandlers: { clnav: { postMessage: function(n) { turns.push(n); } } } } };
        function press(tag, widget, handled, key, modifier, editable) {
          turns = [];
          document.activeElement = { tagName: tag, isContentEditable: !!editable,
            closest: function() { return widget ? this : null; } };
          var e = { key: key || 'ArrowRight', defaultPrevented: false, metaKey: !!modifier,
            preventDefault: function() { this.defaultPrevented = true; } };
          // A visual handles its key at the target, before the document's bubbling listener.
          if (captures) listener(e);
          if (handled) e.preventDefault();
          if (!captures) listener(e);
          return JSON.stringify(turns);
        }
        """)
        context.evaluateScript(WalkthroughController.arrowScript)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("captures")?.toBool() == false)
        for call in [
            "press('DIV', false, true)",   // Existing panorama/filter wrappers preventDefault.
            "press('DIV', true, false)",   // Mind-map tabindex nodes may expand without preventDefault.
            "press('CANVAS', false, false)", "press('svg', false, false)",
            "press('g', true, false)", "press('INPUT', false, false)",
            "press('TEXTAREA', false, false)", "press('SELECT', false, false)",
            "press('IFRAME', false, false)", "press('DIV', false, false, 'ArrowRight', false, true)",
            "press('BODY', false, false, 'ArrowRight', true)",
        ] {
            #expect(context.evaluateScript(call)?.toString() == "[]", "Widget key leaked: \(call)")
        }
        #expect(context.evaluateScript("press('BODY', false, false)")?.toString() == "[1]")
        #expect(context.evaluateScript("press('BODY', false, false, 'ArrowLeft')")?.toString() == "[-1]")
    }

    @Test func switchingPagesCancelsOldSlideRequest() async throws {
        let (controller, web) = fixture()
        controller.deckFile = "01a-first.pdf"
        controller.show(page("first"), slide: 1, follow: true)
        web.finishLoad(controller)
        web.scripts.removeAll()
        controller.show(page("first"), slide: 10, follow: true)
        controller.deckFile = "02a-second.pdf"
        controller.show(page("second"), slide: 2, follow: true)
        web.finishLoad(controller)
        try await settleDebounce()
        let calls = try web.scrollQueries()
        #expect(calls.count == 1)
        #expect(calls.first?["file"] as? String == "02a-second.pdf")
        #expect(calls.first?["page"] as? Int == 2)
    }

    @Test func sharedHTMLUsesNewDeckMetadataAndOnlyLatestSlide() async throws {
        let (controller, web) = fixture()
        controller.deckFile = "first.pdf"
        controller.show(page("shared", numbering: "plus1", map: ["3": 2]), slide: 2, follow: true)
        web.finishLoad(controller)
        web.scripts.removeAll()
        controller.show(page("shared"), slide: 10, follow: true)
        controller.deckFile = "second.pdf"
        controller.show(page("shared", numbering: "identity", map: ["7": 2]), slide: 2, follow: true)
        try await settleDebounce()
        let calls = try web.scrollQueries()
        #expect(web.navigations.count == 1)
        #expect(calls.count == 1)
        #expect(calls.first?["file"] as? String == "second.pdf")
        #expect(calls.first?["page"] as? Int == 7)
        #expect(calls.first?["numbering"] as? String == "identity")
        web.scripts.removeAll()
        controller.show(page("shared"), slide: 4, follow: true)
        try await settleDebounce()
        let restored = try #require(web.scrollQueries().first)
        #expect(restored["numbering"] == nil)
        #expect(restored["rebuild"] as? Bool == true)
    }

    @Test func clearingPageCancelsDebounceAndLateLoad() async throws {
        let (controller, web) = fixture()
        controller.show(page("first"), slide: 1, follow: true)
        web.finishLoad(controller)
        let oldNavigation = try #require(web.navigations.last)
        web.scripts.removeAll()
        controller.show(page("first"), slide: 10, follow: true)
        controller.show(nil, slide: 1, follow: false)
        controller.webView(web, didFinish: oldNavigation)
        try await settleDebounce()
        #expect(try web.scrollQueries().isEmpty)
        #expect(controller.loadedPath == nil)
        #expect(controller.sectionTitle == nil)
    }

    @Test func disablingFollowCancelsQueuedAndInFlightScrolling() async throws {
        let (controller, web) = fixture()
        controller.show(page("first"), slide: 1, follow: true)
        web.finishLoad(controller)
        web.scripts.removeAll()
        controller.show(page("first"), slide: 10, follow: true)
        controller.show(page("first"), slide: 10, follow: false)
        try await settleDebounce()
        #expect(try web.scrollQueries().isEmpty)
        #expect(web.scripts.contains { $0.contains("cancelPin()") })

        controller.show(page("second"), slide: 4, follow: true)
        controller.show(page("second"), slide: 4, follow: false)
        web.finishLoad(controller)
        #expect(try web.scrollQueries().isEmpty)

        controller.show(page("third"), slide: 8, follow: false)
        web.finishLoad(controller)
        #expect(try web.scrollQueries().isEmpty)
    }

    @Test func staleNavigationAndJavaScriptCallbacksCannotUpdateNewSelection() throws {
        let (controller, web) = fixture()
        controller.show(page("first"), slide: 1, follow: true)
        let oldNavigation = try #require(web.navigations.last)
        controller.show(page("second"), slide: 2, follow: true)
        controller.webView(web, didFinish: oldNavigation)
        #expect(web.scripts.isEmpty)
        web.finishLoad(controller)
        let oldReply = try #require(web.scrollCompletions.last)
        controller.show(page("third"), slide: 3, follow: true)
        oldReply(["ok": true, "title": "Old section", "match": "declared"], nil)
        #expect(controller.sectionTitle == nil)
        web.finishLoad(controller)
        let latestReply = try #require(web.scrollCompletions.last)
        latestReply(["ok": true, "title": "Current section", "match": "declared"], nil)
        #expect(controller.sectionTitle == "Current section")
    }
}

/// Records controller requests. Navigation identities come from an isolated view loading only inline
/// HTML: WKNavigation's inherited initializer does not initialize its underlying WebKit object.
@MainActor
private final class StubWalkthroughWebView: WKWebView {
    private lazy var navigationSource: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: config)
    }()
    var navigations: [WKNavigation] = []
    var scripts: [String] = []
    var scrollCompletions: [@MainActor (Any?, Error?) -> Void] = []

    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        let navigation = navigationSource.loadHTMLString("<!doctype html><title>Test navigation</title>", baseURL: nil)
        if let navigation { navigations.append(navigation) }
        return navigation
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }

    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor (Any?, Error?) -> Void)? = nil) {
        scripts.append(javaScriptString)
        if javaScriptString.contains(".index(") { completionHandler?(1, nil) }
        else if javaScriptString.contains(".go("), let completionHandler { scrollCompletions.append(completionHandler) }
    }

    func finishLoad(_ controller: WalkthroughController) {
        controller.webView(self, didFinish: navigations.last)
    }

    func scrollQueries() throws -> [[String: Any]] {
        try scripts.compactMap { script in
            guard let start = script.range(of: "__coLearnerWT.go("), let end = script.range(of: ") : null", options: .backwards) else { return nil }
            return try JSONSerialization.jsonObject(with: Data(script[start.upperBound..<end.lowerBound].utf8)) as? [String: Any]
        }
    }
}
