import SwiftUI
import WebKit
import CryptoKit

// MARK: - addresses

/// Web pages in a web tab: what a typed address means and which book a page belongs to. A web book is a deck whose
/// path is its address (`Deck.isWeb`): one tab and one conversation per book, across the pages read in it.
enum WebAddress {
    static func isWeb(_ path: String) -> Bool { path.hasPrefix("https://") || path.hasPrefix("http://") }

    /// A typed or pasted address as a web URL ("https://" added when it has no scheme); nil if it isn't one.
    static func parse(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            if s.contains("://") || lower.hasPrefix("file:") || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") { return nil }
            s = "https://" + s
        }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty, host.contains(".") || host == "localhost" else { return nil }
        return u
    }

    /// The page a URL shows: without its #fragment.
    static func pageKey(_ u: URL) -> String {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u.absoluteString }
        c.fragment = nil
        return c.url?.absoluteString ?? u.absoluteString
    }

    /// The book a page belongs to: its site and first folder ("https://textbooks.math.gatech.edu/ila/" for
    /// ".../ila/linear-transformations.html", ".../ila/" or ".../ila"), or the site alone for a file at its top level.
    /// Applied to a book's own address it gives that address back. (WebBooks.bookID(for:) prefers a book read before.)
    static func bookID(_ u: URL) -> String {
        guard let c = URLComponents(url: u, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty else { return pageKey(u) }
        var root = scheme + "://" + host
        if let port = c.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) { root += ":\(port)" }
        let path = c.percentEncodedPath
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        // A first folder: "/ila/linear-transformations.html", "/ila/", or "/ila" (no file extension: a folder).
        if parts.count >= 2 || (parts.count == 1 && (path.hasSuffix("/") || !parts[0].contains("."))) {
            return root + "/" + parts[0] + "/"
        }
        return root + "/"
    }

    /// "textbooks.math.gatech.edu/ila": a book's name until one of its pages gives a better one.
    static func label(_ id: String) -> String {
        guard let c = URLComponents(string: id), let host = c.host else { return id }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = (c.path.removingPercentEncoding ?? c.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? h : h + "/" + path
    }
}

extension String {
    /// nil for "".
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - the web books read so far (webbooks.json)

/// A page read in a web book; questions record it by its number (its place in `WebBookRecord.pages`, from 1).
struct WebPageRef: Codable, Equatable {
    var url: String
    var title: String
}

struct WebBookRecord: Codable, Equatable {
    /// The book's name, once one of its pages gives one (its site name, or a link back to its start page).
    var title: String?
    /// The page on screen when the tab was last used.
    var lastURL: String
    /// Every page shown in the book's tab, in the order first seen.
    var pages: [WebPageRef] = []
    /// The tab's text size (WKWebView pageZoom); nil = 1.
    var zoom: Double?
}

struct WebBooksFile: Codable, Equatable {
    var version = 1
    var books: [String: WebBookRecord] = [:]
}

/// The web books and their numbered pages, saved in webbooks.json; each tab's history and place in
/// web-tabs/<book>.state (WebKit's own record, so Back, Forward and the scroll position come back at launch).
@MainActor
final class WebBooks {
    private let url: URL
    private let stateFolder: URL
    private(set) var file = WebBooksFile()
    private var saveQueued = false

    init(url: URL = AppPaths.support.appendingPathComponent("webbooks.json"),
         stateFolder: URL = AppPaths.support.appendingPathComponent("web-tabs", isDirectory: true)) {
        self.url = url
        self.stateFolder = stateFolder
        if let d = try? Data(contentsOf: url) {
            if let f = try? JSONDecoder().decode(WebBooksFile.self, from: d) { file = f }
            else {
                // Never overwrite a file this version can't read.
                let aside = url.deletingLastPathComponent().appendingPathComponent("webbooks.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
            }
        }
    }

    func record(_ id: String) -> WebBookRecord? { file.books[id] }

    /// The book a page goes in: a book read before whose address the page's starts with (the longest one; so pages
    /// of "d2l.ai/" stay in that book whatever their folder), else its own (WebAddress.bookID).
    func bookID(for page: URL) -> String {
        let key = WebAddress.pageKey(page)
        return file.books.keys.filter { key.hasPrefix($0) && $0.hasSuffix("/") }.max { $0.count < $1.count }
            ?? WebAddress.bookID(page)
    }

    /// The book `page` belongs to (made the first time); its id.
    @discardableResult
    func ensure(_ page: URL) -> String {
        let id = bookID(for: page)
        if file.books[id] == nil {
            file.books[id] = WebBookRecord(lastURL: page.absoluteString)
            save()
        }
        return id
    }

    /// The deck for a book id or any page of it; nil if `path` is no web address.
    func deck(_ path: String) -> Deck? {
        guard WebAddress.isWeb(path), let u = URL(string: path) else { return nil }
        let id = ensure(u)
        let r = file.books[id]
        return Deck(path: id, title: r?.title ?? WebAddress.label(id), courseID: "web", courseName: "Web",
                    walkthroughs: [], contextFiles: [])
    }

    func pageCount(_ id: String) -> Int { file.books[id]?.pages.count ?? 0 }

    /// The title of a page read before, if it had one.
    func title(of u: URL) -> String? {
        let key = WebAddress.pageKey(u)
        return file.books[bookID(for: u)]?.pages.first { $0.url == key }?.title.nonEmpty
    }

    func page(_ id: String, _ n: Int) -> WebPageRef? {
        guard let pages = file.books[id]?.pages, n >= 1, n <= pages.count else { return nil }
        return pages[n - 1]
    }

    /// The number of the page at `url` (counted from 1, numbered the first time it shows, never changed: questions keep
    /// it); its title is kept current ("" keeps the one it has).
    func number(_ id: String, url: URL, title: String) -> Int {
        let key = WebAddress.pageKey(url)
        var r = file.books[id] ?? WebBookRecord(lastURL: url.absoluteString)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = r.pages.firstIndex(where: { $0.url == key }) {
            if !t.isEmpty, r.pages[i].title != t { r.pages[i].title = t; file.books[id] = r; save() }
            return i + 1
        }
        r.pages.append(WebPageRef(url: key, title: t))
        file.books[id] = r
        save()
        return r.pages.count
    }

    func setLast(_ id: String, _ url: URL) {
        guard var r = file.books[id], r.lastURL != url.absoluteString else { return }
        r.lastURL = url.absoluteString
        file.books[id] = r
        save()
    }

    /// The book's name from one of its pages: kept the first time only (a later page could be another site's).
    func nameIfUnnamed(_ id: String, _ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, var r = file.books[id], r.title == nil else { return false }
        r.title = String(n.prefix(120))
        file.books[id] = r
        save()
        return true
    }

    func setZoom(_ id: String, _ zoom: Double) {
        guard var r = file.books[id] else { return }
        r.zoom = abs(zoom - 1) < 0.01 ? nil : zoom
        file.books[id] = r
        save()
    }

    /// Titles of pages by number (for the chat: tags, "also asked on" chips).
    func labels(_ id: String, _ numbers: [Int]) -> [String: String] {
        var out: [String: String] = [:]
        for n in numbers { if let p = page(id, n) { out[String(n)] = p.title.isEmpty ? WebAddress.label(p.url) : p.title } }
        return out
    }

    // MARK: the tab's history and place

    private func stateURL(_ id: String) -> URL {
        let h = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return stateFolder.appendingPathComponent("\(h).state")
    }

    func savedState(_ id: String) -> Data? { try? Data(contentsOf: stateURL(id)) }

    func saveState(_ id: String, _ data: Data?) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        try? data.write(to: stateURL(id), options: .atomic)
    }

    /// Writes webbooks.json once for everything changed in this turn of the run loop.
    private func save() {
        guard !saveQueued else { return }
        saveQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveQueued = false
            self.saveNow()
        }
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(file) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - one web tab

/// The page text and what is on screen, read from a web page by webbook_read.js.
struct WebPageText: Decodable, Equatable {
    /// The address of the document read (nil from an older reader).
    var url: String? = nil
    var title: String
    var site: String
    var text: String
    var truncated: Bool
}

struct WebScreen: Decodable, Equatable {
    /// The titles of the sections a third of the way down the view, outermost first.
    var section: [String]
    /// The text on screen.
    var visible: String
    var scrollY: Double
    var viewH: Double
    var viewW: Double
    var docH: Double

    /// How far down the page the view is, 0...1 (nil for a page that fits the view).
    var position: Double? {
        let room = docH - viewH
        guard room > 40 else { return nil }
        return min(max(scrollY / room, 0), 1)
    }
}

/// What a question asked in a web tab takes from it.
struct WebSnapshot {
    var url: URL?
    var title: String
    var page: WebPageText?
    var screen: WebScreen?
    /// A picture of the view, at most the attachment size.
    var view: CGImage?

    /// The same part of the same page gives the same key: scrolled less than a fifth of the view, the same width, and
    /// the same text on screen (which also follows scrolling inside a box and parts opened or closed on the page).
    var viewKey: String {
        let page = url.map(WebAddress.pageKey) ?? "?"
        guard let s = screen, s.viewH > 0 else { return page + "|" + UUID().uuidString }
        let text = SHA256.hash(data: Data(s.visible.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(page)|\(Int((s.scrollY / max(s.viewH * 0.2, 1)).rounded()))|\(Int((s.viewW / 50).rounded()))|\(text)"
    }
}

/// One open web tab: its web view, where it is, and reading the page for the chat.
@MainActor
final class WebBookController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// Co-learner's own content world: the page's scripts can't see or call the reader.
    static let readerWorld = WKContentWorld.world(name: "CoLearnerReader")
    static let readerSource: String = (try? String(contentsOf: AppPaths.web.appendingPathComponent("webbook_read.js"), encoding: .utf8)) ?? ""

    let deckID: String
    let webView: PasteWebView
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    /// Why the last page didn't load, until another one starts.
    @Published private(set) var failure: String?
    /// The address field's text (what the user types; follows the page while not being edited).
    @Published var address = ""
    var editingAddress = false {
        didSet { if !editingAddress { address = url?.absoluteString ?? address } }
    }
    /// The page on screen changed: another page (`true`; its title isn't known yet), or a new title for it.
    var onChange: ((WebBookController, Bool) -> Void)?
    /// A page finished loading (the book's name may be on it).
    var onLoad: ((WebBookController) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var crosshair = false
    /// Run once the page with this key has loaded (Ask again on another page).
    private var waiting: [(id: UUID, key: String, run: () -> Void)] = []
    /// A page is loading but hasn't replaced the one on screen yet: WebKit already reports its address, still with the
    /// old page's title, so neither counts until it commits.
    private var provisional = false
    /// The page shown (its key), to tell another page from a new title.
    private var shownKey: String?
    /// Another app's link or a download is being asked about (one question at a time).
    private var asking = false

    /// `store`: where sites keep cookies and logins (the Mac's default, so sign-ins persist; tests pass a
    /// nonpersistent one).
    init(deckID: String, store: WKWebsiteDataStore? = nil) {
        self.deckID = deckID
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store ?? .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(WKUserScript(source: Self.readerSource, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true, in: Self.readerWorld))
        webView = PasteWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        let update: (WKWebView) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
        observations = [
            webView.observe(\.url) { v, _ in update(v) },
            webView.observe(\.title) { v, _ in update(v) },
            webView.observe(\.canGoBack) { v, _ in update(v) },
            webView.observe(\.canGoForward) { v, _ in update(v) },
            webView.observe(\.isLoading) { v, _ in update(v) },
        ]
    }

    /// The tab's history and place as WebKit records them (nil if it has none yet).
    var savedState: Data? {
        guard webView.url != nil else { return nil }
        if let d = webView.interactionState as? Data { return d }
        guard let s = webView.interactionState else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: false)
    }

    /// Back where the tab was (`state`), or else `fallback`.
    func restore(_ state: Data?, fallback: URL) {
        if let state {
            webView.interactionState = state
            if webView.url != nil || webView.isLoading { return }
        }
        load(fallback)
    }

    func load(_ u: URL) {
        failure = nil
        webView.load(URLRequest(url: u))
        if !editingAddress { address = u.absoluteString }
    }

    /// The address field's Return.
    func go(to typed: String) -> Bool {
        guard let u = WebAddress.parse(typed) else { return false }
        editingAddress = false
        load(u)
        return true
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reloadOrStop() { if webView.isLoading { webView.stopLoading() } else if webView.url != nil { webView.reload() } }

    var zoom: Double { Double(webView.pageZoom) }
    func setZoom(_ z: Double) { webView.pageZoom = CGFloat(min(max(z, 0.5), 3)) }

    /// Runs `run` once the page at `u` has loaded (at once if it is the page on screen and done), or after 15 s.
    func whenLoaded(_ u: URL, _ run: @escaping () -> Void) {
        let key = WebAddress.pageKey(u)
        if let now = webView.url, WebAddress.pageKey(now) == key, !webView.isLoading { run(); return }
        var done = false
        let once = { if !done { done = true; run() } }
        let id = UUID()
        waiting.append((id, key, once))
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.waiting.removeAll { $0.id == id }
            once()
        }
    }

    private func sync() {
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        guard !provisional else { return }
        let newURL = webView.url, newTitle = webView.title ?? ""
        let key = newURL.map(WebAddress.pageKey)
        let another = key != shownKey
        let changed = newURL != url || newTitle != title
        if newURL != url { url = newURL }
        if newTitle != title { title = newTitle }
        shownKey = key
        if !editingAddress, let u = newURL, address != u.absoluteString { address = u.absoluteString }
        if changed { onChange?(self, another) }
    }

    // MARK: reading the page

    /// Evaluates `expression` in the reader's world (the reader is put on the page first if it isn't there yet, e.g.
    /// a page still loading); its value comes back as JSON text.
    private func call(_ expression: String, _ done: @escaping (String?) -> Void) {
        let js = Self.readerSource + "\n;JSON.stringify(" + expression + ")"
        webView.evaluateJavaScript(js, in: nil, in: Self.readerWorld) { result in
            MainActor.assumeIsolated {
                if case .success(let v) = result, let s = v as? String { done(s) } else { done(nil) }
            }
        }
    }

    /// The same for an async function body that returns JSON text (`args` are its variables).
    private func callAsync(_ body: String, args: [String: Any], _ done: @escaping (String?) -> Void) {
        webView.callAsyncJavaScript(Self.readerSource + "\n;" + body, arguments: args, in: nil, in: Self.readerWorld) { result in
            MainActor.assumeIsolated {
                if case .success(let v) = result, let s = v as? String { done(s) } else { done(nil) }
            }
        }
    }

    /// MathJax 3 keeps the TeX of each formula in its own records, which only the page's world can see: copy it onto
    /// the formulas (data-cl-tex) for the reader. Nothing else on the page changes.
    private static let mathScript = """
    (function () {
      try {
        var d = window.MathJax && MathJax.startup && MathJax.startup.document, list = d && d.math;
        if (!list) return 0;
        var n = 0;
        Array.from(list).forEach(function (it) {
          var root = it && it.typesetRoot;
          if (root && root.nodeType === 1 && typeof it.math === "string") {
            var tex = it.math.trim(), mark = it.display ? "$$" : "$";
            root.setAttribute("data-cl-tex", mark + tex + mark);
            n++;
          }
        });
        return n;
      } catch (e) { return -1; }
    })();
    """

    /// The page text (with its collapsed examples, see readAll in webbook_read.js), what is on screen and a picture of
    /// it, for a question. Whatever can't be read in 8 seconds (a page that is busy, a web process that hung) is left out.
    func snapshot(root: String, _ done: @escaping (WebSnapshot) -> Void) {
        var snap = WebSnapshot(url: webView.url, title: webView.title ?? "")
        var finished = false
        let finish = { if !finished { finished = true; done(snap) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
        webView.evaluateJavaScript(Self.mathScript, in: nil, in: .page) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !finished else { return }
                self.callAsync("return JSON.stringify(await __clReader.readAll(opts));",
                               args: ["opts": ["max": WebContext.maxPageText, "root": root]]) { read in
                    snap.page = read.flatMap(Self.decodePage)
                    self.call("__clReader.where({max: 2000})") { screen in
                        snap.screen = screen.flatMap(Self.decodeScreen)
                        self.captureView { image in
                            snap.view = image
                            finish()
                        }
                    }
                }
            }
        }
    }

    /// The book's name, if the page shows one (cheap: only the first part of the text is read).
    func siteName(root: String, _ done: @escaping (String?) -> Void) {
        call("__clReader.read(\(Self.json(["max": 1000, "root": root])))") { s in
            done(s.flatMap(Self.decodePage).map(\.site).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    nonisolated static func decodePage(_ json: String) -> WebPageText? {
        guard var p = try? JSONDecoder().decode(WebPageText.self, from: Data(json.utf8)) else { return nil }
        p.title = String(p.title.prefix(300))
        p.site = String(p.site.prefix(120))
        p.text = String(p.text.prefix(60_000))
        return p
    }

    nonisolated static func decodeScreen(_ json: String) -> WebScreen? {
        guard var s = try? JSONDecoder().decode(WebScreen.self, from: Data(json.utf8)) else { return nil }
        s.section = Array(s.section.prefix(8)).map { String($0.prefix(160)) }
        s.visible = String(s.visible.prefix(2_000))
        return s
    }

    private static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// A picture of the whole view.
    func captureView(_ done: @escaping (CGImage?) -> Void) {
        snapshotImage(webView.bounds, done)
    }

    /// A picture of `rect` (web view coordinates, flipped like the page's) and the section at its middle.
    func capture(_ rect: CGRect, _ done: @escaping (CGImage?, String?) -> Void) {
        let r = rect.intersection(webView.bounds)
        guard r.width >= 4, r.height >= 4 else { done(nil, nil); return }
        let zoom = max(webView.pageZoom * webView.magnification, 0.01)
        call("__clReader.sectionAt(\(Double(r.midY / zoom)))") { [weak self] found in
            guard let self else { done(nil, nil); return }
            let section = found.flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
                .flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            self.snapshotImage(r) { done($0, section) }
        }
    }

    /// Drawn afresh at about 3 pixels per point, at most the attachment's long edge, so small print stays sharp.
    private func snapshotImage(_ r: CGRect, _ done: @escaping (CGImage?) -> Void) {
        guard r.width >= 4, r.height >= 4, webView.url != nil else { done(nil); return }
        let scale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let perPoint = min(3, ImageAttachments.longEdge / max(r.width, r.height))
        let config = WKSnapshotConfiguration()
        config.rect = r
        config.snapshotWidth = NSNumber(value: Double(r.width * perPoint / scale))
        webView.takeSnapshot(with: config) { image, _ in
            MainActor.assumeIsolated { done(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)) }
        }
    }

    /// While a box is dragged out over the page: a crosshair everywhere (pages set their own cursors otherwise).
    func showCrosshair(_ on: Bool) {
        crosshair = on
        guard webView.url != nil else { return }
        call("__clReader.crosshair(\(on))") { _ in }
    }

    // MARK: WKNavigationDelegate, WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            // data: only in frames (WebKit refuses top-level data: pages anyway).
            decisionHandler(scheme == "data" && action.targetFrame?.isMainFrame != false ? .cancel : .allow)
            return
        }
        // mailto: and other apps' links (zoommtg:, vscode:…): only after asking, as a page can "click" one by script.
        // Never local files.
        if action.navigationType == .linkActivated, let u = action.request.url, !["file", "javascript"].contains(scheme) {
            confirmOpen(u, title: "Open this link in another app?",
                        info: "The page wants to open a “\(scheme):” link, in the app that handles it.")
        }
        decisionHandler(.cancel)
    }

    /// Asks before handing `u` to another app (one question at a time; a page asking again meanwhile is ignored).
    private func confirmOpen(_ u: URL, title: String, info: String) {
        guard !asking, let w = webView.window else { return }
        asking = true
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info + "\n\n" + String(u.absoluteString.prefix(300))
        a.addButton(withTitle: "Open")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            self?.asking = false
            if r == .alertFirstButtonReturn { NSWorkspace.shared.open(u) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // A download (a zip, a slide file): the browser takes it, if the student says so.
        if response.canShowMIMEType { decisionHandler(.allow); return }
        if response.isForMainFrame, let u = response.response.url {
            confirmOpen(u, title: "Download this file in your browser?",
                        info: "“\(response.response.suggestedFilename ?? u.lastPathComponent)” is a file this tab can't show.")
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        provisional = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        provisional = false
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        provisional = false
        sync()
        if crosshair { showCrosshair(true) }
        if let now = webView.url {
            let key = WebAddress.pageKey(now)
            let ready = waiting.filter { $0.key == key }
            waiting.removeAll { $0.key == key }
            ready.forEach { $0.run() }
        }
        onLoad?(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        provisional = false
        noteFailure(error)
        sync()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    private func noteFailure(_ error: Error) {
        let e = error as NSError
        // Stopped, replaced by another load, or handed to the browser: nothing went wrong.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        failure = e.localizedDescription
        sync()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        provisional = false
        webView.reload()
    }

    /// Links that open a new window (target="_blank", window.open) open in this tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let u = action.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            webView.load(URLRequest(url: u))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "This page says"
        a.informativeText = message
        if let w = webView.window { a.beginSheetModal(for: w) { _ in completionHandler() } } else { a.runModal(); completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "This page asks"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        if let w = webView.window {
            a.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn) }
        } else {
            completionHandler(a.runModal() == .alertFirstButtonReturn)
        }
    }
}

// MARK: - what a web tab shows

/// A web tab: back, forward, reload, the address and Open in Browser above the page.
struct WebBookPane: View {
    @ObservedObject var web: WebBookController
    /// An area of the page is being selected (passed in so the layer's crosshair and hint follow it).
    let selecting: Bool
    /// Asked by the layer as the mouse moves (AppModel.selectingArea).
    let isSelecting: () -> Bool
    /// The box dragged out (in the layer's coordinates), the layer, and the web view under it.
    let onArea: (NSRect, AreaSelectView, NSView) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WebBookBar(web: web)
            if let f = web.failure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text("Couldn’t open the page: \(f)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Try Again") { web.reloadOrStop() }.controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            Divider()
            WebContentHost(web: web, selecting: selecting, isSelecting: isSelecting, onArea: onArea)
                .id(web.deckID)
        }
    }
}

private struct WebBookBar: View {
    @ObservedObject var web: WebBookController

    var body: some View {
        HStack(spacing: 4) {
            Button { web.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle())
                .disabled(!web.canGoBack)
                .help("Back (⌘[)")
            Button { web.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(IconButtonStyle())
                .disabled(!web.canGoForward)
                .help("Forward (⌘])")
            Button { web.reloadOrStop() } label: {
                Image(systemName: web.isLoading ? "xmark" : "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(IconButtonStyle())
            .help(web.isLoading ? "Stop loading" : "Reload this page")
            TextField("Web address", text: $web.address, onEditingChanged: { web.editingAddress = $0 }, onCommit: {
                if !web.go(to: web.address) { NSSound.beep() }
            })
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .help("The page’s address. Type or paste another one and press Return")
            Button {
                if let u = web.url { NSWorkspace.shared.open(u) }
            } label: { Image(systemName: "safari").font(.system(size: 13)) }
                .buttonStyle(IconButtonStyle())
                .disabled(web.url == nil)
                .help("Open this page in your browser")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The tab's web view with the area layer on top (✂︎ Select area, ⌥-drag), as for the slides.
private struct WebContentHost: NSViewRepresentable {
    let web: WebBookController
    /// Passed in so that SwiftUI updates the layer (crosshair, hint) when selecting starts and ends.
    let selecting: Bool
    let isSelecting: () -> Bool
    let onArea: (NSRect, AreaSelectView, NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        let view = web.webView
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        let overlay = AreaSelectView(hint: "Drag over the part of the page you want · Esc to cancel")
        overlay.frame = box.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.scrollTarget = view
        overlay.isActive = isSelecting
        let onArea = onArea
        overlay.onSelect = { [weak overlay, weak view] r in
            guard let overlay, let view else { return }
            onArea(r, overlay, view)
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
        for v in box.subviews { v.removeFromSuperview() }
    }
}

/// "Open a Web Page…": the address, typed or pasted. nil when cancelled; the alert repeats until the address is valid.
@MainActor
enum WebAddressPrompt {
    static func ask(title: String, info: String, button: String, initial: String = "") -> URL? {
        var text = initial
        while true {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = info
            a.addButton(withTitle: button)
            a.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "https://textbooks.math.gatech.edu/ila/"
            field.stringValue = text
            a.accessoryView = field
            a.window.initialFirstResponder = field
            guard a.runModal() == .alertFirstButtonReturn else { return nil }
            text = field.stringValue
            if let u = WebAddress.parse(text) { return u }
            NSSound.beep()
        }
    }
}
