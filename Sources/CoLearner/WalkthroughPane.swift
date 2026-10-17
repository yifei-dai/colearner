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

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // The section indexer runs inside every study page once it has loaded.
        if let js = try? String(contentsOf: AppPaths.web.appendingPathComponent("walkthrough_index.js"), encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        config.userContentController.addUserScript(WKUserScript(source: Self.arrowScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        config.userContentController.add(WeakNavHandler(self), name: "clnav")
    }

    func show(_ p: StudyPage?, slide: Int, follow: Bool) {
        guard let p else {
            page = nil
            loadedPath = nil
            webView.loadHTMLString("", baseURL: nil)
            return
        }
        if p.path != loadedPath {
            page = p
            ready = false
            loadedPath = p.path
            sectionTitle = nil
            coverage = nil
            pendingSlide = slide
            let url = URL(fileURLWithPath: p.path)
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        guard follow else { return }
        // Arrow-key bursts: only scroll for the slide the user stops on.
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.goto(slide) }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    /// ← → on a study page turn the slide, unless a form control (e.g. a demo's slider) has focus.
    static let arrowScript = """
    document.addEventListener("keydown", function (e) {
      if ((e.key !== "ArrowLeft" && e.key !== "ArrowRight") || e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
      var a = document.activeElement;
      if (a && (/^(INPUT|TEXTAREA|SELECT|IFRAME)$/.test(a.tagName) || a.isContentEditable)) return;
      e.preventDefault();
      window.webkit.messageHandlers.clnav.postMessage(e.key === "ArrowLeft" ? -1 : 1);
    }, true);
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
        guard ready else { pendingSlide = slide; return }
        var q: [String: Any] = ["file": deckFile, "page": ref(for: slide), "behavior": "smooth"]
        if let n = page?.numbering { q["numbering"] = n }
        guard let data = try? JSONSerialization.data(withJSONObject: q), let arg = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__coLearnerWT ? __coLearnerWT.go(\(arg)) : null") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
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
        ready = true
        let numbering = page?.numbering.map { "{numbering: \"\($0)\"}" } ?? "{}"
        webView.evaluateJavaScript("window.__coLearnerWT ? __coLearnerWT.index(\(numbering)).entries.length : -1") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
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

}

final class WeakNavHandler: NSObject, WKScriptMessageHandler {
    weak var target: WalkthroughController?
    init(_ t: WalkthroughController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let d = message.body as? Int, d == 1 || d == -1 else { return }
        MainActor.assumeIsolated { target?.onTurn?(d) }
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
                if !pages.isEmpty {
                    Toggle("Follow slides", isOn: $model.followSlides)
                        .toggleStyle(.checkbox)
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
                .disabled(model.deck == nil)
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
                    Text(model.deck == nil ? "Open a lecture first." : "No walkthrough is linked to \(model.deck!.title) yet.")
                        .foregroundStyle(.secondary)
                    if model.deck != nil {
                        Button("Link a walkthrough page or notes PDF…") { model.linkStudyPagePanel() }
                        ForEach(model.unlinkedStudyPages) { p in
                            Button("Link “\(p.title)” again") { model.relinkStudyPage(p) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.currentStudyPage?.isPDF == true {
                PDFViewHost(view: model.studyPDF.view)
            } else {
                WebViewHost(view: model.walk.webView)
            }
        }
        .onAppear { sync() }
        .onChange(of: model.page) { _, _ in sync() }
        .onChange(of: model.deckID) { _, _ in sync() }
        .onChange(of: model.currentStudyPage?.path) { _, _ in sync() }
        .onChange(of: model.followSlides) { _, on in if on { sync() } }
    }

    private func sync() {
        let deckFile = model.deck?.url.lastPathComponent ?? ""
        if let p = model.currentStudyPage, p.isPDF {
            model.studyPDF.show(p, deckFile: deckFile, slide: model.page, follow: model.followSlides)
        } else {
            model.walk.deckFile = deckFile
            model.walk.show(model.currentStudyPage, slide: model.page, follow: model.followSlides)
        }
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

struct PDFViewHost: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
