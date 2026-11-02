import SwiftUI
import WebKit
import PDFKit

/// Shows the deck's walkthrough / review page and keeps it scrolled to the section for the current slide.
@MainActor
final class WalkthroughController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var loadedPath: String?
    @Published private(set) var sectionTitle: String?
    @Published private(set) var coverage: String?
    private var page: StudyPage?
    private var pendingSlide: Int?
    private var ready = false
    private var debounce: DispatchWorkItem?
    private var generation = 0
    private var followsSlides = true
    private var loadingNavigation: WKNavigation?
    private var rebuildIndex = false
    private var crosshair = false

    override convenience init() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        Self.installPageScripts(in: config.userContentController)
        self.init(webView: PasteWebView(frame: .zero, configuration: config))
    }

    /// What runs inside every study page once it has loaded (main frame only): the section indexer, the arrow keys,
    /// and the "Ask about this" button (walkthrough_ask.js, which reads the indexer's sections).
    static func installPageScripts(in controller: WKUserContentController) {
        func add(_ source: String) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if let js = try? String(contentsOf: AppPaths.web.appendingPathComponent("walkthrough_index.js"), encoding: .utf8) { add(js) }
        add(arrowScript)
        if let js = try? String(contentsOf: AppPaths.web.appendingPathComponent("walkthrough_ask.js"), encoding: .utf8) { add(js) }
    }

    /// Accepting a web view also lets tests exercise navigation without loading real study pages.
    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(WeakNavHandler(self), name: "clnav")
        webView.configuration.userContentController.add(WeakAskHandler(self), name: "clask")
    }

    func show(_ p: StudyPage?, slide: Int, follow: Bool) {
        // Every selection supersedes pending work, including a different deck sharing this HTML file,
        // clearing the page, and turning Follow slides off while a load or scroll is still pending.
        debounce?.cancel()
        debounce = nil
        generation += 1
        pendingSlide = nil
        followsSlides = follow
        guard let p else {
            let hadPage = page != nil
            page = nil
            loadedPath = nil
            ready = false
            sectionTitle = nil
            coverage = nil
            if hadPage { loadingNavigation = webView.loadHTMLString("", baseURL: nil) }
            return
        }
        let numberingChanged = page?.numbering != p.numbering
        page = p   // A shared HTML file can have different numbering or a page map for each deck.
        if p.path != loadedPath {
            rebuildIndex = false
            ready = false
            loadedPath = p.path
            sectionTitle = nil
            coverage = nil
            pendingSlide = follow ? slide : nil
            let url = URL(fileURLWithPath: p.path)
            loadingNavigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        if numberingChanged { rebuildIndex = true }
        guard follow else {
            if ready { webView.evaluateJavaScript("window.__coLearnerWT && __coLearnerWT.cancelPin()", completionHandler: nil) }
            return
        }
        guard ready else { pendingSlide = slide; return }
        // Arrow-key bursts: only scroll for the slide the user stops on.
        let current = generation
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.goto(slide)
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    /// Study-page widgets get the keys first; unhandled arrows elsewhere turn the lecture slide.
    static let arrowScript = """
    document.addEventListener("keydown", function (e) {
      if (e.defaultPrevented || (e.key !== "ArrowLeft" && e.key !== "ArrowRight") || e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
      var a = document.activeElement;
      if (a && (/^(INPUT|TEXTAREA|SELECT|IFRAME|CANVAS|SVG)$/.test(a.tagName.toUpperCase()) || a.isContentEditable ||
                a.closest("svg, canvas, [tabindex]:not(a):not(button), [role='slider'], [role='tree'], [role='treeitem']"))) return;
      e.preventDefault();
      window.webkit.messageHandlers.clnav.postMessage(e.key === "ArrowLeft" ? -1 : 1);
    });
    """
    var onTurn: ((Int) -> Void)?

    /// The deck file name tells the indexer which deck's slides to match (one page can cover 01a and 01b).
    var deckFile: String = ""

    /// App slide number -> the page number the study page was written against.
    private func ref(for slide: Int) -> Int {
        guard let map = page?.map else { return slide }
        let hits = map.filter { $0.value == slide }.compactMap { Int($0.key) }.sorted()
        if let first = hits.first { return first }
        // No exact match (slide added in the new deck): the nearest earlier mapped slide.
        let earlier = map.filter { $0.value < slide }.max { $0.value < $1.value }
        return earlier.flatMap { Int($0.key) } ?? slide
    }

    func goto(_ slide: Int) {
        guard page != nil, followsSlides else { return }
        guard ready else { pendingSlide = slide; return }
        let current = generation
        var q: [String: Any] = ["file": deckFile, "page": ref(for: slide), "behavior": "smooth"]
        if let n = page?.numbering { q["numbering"] = n }
        // In particular, removing an explicit numbering override must restore the page's default.
        if rebuildIndex { q["rebuild"] = true; rebuildIndex = false }
        guard let data = try? JSONSerialization.data(withJSONObject: q), let arg = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__coLearnerWT ? __coLearnerWT.go(\(arg)) : null") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                if let d = result as? [String: Any], (d["ok"] as? Bool) == true {
                    let path = (d["path"] as? [String])?.filter { !$0.isEmpty } ?? []
                    var t = path.isEmpty ? (d["title"] as? String ?? "") : path.joined(separator: " › ")
                    let match = d["match"] as? String ?? ""
                    if !["declared", "cited", "mentioned"].contains(match) { t += "  (no section for this slide; nearest one)" }
                    self.sectionTitle = t
                } else {
                    self.sectionTitle = nil
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard page != nil, navigation === loadingNavigation else { return }
        ready = true
        if crosshair { showCrosshair(true) }
        let current = generation
        let options = page?.numbering.map { ["numbering": $0] } ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8)
        let numbering = String(decoding: data, as: UTF8.self)
        webView.evaluateJavaScript("window.__coLearnerWT ? __coLearnerWT.index(\(numbering)).entries.length : -1") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                if let n = result as? Int, n <= 0 {
                    self.coverage = "No slide-linked sections found on this page"
                }
                if let s = self.pendingSlide { self.pendingSlide = nil; self.goto(s) }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let u = action.request.url {
            // In-page anchors stay here; anything else opens in the browser.
            if u.isFileURL, u.path == loadedPath { decisionHandler(.allow); return }
            if ["http", "https"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: asking about the page

    /// A passage or section of the page to ask the chat about (the page's "Ask about this" button).
    var onAsk: ((ChatQuote) -> Void)?

    /// From the "clask" handler: only the page this controller loaded counts (not a page it navigated on to).
    fileprivate func receiveAsk(_ body: Any, from url: URL?) {
        guard let loadedPath, let url, url.isFileURL,
              url.resolvingSymlinksInPath().path == URL(fileURLWithPath: loadedPath).resolvingSymlinksInPath().path,
              let q = quote(from: body) else { return }
        onAsk?(q)
    }

    /// What the page sent, checked like any input from a web page: `text` a non-empty string (capped), `kind`
    /// "selection" or "section", `section` absent or a string (clipped to 300 characters). The source is the
    /// study page's title.
    func quote(from body: Any?) -> ChatQuote? {
        guard let page, !page.isPDF, let d = body as? [String: Any],
              let kind = d["kind"] as? String, kind == "selection" || kind == "section",
              let raw = d["text"] as? String else { return nil }
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatQuote.maxText))
        guard !text.isEmpty else { return nil }
        var section: String?
        switch d["section"] {
        case nil, is NSNull: break
        case let s as String:
            let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { section = s.count > 300 ? String(s.prefix(299)) + "…" : s }
        default: return nil
        }
        return ChatQuote(source: page.title, section: section, text: text, kind: kind)
    }

    /// The Ask button and menu item: the page's selection, else the section being read (nil when the page has
    /// neither, or changed meanwhile).
    func collectQuote(_ done: @escaping (ChatQuote?) -> Void) {
        guard let path = loadedPath else { done(nil); return }
        webView.evaluateJavaScript("window.__coLearnerAsk ? __coLearnerAsk.collect({hide: true}) : null") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, self.loadedPath == path else { done(nil); return }
                done(self.quote(from: result))
            }
        }
    }

    /// A picture of `rect` (web view coordinates, which are flipped like the page's) at about 3 pixels per point,
    /// and the section under its middle.
    func capture(_ rect: CGRect, _ done: @escaping (CGImage?, String?) -> Void) {
        let r = rect.intersection(webView.bounds)
        guard let path = loadedPath, r.width >= 4, r.height >= 4 else { done(nil, nil); return }
        let zoom = max(webView.pageZoom * webView.magnification, 0.01)
        let point = "\(Double(r.midX / zoom)), \(Double(r.midY / zoom))"
        // The "Ask about this" pill is put away first so the picture doesn't show it.
        let script = "window.__coLearnerAsk ? ((__coLearnerAsk.hide && __coLearnerAsk.hide()), __coLearnerAsk.sectionAt(\(point))) : ''"
        webView.evaluateJavaScript(script) { [weak self] found, _ in
            MainActor.assumeIsolated {
                guard let self, self.loadedPath == path else { done(nil, nil); return }
                let section = (found as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
                // The snapshot is drawn afresh at the requested width (pixels = width × the screen's scale), so small
                // print and formulas stay sharp; at most the attachment's long edge.
                let scale = self.webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                let perPoint = min(3, ImageAttachments.longEdge / max(r.width, r.height))
                let config = WKSnapshotConfiguration()
                config.rect = r
                config.snapshotWidth = NSNumber(value: Double(r.width * perPoint / scale))
                self.webView.takeSnapshot(with: config) { image, _ in
                    MainActor.assumeIsolated {
                        done(image?.cgImage(forProposedRect: nil, context: nil, hints: nil), section)
                    }
                }
            }
        }
    }

    /// While a box is dragged out over the page: a crosshair everywhere (the page sets its own cursor otherwise).
    /// Kept for a page that is still loading (selecting can start as the tab first comes up).
    func showCrosshair(_ on: Bool) {
        crosshair = on
        guard loadedPath != nil else { return }
        webView.evaluateJavaScript("window.__coLearnerAsk && __coLearnerAsk.crosshair(\(on))", completionHandler: nil)
    }
}

final class WeakNavHandler: NSObject, WKScriptMessageHandler {
    weak var target: WalkthroughController?
    init(_ t: WalkthroughController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let d = message.body as? Int, d == 1 || d == -1 else { return }
        MainActor.assumeIsolated { target?.onTurn?(d) }
    }
}

/// "Ask about this" on a study page. WebKit gives every frame the handler; only the page's main frame counts.
final class WeakAskHandler: NSObject, WKScriptMessageHandler {
    weak var target: WalkthroughController?
    init(_ t: WalkthroughController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        let body = message.body, url = message.frameInfo.request.url
        MainActor.assumeIsolated { target?.receiveAsk(body, from: url) }
    }
}

struct WalkthroughPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let pages = model.currentStudyPages
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if pages.count > 1 {
                    Picker("", selection: Binding(
                        get: { model.currentStudyPage?.path ?? "" },
                        set: { if let d = model.deck { model.selectedStudyPage[d.path] = $0 } })) {
                        ForEach(pages) { Text($0.title).tag($0.path) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                } else if let p = pages.first {
                    Text(p.title).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                // In a narrow pop-out (340 pt) the title gives way first; the controls keep their size.
                Button { model.askAboutWalkthrough() } label: {
                    Label("Ask", systemImage: "bubble.left").labelStyle(.titleAndIcon).padding(.horizontal, 5)
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .fixedSize()
                .help("Ask the chat about the selected text, or about the section you are reading (⇧⌘L)")
                .disabled(pages.isEmpty)
                Button { model.beginWalkthroughAreaSelection() } label: {
                    Image(systemName: "crop")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .fixedSize()
                .accessibilityLabel("Select an area of the walkthrough")
                .help("Drag a box over part of the walkthrough to ask about it (or ⌥-drag on it; ⌥⇧⌘A)")
                .disabled(pages.isEmpty)
                if !pages.isEmpty {
                    Toggle("Follow slides", isOn: $model.followSlides)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("Scroll to the section for the slide on screen")
                }
                Menu {
                    Button("Link a walkthrough page or notes PDF…") { model.linkStudyPagePanel() }
                    if !pages.isEmpty {
                        Divider()
                        ForEach(pages) { p in
                            Button("Unlink “\(p.title)”") { model.unlinkStudyPage(p) }
                        }
                    }
                    let gone = model.unlinkedStudyPages
                    if !gone.isEmpty {
                        Divider()
                        Menu("Link again") {
                            ForEach(gone) { p in Button(p.title) { model.relinkStudyPage(p) } }
                        }
                    }
                } label: {
                    Image(systemName: "link")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Link or unlink walkthrough pages and notes for this deck")
                .disabled(model.deck == nil || model.deck?.isWeb == true)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            if let p = model.currentStudyPage {
                if p.isPDF { PDFStatusLine(pdf: model.studyPDF) } else { SectionLine(walk: model.walk) }
            }
            Divider()
            if pages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "book.pages").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.deck == nil ? "Open a lecture first."
                         : model.deck!.isWeb ? "Walkthroughs go with lecture PDFs. Ask about this web page in the Chat tab."
                         : "No walkthrough is linked to \(model.deck!.title) yet.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let d = model.deck, !d.isWeb {
                        Button("Link a walkthrough page or notes PDF…") { model.linkStudyPagePanel() }
                        ForEach(model.unlinkedStudyPages) { p in
                            Button("Link “\(p.title)” again") { model.relinkStudyPage(p) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.currentStudyPage?.isPDF == true {
                StudyContentHost(view: model.studyPDF.view, selecting: model.selectingWalkthroughArea)
            } else {
                StudyContentHost(view: model.walk.webView, selecting: model.selectingWalkthroughArea)
            }
        }
        .onAppear { sync() }
        .onChange(of: model.page) { _, _ in sync() }
        .onChange(of: model.deckID) { _, _ in sync() }
        .onChange(of: model.currentStudyPage) { _, _ in sync() }
        .onChange(of: model.libraryRevision) { _, _ in sync() }
        .onChange(of: model.followSlides) { _, _ in sync() }
    }

    private func sync() {
        let deckFile = model.deck?.knownFile ?? ""
        if let p = model.currentStudyPage, p.isPDF {
            model.walk.show(nil, slide: model.page, follow: false)
            model.studyPDF.show(p, deckFile: model.deck?.scribeFile(p.path) ?? deckFile, slide: model.page, follow: model.followSlides)
        } else {
            model.walk.deckFile = deckFile
            model.walk.show(model.currentStudyPage, slide: model.page, follow: model.followSlides)
        }
    }
}

/// The walkthrough page or notes PDF, taken over the way PanelHost does (whichever host appears last holds the shared
/// view), with the area layer on top: it takes the mouse only while an area of the walkthrough is being selected
/// (Select Area of Walkthrough) or while ⌥ is held, and lets the page scroll meanwhile.
private struct StudyContentHost: NSViewRepresentable {
    @EnvironmentObject var model: AppModel
    let view: NSView
    /// Passed in so that SwiftUI updates the layer (crosshair, hint) when selecting starts and ends.
    let selecting: Bool

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        let overlay = AreaSelectView(hint: "Drag over the part of the walkthrough you want · Esc to cancel")
        overlay.frame = box.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.scrollTarget = view
        overlay.isActive = { [weak model] in model?.selectingWalkthroughArea ?? false }
        overlay.onSelect = { [weak model, weak overlay, weak view] r in
            guard let overlay, let view else { return }
            model?.finishWalkthroughAreaSelection(r, on: overlay, over: view)
        }
        box.addSubview(overlay)
        context.coordinator.overlay = overlay
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        context.coordinator.overlay?.refresh(selecting: selecting)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var overlay: AreaSelectView?
    }

    static func dismantleNSView(_ box: NSView, coordinator: Coordinator) {
        // The shared view is only still here if no other host has taken it.
        for v in box.subviews { v.removeFromSuperview() }
    }
}

/// "Showing: Topic 4 · Homogeneous transforms" under the page picker.
private struct SectionLine: View {
    @ObservedObject var walk: WalkthroughController
    var body: some View {
        if let s = walk.sectionTitle.map({ "Showing: " + $0 }) ?? walk.coverage {
            HStack {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}

private struct PDFStatusLine: View {
    @ObservedObject var pdf: StudyPDFController
    var body: some View {
        if let s = pdf.status {
            HStack {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}


