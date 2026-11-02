import AppKit
import WebKit

/// Owns the chat web view, the chat history and the running assistant processes.
@MainActor
final class ChatController: NSObject, WKNavigationDelegate {
    unowned let model: AppModel
    let store = ChatStore()
    let claude = ClaudeBackend()
    let codex = CodexBackend()

    private(set) var webView: WKWebView!
    private var ready = false
    private var running: [String: RunHandle] = [:]          // assistant message id -> process
    private var stopping: [String: RunHandle] = [:]         // stopped, process not exited yet
    private var saved = Set<String>()                        // runs whose turn completed (in the session)
    private var runWhere: [String: (deck: String, conv: String)] = [:]
    /// What an assistant had seen before a run; put back if the run is stopped or fails (it may never have
    /// reached the session).
    private struct SeenBefore {
        var provider: Provider
        var fresh: Bool
        var by: [String]?
        var slides: [Int]?
        var view: String?
    }
    private var seenBefore: [String: SeenBefore] = [:]
    /// Web tabs: answers whose question waits for its page to be read (they start once it is).
    private var awaitingPage = Set<String>()
    private var dirty: [String: ChatMessage] = [:]
    private var flushScheduled = false
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var searchRequest: (query: String, id: Int)?
    private var searchResults: [ChatSearchResult] = []
    private var searchPending = false
    /// Last plan usage per assistant (kept across launches). Updated after every answer and on demand.
    private struct Usage {
        var plan: String?; var windows: [UsageWindow]; var updated: Double; var loading = false; var error: String?
        var signedOut = false
    }
    /// Signing Claude / ChatGPT in again from the chat (a login that expired).
    let signIn = SignIn()
    private var usage: [Provider: Usage] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
        signIn.onChange = { [weak self] p, phase in
            guard let self else { return }
            self.pushSignIn()
            if phase == .signedIn {
                self.usage[p]?.signedOut = false
                self.refreshUsage(force: true)
            }
        }
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(self), name: "cl")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let chatView = PasteWebView(frame: .zero, configuration: config)
        webView = chatView
        chatView.pastePictures = { [weak self] in self?.pasteForChat() ?? false }
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        let web = AppPaths.web
        webView.loadFileURL(web.appendingPathComponent("chat.html"), allowingReadAccessTo: web)
        ImageAttachments.removeOld()
    }

    // MARK: JS bridge

    private func js(_ fn: String, _ arg: Any) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.CL && CL.\(fn)(\(s))", completionHandler: nil)
    }

    // MARK: model pickers and usage

    func pushConfig() {
        let cat = ModelCatalog.shared
        func entry(_ p: Provider, _ id: String, _ effort: String) -> [String: Any] {
            let models = ModelCatalog.list(p)
            let m = ModelCatalog.model(p, id) ?? models.first
            return [
                "models": models.map { ["id": $0.id, "label": $0.label, "hidden": cat.isHidden(p, $0.id), "isNew": cat.isNew(p, $0.id)] },
                "model": id,
                "efforts": (m?.effortInfo ?? []).map { ["id": $0.id, "label": $0.label] },
                "effort": effort,
                "updated": cat.updated[p] ?? 0,
                "refreshing": cat.refreshing,
            ]
        }
        var codex = entry(.codex, model.codexModel, model.codexEffort)
        codex["fastMode"] = model.codexFastMode
        js("setConfig", ["claude": entry(.claude, model.claudeModel, model.claudeEffort), "codex": codex])
    }

    /// Fresh model lists from both tools (also run at every launch). New models appear in the menu by themselves.
    func refreshModels() {
        let cat = ModelCatalog.shared
        cat.onChange = { [weak self] in
            guard let self else { return }
            self.model.ensureModelChoices()
            self.pushConfig()
        }
        cat.refresh(claudeBin: claude.knownLocation, codexBin: codex.knownBinary)
    }

    private func loadUsage() {
        for p in Provider.allCases {
            if let d = UserDefaults.standard.data(forKey: "usage.\(p.rawValue)"),
               let w = try? JSONDecoder().decode([UsageWindow].self, from: d) {
                usage[p] = Usage(plan: UserDefaults.standard.string(forKey: "usage.\(p.rawValue).plan"), windows: w,
                                 updated: UserDefaults.standard.double(forKey: "usage.\(p.rawValue).at"))
            }
        }
        pushUsage()
        refreshUsage(force: false)
    }

    /// Asks both tools for their current limits (no model is called). Skipped if fetched in the last 2 minutes.
    func refreshUsage(force: Bool) {
        let now = Date().timeIntervalSince1970
        for p in Provider.allCases {
            if usage[p]?.loading == true { continue }
            if !force, let u = usage[p], now - u.updated < 120, !u.windows.isEmpty { continue }
            var u = usage[p] ?? Usage(plan: nil, windows: [], updated: 0)
            u.loading = true
            usage[p] = u
            switch p {
            case .claude:
                // Never probe for the binary on the main thread; right after launch the lookup may still be running.
                let known = claude.knownLocation
                let cwd = ClaudeBackend.workingDirectory
                DispatchQueue.global(qos: .utility).async {
                    let loc: (URL, [Int])? = known ?? ClaudeBackend.candidates().max { $0.1.lexicographicallyPrecedes($1.1) }
                    let r = loc.map { UsageFetcher.claude(bin: $0.0, env: ClaudeBackend.environment($0.0), cwd: cwd) }
                        ?? .init(plan: nil, windows: [], error: "Claude Code not found.")
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.finishUsage(p, r) } }
                }
            case .codex:
                let known = codex.knownBinary
                DispatchQueue.global(qos: .utility).async {
                    guard let bin = known ?? CodexBackend.locate() else {
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.finishUsage(p, .init(plan: nil, windows: [], error: "Codex CLI not found.")) } }
                        return
                    }
                    var r = UsageFetcher.codex(bin: bin, env: ToolLocator.environment(addingDirsOf: [bin]))
                    if r.windows.isEmpty {   // fall back to the last limits Codex logged
                        let logged = UsageWindow.latestCodex(thread: nil)
                        if !logged.isEmpty { r = .init(plan: r.plan, windows: logged, error: nil) }
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.finishUsage(p, r) } }
                }
            }
        }
        pushUsage()
    }

    private func finishUsage(_ p: Provider, _ r: UsageFetcher.Result) {
        var u = usage[p] ?? Usage(plan: nil, windows: [], updated: 0)
        u.loading = false
        u.signedOut = r.signedOut
        if r.windows.isEmpty {
            u.error = r.error
        } else {
            u.windows = r.windows
            u.updated = Date().timeIntervalSince1970
            u.error = nil
        }
        if let plan = r.plan { u.plan = plan }
        usage[p] = u
        saveUsage(p)
        pushUsage()
    }

    /// After an answer: the tool reported some windows; update those, keep the rest (e.g. Fable's week).
    private func setUsage(_ p: Provider, _ w: [UsageWindow]) {
        var u = usage[p] ?? Usage(plan: nil, windows: [], updated: 0)
        for nw in w {
            if let i = u.windows.firstIndex(where: { $0.label == nw.label }) {
                var merged = nw
                if merged.title == nil { merged.title = u.windows[i].title }
                u.windows[i] = merged
            } else {
                u.windows.append(nw)
            }
        }
        u.updated = Date().timeIntervalSince1970
        u.error = nil
        usage[p] = u
        saveUsage(p)
        pushUsage()
    }

    private func saveUsage(_ p: Provider) {
        guard let u = usage[p] else { return }
        if let d = try? JSONEncoder().encode(u.windows) { UserDefaults.standard.set(d, forKey: "usage.\(p.rawValue)") }
        UserDefaults.standard.set(u.updated, forKey: "usage.\(p.rawValue).at")
        if let plan = u.plan { UserDefaults.standard.set(plan, forKey: "usage.\(p.rawValue).plan") }
    }

    private func pushUsage() {
        var d: [String: Any] = [:]
        for (p, u) in usage {
            var e: [String: Any] = ["windows": u.windows.map(\.js), "updated": u.updated, "loading": u.loading]
            if let plan = u.plan { e["plan"] = plan }
            if let err = u.error { e["error"] = err }
            if u.signedOut { e["signedOut"] = true }
            d[p.rawValue] = e
        }
        js("setUsage", d)
    }

    // MARK: sign in again / ask again

    /// Opens Terminal with Claude Code's or Codex's own login (the browser shows the Authorize page).
    func startSignIn(_ p: Provider) {
        switch p {
        case .claude: signIn.start(.claude, binary: claude.located?.0, checkIn: ClaudeBackend.workingDirectory)
        case .codex: signIn.start(.codex, binary: codex.binary, checkIn: nil)
        }
    }

    private func pushSignIn() {
        var d: [String: String] = [:]
        for p in Provider.allCases { d[p.rawValue] = (signIn.phase[p] ?? .idle).rawValue }
        js("setSignIn", d)
    }

    /// "Ask again" on an answer that failed: the same question, to the same assistant, on the slide it was asked on,
    /// with what the chat box holds now (an unanswered question's pictures and quote come back there).
    func askAgain(messageID: String, useArea: Bool, imageIDs: [String], quoteID: String?) {
        guard let deck = model.deck else { return }
        let conv = store.current(deck.path)
        guard let i = conv.messages.firstIndex(where: { $0.id == messageID }), let p = conv.messages[i].provider,
              let q = conv.messages[..<i].last(where: { $0.role == .user }) else { return }
        let again = { [weak self] in
            self?.send(text: q.text, display: q.display, choice: p.rawValue, useArea: useArea, imageIDs: imageIDs, quoteID: quoteID)
        }
        // A web tab goes back to the question's page first, and asks once it is there.
        if deck.isWeb, let page = q.page, page != model.page, let ref = model.webBooks.page(deck.path, page),
           let u = URL(string: ref.url), let tab = model.web {
            tab.load(u)
            tab.whenLoaded(u) { [weak self] in
                guard let self, self.model.deck?.path == deck.path, self.model.page == page else { return }
                again()
            }
            return
        }
        if let page = q.page, page != model.page, page >= 1, page <= model.pageCount { model.page = page }
        again()
    }

    func focusInput() {
        // A popped-out chat window has to become key to take typing.
        if NSApp.isActive, let w = webView.window, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
        webView.window?.makeFirstResponder(webView)
        guard ready else { return }
        webView.evaluateJavaScript("window.CL && CL.focusInput()", completionHandler: nil)
    }

    func openSearch() {
        if NSApp.isActive, let w = webView.window, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
        webView.window?.makeFirstResponder(webView)
        guard ready else { searchPending = true; return }
        js("openSearch", NSNull())
    }

    private func searchChats(query: String, requestID: Int) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        searchRequest = (query, requestID)
        searchResults = []
        searchTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.store.search(query: query)
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            self.searchResults = results
            self.pushSearchResults()
        }
    }

    private func pushSearchResults(error: String? = nil) {
        guard let request = searchRequest else { return }
        var payload: [String: Any] = ["query": request.query, "requestID": request.id,
            "results": searchResults.map { result -> [String: Any] in
                let deck = model.deck(path: result.deckPath) ?? model.openDecks.first { $0.path == result.deckPath }
                var row: [String: Any] = ["id": result.id, "deckPath": result.deckPath,
                    "deckTitle": deck?.title ?? URL(fileURLWithPath: result.deckPath).deletingPathExtension().lastPathComponent,
                    "courseName": deck?.courseName ?? "Saved deck", "messageID": result.messageID,
                    "role": result.role.rawValue, "snippet": result.snippet,
                    "created": result.createdAt.timeIntervalSince1970]
                if let id = result.conversationID { row["conversationID"] = id }
                if let page = result.page { row["page"] = page }
                if let d = deck, d.isWeb, let page = result.page, let ref = model.webBooks.page(d.path, page) {
                    row["pageLabel"] = ref.title.nonEmpty ?? WebAddress.label(ref.url)
                }
                if let provider = result.provider { row["provider"] = provider.rawValue }
                return row
            }]
        if let error { payload["error"] = error }
        js("setSearchResults", payload)
    }

    private func openSearchResult(_ id: String) {
        // The page may return only a native-issued result ID, never an arbitrary file path.
        guard let result = searchResults.first(where: { $0.id == id }),
              let destination = ChatNavigation.destination(for: result, store: store,
                  decks: [model.deck(path: result.deckPath)].compactMap { $0 } + model.openDecks) else {
            pushSearchResults(error: "This message is no longer available. Search again to refresh the results.")
            return
        }
        guard model.open(destination.deck) else {
            pushSearchResults(error: "The deck’s PDF could not be opened. Restore the file and try again.")
            return
        }
        store.setCurrent(destination.deck.path, destination.conversationID)
        if let page = destination.page, (1...max(model.pageCount, 1)).contains(page) { model.goToPage(page) }
        model.refreshChatPages()
        model.showPanel(.chat)
        showCurrent()
        js("revealMessage", ["messageID": destination.messageID])
    }

    /// Re-render the chat panel: the deck's current conversation (chat.js shows this slide's part, or all).
    func showCurrent() {
        guard ready else { return }
        // Send queued updates first (in order), so the page's copy is current when setThread compares.
        for (_, m) in dirty { js("upsertMessage", m.js) }
        dirty.removeAll()
        guard let d = model.deck else {
            area = nil
            dropQuote()
            js("setThread", ["hasDeck": false, "kind": "slides", "messages": [], "pages": [], "provider": model.provider, "history": [],
                             "area": NSNull(), "conversation": NSNull(), "images": imagesJS, "quote": NSNull(),
                             "processing": imagesInFlight] as [String: Any])
            return
        }
        // A selected area belongs to its slide; moving on drops it. A walkthrough quote belongs to its deck.
        if let a = area, a.deck != d.path || a.page != model.page { area = nil }
        if quoteDeck != d.path { dropQuote() }
        let conv = store.current(d.path)
        var areaJS: Any = NSNull()
        if let a = area { areaJS = ["page": a.page, "thumb": a.thumb] }
        // A web tab: the page on screen and the titles of the pages questions were asked on.
        var web: [String: Any] = ["kind": "slides"]
        if d.isWeb {
            web = ["kind": "web", "pageTitle": model.webPageTitle ?? "",
                   "pageLabels": model.webBooks.labels(d.path, conv.pages + [model.page])]
        }
        js("setThread", web.merging([
            "hasDeck": true, "deckTitle": d.title, "deckPath": d.path, "page": model.page, "pageCount": model.pageCount,
            "messages": conv.messages.map(\.js), "pages": conv.pages, "provider": model.provider,
            "conversation": ["id": conv.id, "legacy": conv.legacy ?? false, "created": conv.created.timeIntervalSince1970],
            "history": store.conversations(d.path).map { c -> [String: Any] in
                ["id": c.id, "created": c.created.timeIntervalSince1970, "count": c.messages.filter { $0.role == .user }.count,
                 "legacy": c.legacy ?? false, "current": c.id == conv.id,
                 "first": c.messages.first(where: { $0.role == .user }).map { $0.display ?? String($0.text.prefix(60)) } ?? ""]
            },
            "area": areaJS,
            "images": imagesJS,
            "quote": pendingQuote?.js ?? NSNull(),
            "processing": imagesInFlight,
        ] as [String: Any]) { _, b in b })
    }

    private func isVisible(_ deck: String, _ conv: String) -> Bool {
        model.deck?.path == deck && store.current(deck).id == conv
    }

    /// PDFs were renamed or moved: running answers, the selected area and the quote follow their deck.
    func followMoves(_ follow: (String) -> String) {
        runWhere = runWhere.mapValues { (deck: follow($0.deck), conv: $0.conv) }
        askedWith = askedWith.mapValues { a in var a = a; a.deck = follow(a.deck); return a }
        if let a = area { area?.deck = follow(a.deck) }
        quoteDeck = quoteDeck.map(follow)
        searchResults = searchResults.map { r in var r = r; r.deckPath = follow(r.deckPath); return r }
    }

    private func push(_ m: ChatMessage, deck: String, conv: String, immediate: Bool = false) {
        guard isVisible(deck, conv) else { return }
        if immediate {
            dirty.removeValue(forKey: m.id)
            js("upsertMessage", m.js)
            return
        }
        dirty[m.id] = m
        if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                for (_, m) in self.dirty { self.js("upsertMessage", m.js) }
                self.dirty.removeAll()
            }
        }
    }

    // MARK: selected area

    /// An area of a slide the user cut out (button "Select area", or ⌥-drag on the slide); in a web tab, of the page,
    /// with the section it is in.
    struct Area { var deck: String; var page: Int; var url: URL; var thumb: String; var section: String? = nil }
    private(set) var area: Area?

    func setArea(page: Int, url: URL, thumb: String, section: String? = nil) {
        guard let d = model.deck else { return }
        area = Area(deck: d.path, page: page, url: url, thumb: thumb, section: section)
        js("setArea", ["page": page, "thumb": thumb])
        DispatchQueue.main.async { [weak self] in self?.focusInput() }
    }

    func clearArea() {
        area = nil
        js("setArea", NSNull())
    }

    // MARK: screenshots, images and walkthrough quotes

    /// Pictures waiting in the chat box. They go with the next question, whatever the deck or slide (like the text
    /// being typed).
    private(set) var pendingImages: [PendingImage] = []
    /// Text quoted from the open deck's walkthrough or notes; another deck coming up drops it.
    private(set) var pendingQuote: ChatQuote?
    private var quoteDeck: String?
    /// The chat a quoted answer (Reply) came from. The quote stays through New chat and History; a question asked in
    /// another chat is told the answer isn't part of it.
    private var quoteConversation: String?
    /// Decoding and scaling run here, in order, off the main thread.
    private let imageQueue = DispatchQueue(label: "Co-learner.images", qos: .userInitiated)
    private var imagesInFlight = 0

    private var imagesJS: [[String: Any]] {
        pendingImages.map { ["id": $0.id, "label": $0.label, "thumb": $0.thumb] }
    }

    private func pushAttachments() {
        js("setAttachments", ["images": imagesJS, "quote": pendingQuote?.js ?? NSNull(), "processing": imagesInFlight] as [String: Any])
    }

    /// The chat's Search box is open (⌘V there pastes text into it, never a picture into the chat box).
    private(set) var searchOpen = false

    /// A short line under the chat box ("Only images can be attached").
    private func note(_ text: String, error: Bool = true) {
        js("showNote", ["text": text, "error": error])
    }

    /// Attach a picture: `make` decodes and scales it off the main thread; `failure` is shown if it can't be read.
    private func attach(_ failure: String, _ make: @escaping () -> PendingImage?) {
        guard pendingImages.count + imagesInFlight < ImageAttachments.maxPending else {
            note("At most \(ImageAttachments.maxPending) pictures go with one question.")
            return
        }
        imagesInFlight += 1
        pushAttachments()   // the page shows that a picture is on its way and holds the question until it is in
        imageQueue.async {
            let image = make()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.imagesInFlight -= 1
                    if let image { self.pendingImages.append(image) } else { self.note(failure) }
                    self.pushAttachments()
                }
            }
        }
    }

    /// Image data from the pasteboard or dropped on the chat. `detail` is how the prompt names it.
    func addImage(data: Data, label: String, detail: String) {
        attach("Couldn’t read “\(label)” as an image.") { ImageAttachments.make(data: data, label: label, detail: detail) }
    }

    /// A picture made in the app: a snapshot of part of the walkthrough, a rendered notes page (`fromNotes`).
    func addImage(cgImage: CGImage, label: String, detail: String, fromNotes: Bool = false) {
        attach("Couldn’t attach “\(label)”.") {
            var image = ImageAttachments.make(image: cgImage, label: label, detail: detail)
            image?.fromNotes = fromNotes
            return image
        }
    }

    func addImage(fileURL u: URL) {
        let name = u.lastPathComponent
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= ImageAttachments.maxFileBytes else { note("“\(name)” is too large to attach."); return }
        attach("Couldn’t read “\(name)” as an image.") {
            (try? Data(contentsOf: u)).flatMap { ImageAttachments.make(data: $0, label: name, detail: "an image the student attached (“\(name)”)") }
        }
    }

    /// Paste in the chat page (⌘V, Edit › Paste): a picture on the clipboard goes into the chat box; anything else
    /// (text, or the Search box open) is the page's to paste.
    private func pasteForChat() -> Bool {
        !searchOpen && pasteImages()
    }

    /// Attaches the images on `pb` (a copied screenshot, image files copied in Finder). False if there are none, so
    /// the paste can go on as text. Only call it for a paste the user made (a paste action, a drop): macOS asks before
    /// letting an app read the clipboard any other time.
    @discardableResult
    func pasteImages(from pb: NSPasteboard = .general) -> Bool {
        guard model.deck != nil else { return false }
        let items = ImageAttachments.items(on: pb)
        for item in items {
            switch item {
            case .file(let u): addImage(fileURL: u)
            case .data(let d): addImage(data: d, label: "Pasted image", detail: "an image the student pasted")
            }
        }
        return !items.isEmpty
    }

    /// The 📎 button: pick screenshots or other pictures (the panel opens in the screenshot folder).
    func chooseImages() {
        guard model.deck != nil else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        p.message = "Choose screenshots or other pictures to ask about"
        p.prompt = "Attach"
        p.directoryURL = ImageAttachments.screenshotFolder
        guard p.runModal() == .OK else { return }
        for u in p.urls { addImage(fileURL: u) }
        focusInput()
    }

    func removeImage(_ id: String) {
        guard let i = pendingImages.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: pendingImages.remove(at: i).url)   // never sent: nobody reads it
        pushAttachments()
    }

    /// "Ask" in the Walkthrough tab: the passage goes with the next question about the open deck (replacing an
    /// earlier one). `conversation`: for part of an answer, the chat it is in.
    func setQuote(_ q: ChatQuote, conversation: String? = nil) {
        guard let d = model.deck else { return }
        var q = q
        q.text = String(q.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatQuote.maxText))
        guard !q.text.isEmpty else { return }
        pendingQuote = q
        quoteDeck = d.path
        quoteConversation = conversation
        pushAttachments()
    }

    func clearQuote() {
        dropQuote()
        pushAttachments()
    }

    /// Part of an answer the student selected to ask about: whose answer it is and the slide it was given on. Only a
    /// finished answer (a streaming one is still being redrawn).
    /// `place`: where it was given, when that isn't "slide N" (a web tab: the page's title).
    static func replyQuote(text: String, to m: ChatMessage, place: String? = nil) -> ChatQuote? {
        guard m.role == .assistant, m.status != .streaming else { return nil }
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatQuote.maxText))
        guard !t.isEmpty else { return nil }
        return ChatQuote(source: (m.provider?.displayName ?? "The assistant") + "’s answer", section: place ?? m.page.map { "slide \($0)" },
                         text: t, kind: "reply", provider: m.provider)
    }

    private func dropQuote() {
        pendingQuote = nil
        quoteDeck = nil
        quoteConversation = nil
    }

    func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            ready = true
            searchOpen = false
            searchTask?.cancel()
            searchGeneration += 1
            searchRequest = nil
            searchResults = []
            showCurrent()
            pushConfig()
            loadUsage()
            pushSignIn()
            refreshModels()
            if searchPending { searchPending = false; openSearch() }
        case "searchChats":
            guard let query = body["query"] as? String, let id = body["requestID"] as? Int else { return }
            searchChats(query: query, requestID: id)
        case "openSearchResult":
            if let id = body["id"] as? String { openSearchResult(id) }
        case "searchState":
            searchOpen = body["open"] as? Bool ?? false
        case "turn":
            if let d = body["delta"] as? Int { model.go(d) }
        case "headHeight":
            if let h = body["height"] as? Double, h >= 20, h <= 200, abs(CGFloat(h) - model.chatHeadHeight) >= 0.5 {
                model.chatHeadHeight = CGFloat(h)
            }
        case "setModel":
            guard let p = Provider(rawValue: body["provider"] as? String ?? ""), let m = body["model"] as? String,
                  ModelCatalog.model(p, m) != nil else { return }
            if p == .claude { model.claudeModel = m } else { model.codexModel = m }
        case "setModelVisible":
            guard let p = Provider(rawValue: body["provider"] as? String ?? ""), let m = body["model"] as? String else { return }
            let show = body["visible"] as? Bool ?? true
            ModelCatalog.shared.setHidden(p, m, !show)
            model.ensureModelChoices()   // hiding the model in use switches to the first one shown
            pushConfig()
        case "jsError":
            NSLog("Co-learner chat page error: %@", body["message"] as? String ?? "?")
        case "refreshModels":
            refreshModels()
        case "refreshUsage":
            refreshUsage(force: body["force"] as? Bool ?? false)
        case "setEffort":
            guard let p = Provider(rawValue: body["provider"] as? String ?? ""), let e = body["effort"] as? String else { return }
            if p == .claude { model.claudeEffort = e } else { model.codexEffort = e }
        case "setFastMode":
            guard body["provider"] as? String == Provider.codex.rawValue,
                  let enabled = body["enabled"] as? Bool else { return }
            model.codexFastMode = enabled
        case "send":
            let text = body["text"] as? String ?? ""
            let display = body["display"] as? String
            let p = body["provider"] as? String ?? model.provider
            if p != model.provider { model.provider = p }
            send(text: text, display: display, choice: p, useArea: body["useArea"] as? Bool ?? true,
                 imageIDs: body["imageIDs"] as? [String] ?? [], quoteID: body["quoteID"] as? String)
        case "signIn":
            guard let p = Provider(rawValue: body["provider"] as? String ?? "") else { return }
            startSignIn(p)
        case "askAgain":
            askAgain(messageID: body["messageID"] as? String ?? "", useArea: body["useArea"] as? Bool ?? false,
                     imageIDs: body["imageIDs"] as? [String] ?? [], quoteID: body["quoteID"] as? String)
        case "stop":
            let ps = (body["providers"] as? [String])?.compactMap(Provider.init(rawValue:))
            stopVisible(providers: ps.map(Set.init))
        case "gotoSlide":
            if let page = ChatNavigation.slide(from: body, deckPath: model.deck?.path,
                conversationID: model.deck.map { store.current($0.path).id }, pageCount: model.pageCount) {
                model.goToPage(page)
            }
        case "selectArea":
            model.beginAreaSelection()
        case "clearArea":
            clearArea()
        case "attachImageData":
            // A picture dropped on the chat, read by the page as a data URL.
            guard model.deck != nil, let s = body["data"] as? String, s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return }
            let name = String(((body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Dropped image").prefix(160))
            let encoded = String(s[s.index(after: comma)...])
            attach("Couldn’t read “\(name)” as an image.") {
                Data(base64Encoded: encoded).flatMap { ImageAttachments.make(data: $0, label: name, detail: "an image the student attached (“\(name)”)") }
            }
        case "dropImages":
            // Dropped files the page could not read itself (e.g. promised files): try the drag pasteboard.
            if !pasteImages(from: NSPasteboard(name: .drag)) { note("Only pictures can be attached.") }
        case "chooseImages":
            DispatchQueue.main.async { [weak self] in self?.chooseImages() }   // not inside WebKit's callback
        case "removeImage":
            if let id = body["id"] as? String { removeImage(id) }
        case "clearQuote":
            clearQuote()
        case "quoteReply":
            // "Reply" on part of an answer: the page sends the selected text and the answer it came from.
            guard let d = model.deck, let id = body["messageID"] as? String, let text = body["text"] as? String,
                  let m = store.current(d.path).messages.first(where: { $0.id == id }) else { return }
            let place = d.isWeb ? m.page.map { n in model.webBooks.page(d.path, n)?.title.nonEmpty ?? "page \(n)" } : nil
            guard let q = Self.replyQuote(text: text, to: m, place: place) else { return }
            setQuote(q, conversation: store.current(d.path).id)
        case "newChat":
            guard let d = model.deck else { return }
            store.startNew(d.path)
            model.refreshChatPages()
            showCurrent()
        case "openChat":
            guard let d = model.deck, let id = body["id"] as? String else { return }
            store.setCurrent(d.path, id)
            model.refreshChatPages()
            showCurrent()
        case "deleteChat":
            if let id = body["id"] as? String { deleteChat(id) }
        case "setProvider":
            if let p = body["provider"] as? String { model.provider = p }
        case "copy":
            if let t = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        case "openLink":
            if let s = body["url"] as? String, let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u)
            }
        case "openVisual":
            if let html = body["html"] as? String { VisualWindow.show(html: html) }
        default:
            break
        }
    }

    // MARK: sending

    private var prerendered = Set<String>()
    /// Question id -> the pictures and quote it took out of the chat box (in memory), until an answer comes back.
    private var askedWith: [String: AskedWith] = [:]

    /// What a question took out of the chat box. If none of its answers comes back (each failed, or was stopped before
    /// any text), it goes back in, so the question can be asked again.
    struct AskedWith {
        var images: [PendingImage]
        var quote: ChatQuote?
        /// Where it was asked (a quote belongs to that deck), and the chat a quoted answer came from.
        var deck: String
        var conversation: String
        var quoteConversation: String?
        /// Its answers still running.
        var runs: Set<String>

        enum Next { case wait, forget, giveBack }

        /// One of its answers ended (`status`, `text`). An answer is any text, unless the run failed.
        mutating func ended(_ run: String, status: ChatMessage.Status, text: String) -> Next {
            guard runs.remove(run) != nil else { return .wait }
            if status == .done || status == .stopped && !text.isEmpty { return .forget }
            return runs.isEmpty ? .giveBack : .wait
        }

        /// The chat box with the pictures back in front: not ones already there or gone from the cache, and only as
        /// many as fit next to `pending` and the `inFlight` pictures still being prepared.
        func pictures(before pending: [PendingImage], inFlight: Int) -> [PendingImage] {
            let room = max(0, ImageAttachments.maxPending - pending.count - inFlight)
            let back = images.filter { i in
                !pending.contains { $0.id == i.id } && FileManager.default.fileExists(atPath: i.url.path)
            }
            return Array(back.prefix(room)) + pending
        }

        /// The note under the chat box for what came back (nil: nothing did).
        static func backNote(pictures n: Int, quote: Bool) -> String? {
            let things = [n > 1 ? "pictures" : n == 1 ? "picture" : nil, quote ? "quoted passage" : nil].compactMap { $0 }
            guard !things.isEmpty else { return nil }
            let verb = n > 1 || things.count > 1 ? "are" : "is"
            return "The \(things.joined(separator: " and the ")) from the unanswered question \(verb) back in the chat box."
        }
    }

    /// A changed PDF or linked file set invalidates both providers' cached context, including history
    /// conversations. Cancel affected active runs before their old file manifest can be used again.
    func sourcesDidChange(for deck: Deck) {
        let revision = SourceRevision.context(for: deck)
        let equivalent = SourceRevision.equivalents(for: deck)
        var changed = false
        for conversation in store.conversations(deck.path) {
            // Stamped by an earlier version for the same sources: keep the session under the new stamp.
            let same = Provider.allCases.filter { p in conversation.contextRevisions?[p.rawValue].map(equivalent.contains) ?? false }
            if !same.isEmpty {
                store.update(deck.path, conversation.id) { c in for p in same { c.restamp(revision, for: p) } }
                changed = true
            }
            let affected = Provider.allCases.filter { conversation.contextRevisions?[$0.rawValue] != revision && !same.contains($0) }
            guard !affected.isEmpty else { continue }
            for (id, whereAt) in runWhere where whereAt.deck == deck.path && whereAt.conv == conversation.id {
                guard let p = conversation.messages.first(where: { $0.id == id })?.provider,
                      affected.contains(p), let handle = running.removeValue(forKey: id) else { continue }
                stopping[id] = handle
                handle.cancel()
                store.update(deck.path, conversation.id) { c in
                    if let i = c.messages.firstIndex(where: { $0.id == id }) { c.messages[i].activity = "stopping…" }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.forceStopped(id) }
            }
            store.update(deck.path, conversation.id) { c in
                for provider in affected { c.prepareContext(revision, for: provider) }
            }
            changed = true
        }
        if changed { store.save(deck.path); showCurrent() }
    }

    /// One conversation per deck. Each assistant's session gets the deck's text once, then only what it hasn't
    /// seen: the image of the slide the student is on, images of slides the question mentions, a selected area, and
    /// the other assistant's messages. In a web tab, the page instead of a slide (sendWeb).
    func send(text: String, display: String?, choice: String, useArea: Bool, imageIDs: [String] = [], quoteID: String? = nil) {
        if model.deck?.isWeb == true {
            sendWeb(text: text, display: display, choice: choice, useArea: useArea, imageIDs: imageIDs, quoteID: quoteID)
            return
        }
        guard model.refreshDocumentIfNeeded() else { return }
        guard let deck = model.deck, let doc = model.document else { return }
        let page = model.page, count = model.pageCount
        let providers = Self.providers(choice)
        // Only the assistants being asked must be free (one session can't answer two questions at once).
        if isBusy(providers, deck: deck.path) { return }
        let q = beginQuestion(deck: deck, page: page, text: text, display: display, providers: providers,
                              useArea: useArea, imageIDs: imageIDs, quoteID: quoteID)
        let conv = q.conv, convID = q.convID

        // Asked with the notes, "p. 12" or "page 7" means a page of the notes.
        let withNotes = q.quote?.kind == "notes" || q.shots.contains { $0.fromNotes }
        let mentioned = DeckContext.referencedSlides(in: text, pageCount: count, slidesOnly: withNotes)
        for (p, answerID) in zip(providers, q.answerIDs) {
            let resume = conv.session(for: p)
            let fresh = resume == nil
            let seenSlides = fresh ? [] : Set(conv.seenSlides?[p.rawValue] ?? [])
            var prompt = ""
            if fresh {
                prompt += DeckContext.header(deck: deck, texts: model.slideTexts, includeFiles: p == .claude)
                prompt += Self.transcript(Array(q.prior.suffix(12)), tag: "earlier_conversation_about_this_deck")
            } else {
                prompt += unseenTranscript(conv, for: p, prior: q.prior)
            }
            var images: [URL] = []
            var shown: [Int] = []
            for n in [page] + mentioned where !seenSlides.contains(n) && !shown.contains(n) && shown.count < 5 {
                if let u = SlideImages.png(deck: deck, document: doc, page: n) { images.append(u); shown.append(n) }
            }
            if let a = q.area { images.append(a.url) }
            images += q.shots.map(\.url)
            if let quote = q.quote { prompt += DeckContext.excerpt(quote, for: p, otherChat: q.quoteFromOtherChat) }
            prompt += DeckContext.questionNote(page: page, count: count, slides: shown, area: q.area != nil,
                                               images: q.shots.map(\.detail), quote: q.quote != nil)
                + "\n<question>\n\(text)\n</question>"

            let before = SeenBefore(provider: p, fresh: fresh, by: conv.seenBy?[p.rawValue], slides: conv.seenSlides?[p.rawValue],
                                    view: conv.seenViews?[p.rawValue])
            store.update(deck.path, convID) { c in
                var sb = c.seenBy ?? [:]
                sb[p.rawValue] = q.prior.map(\.id) + [q.user.id]
                c.seenBy = sb
                var ss = c.seenSlides ?? [:]
                ss[p.rawValue] = Array(Set(seenSlides).union(shown)).sorted()
                c.seenSlides = ss
            }
            let cfg = addAnswer(answerID, by: p, deck: deck.path, conv: convID, page: page, activity: "starting…")
            seenBefore[answerID] = before
            var dirs = readableDirs(for: deck)
            if p == .claude { dirs.append(SlideImages.folder(for: deck)) }
            run(answerID, by: p, deck: deck.path, conv: convID, resume: resume,
                BackendRequest(prompt: prompt, instructions: Prompts.tutor, imageURLs: images, resume: resume,
                               model: cfg.model, effort: cfg.effort, fastMode: cfg.fast, readableDirs: dirs))
        }
        // Claude may open any slide image of the deck; make them all once (in the background).
        let slideDir = SlideImages.folder(for: deck).path
        if !prerendered.contains(slideDir) {
            prerendered.insert(slideDir)
            SlideImages.prerenderAll(deck: deck)
        }
        store.save(deck.path)
        model.refreshChatPages()
    }

    private static func providers(_ choice: String) -> [Provider] {
        choice == "both" ? [.claude, .codex] : [Provider(rawValue: choice) ?? .claude]
    }

    /// One of these assistants is still answering in the deck's conversation.
    private func isBusy(_ providers: [Provider], deck: String) -> Bool {
        store.current(deck).messages.contains { $0.status == .streaming && providers.contains($0.provider ?? .claude) }
    }

    /// A question as it went out: in the conversation (its message on screen), with what it took from the chat box.
    private struct Question {
        var conv: Conversation
        var convID: String
        var user: ChatMessage
        /// Everything finished before it.
        var prior: [ChatMessage]
        var area: Area?
        var shots: [PendingImage]
        var quote: ChatQuote?
        var quoteFromOtherChat: Bool
        /// Its answers' ids, one per assistant asked (known before any run starts: a run can fail inside start()).
        var answerIDs: [String]
    }

    /// Puts the question in the deck's conversation and takes what goes with it out of the chat box (an area, the
    /// pictures the chat box showed, a quote), to come back if no answer does.
    private func beginQuestion(deck: Deck, page: Int, text: String, display: String?, providers: [Provider],
                               useArea: Bool, imageIDs: [String], quoteID: String?) -> Question {
        sourcesDidChange(for: deck)
        let conv = store.current(deck.path)
        let convID = conv.id
        let areaNow = useArea ? area.flatMap { $0.deck == deck.path && $0.page == page ? $0 : nil } : nil
        // Only what the chat box showed goes (a picture still being read waits for the next question).
        let shots = pendingImages.filter { imageIDs.contains($0.id) }
        let quoteNow = quoteID != nil && pendingQuote?.id == quoteID && quoteDeck == deck.path ? pendingQuote : nil
        let quoteFrom = quoteNow == nil ? nil : quoteConversation
        // Part of an answer from another chat (New chat or History since then): not in this conversation.
        let quoteFromOtherChat = quoteNow?.kind == "reply" && quoteFrom != nil && quoteFrom != convID

        var user = ChatMessage(role: .user, text: text, display: display)
        user.page = page
        user.areaThumb = areaNow?.thumb
        if !shots.isEmpty { user.images = shots.map { MessageImage(label: $0.label, thumb: $0.thumb) } }
        user.quote = quoteNow
        // Everything finished so far (answers still streaming are not "said" yet).
        let prior = conv.messages.filter { $0.status != .streaming && !$0.text.isEmpty }
        store.update(deck.path, convID) { $0.messages.append(user) }
        push(user, deck: deck.path, conv: convID, immediate: true)
        if areaNow != nil { clearArea() }   // an area goes with one question, and so do pictures and a quote
        let answerIDs = providers.map { _ in UUID().uuidString }
        if !shots.isEmpty || quoteNow != nil {
            pendingImages.removeAll { p in shots.contains { $0.id == p.id } }
            if quoteNow != nil { dropQuote() }
            pushAttachments()
            askedWith[user.id] = AskedWith(images: shots, quote: quoteNow, deck: deck.path, conversation: convID,
                                           quoteConversation: quoteFrom, runs: Set(answerIDs))
        }
        return Question(conv: conv, convID: convID, user: user, prior: prior, area: areaNow, shots: shots, quote: quoteNow,
                        quoteFromOtherChat: quoteFromOtherChat, answerIDs: answerIDs)
    }

    /// For a session that has its own turns: what it hasn't seen, the other assistant's answers and questions that
    /// were sent only to the other one.
    private func unseenTranscript(_ conv: Conversation, for p: Provider, prior: [ChatMessage], web: Deck? = nil) -> String {
        let seen = Set(conv.seenBy?[p.rawValue] ?? prior.map(\.id))
        let unseen = prior.filter { !seen.contains($0.id) && ($0.provider != p || $0.notInSession == true) }
        guard let web else { return Self.transcript(unseen, tag: "messages_in_this_chat_you_have_not_seen", you: p) }
        return Self.transcript(unseen, tag: "messages_in_this_chat_you_have_not_seen", you: p, place: webPlace(web), unit: "page")
    }

    /// Where a question in a web tab was asked: “Linear Transformations” (its page's title), or "page 4".
    private func webPlace(_ book: Deck) -> (Int) -> String {
        let books = model.webBooks
        return { n in books.page(book.path, n)?.title.nonEmpty.map { "on “\($0)”" } ?? "page \(n)" }
    }

    /// The answer's bubble (streaming, `activity` until text comes), labelled with the model and effort asked now.
    private func addAnswer(_ id: String, by p: Provider, deck: String, conv convID: String, page: Int,
                           activity: String) -> (model: String, effort: String, fast: Bool) {
        var a = ChatMessage(id: id, role: .assistant, provider: p, text: "", status: .streaming)
        a.activity = activity
        a.page = page
        let (mid, eff) = p == .claude ? (model.claudeModel, model.claudeEffort) : (model.codexModel, model.codexEffort)
        let fastMode = p == .codex && model.codexFastMode
        a.model = ModelCatalog.label(p, mid) + " · " + eff + (fastMode ? " · Fast" : "")
        store.update(deck, convID) { $0.messages.append(a) }
        push(a, deck: deck, conv: convID, immediate: true)
        return (mid, eff, fastMode)
    }

    /// Starts the assistant's run for the answer `id`.
    private func run(_ id: String, by p: Provider, deck: String, conv convID: String, resume: String?, _ req: BackendRequest) {
        #if DEBUG
        DebugScript.logRequest(req, provider: p)
        #endif
        let backend: Backend = p == .claude ? claude : codex
        runWhere[id] = (deck, convID)
        let handle = backend.start(req) { [weak self] ev in
            self?.apply(ev, id: id, provider: p, deck: deck, conv: convID, usedResume: resume)
        }
        if let handle { running[id] = handle }
    }

    // MARK: asking in a web tab

    /// A question in a web tab. It shows at once, with its answers "reading the page…" while the page is read (its
    /// text, what is on screen and a picture of it); then each assistant gets the book once, a page's text the first
    /// time a question is asked on it, and the picture of the screen when that part of the page changed since the last
    /// picture it got. Claude has no tools here: nothing on a web page can make it read a file.
    private func sendWeb(text: String, display: String?, choice: String, useArea: Bool, imageIDs: [String], quoteID: String?) {
        guard let deck = model.deck, deck.isWeb, let tab = model.web else { return }
        let page = model.page
        let providers = Self.providers(choice)
        if isBusy(providers, deck: deck.path) { return }
        let q = beginQuestion(deck: deck, page: page, text: text, display: display, providers: providers,
                              useArea: useArea, imageIDs: imageIDs, quoteID: quoteID)
        var configs: [String: (model: String, effort: String, fast: Bool)] = [:]
        for (p, id) in zip(providers, q.answerIDs) {
            configs[id] = addAnswer(id, by: p, deck: deck.path, conv: q.convID, page: page, activity: "reading the page…")
            runWhere[id] = (deck.path, q.convID)   // Stop finds it while it waits
            awaitingPage.insert(id)
        }
        store.save(deck.path)
        model.refreshChatPages()
        tab.snapshot(root: deck.path) { [weak self] snap in
            self?.askWeb(q, deck: deck, page: page, providers: providers, configs: configs, snap: snap)
        }
    }

    private func askWeb(_ q: Question, deck: Deck, page: Int, providers: [Provider],
                        configs: [String: (model: String, effort: String, fast: Bool)], snap: WebSnapshot) {
        // Answers stopped (or their chat deleted) while the page was read are left out.
        let asked = zip(providers, q.answerIDs).filter { awaitingPage.remove($0.1) != nil }
        guard !asked.isEmpty, let conv = store.conversation(deck.path, q.convID) else { return }
        let url = snap.url.map { WebAddress.pageKey($0) } ?? model.webBooks.page(deck.path, page)?.url ?? deck.path
        let title = snap.page?.title.nonEmpty ?? snap.title.nonEmpty ?? model.webBooks.page(deck.path, page)?.title.nonEmpty
            ?? WebAddress.label(url)
        let viewKey = snap.viewKey
        // The text is of the question's page (not one still on screen while the next one loads): only then does it count
        // as that page's text.
        let askedPage = model.webBooks.page(deck.path, page)?.url
        let readThisPage = snap.page?.url.flatMap(URL.init(string:)).map(WebAddress.pageKey).map { $0 == askedPage } ?? true
        var viewShot: PendingImage?   // written once, for each assistant that needs it
        for (p, id) in asked {
            let resume = conv.session(for: p)
            let fresh = resume == nil
            let seenPages = fresh ? [] : Set(conv.seenSlides?[p.rawValue] ?? [])
            let lastView = fresh ? nil : conv.seenViews?[p.rawValue]
            var prompt = ""
            if fresh {
                prompt += WebContext.header(book: deck)
                prompt += Self.transcript(Array(q.prior.suffix(12)), tag: "earlier_conversation_about_this_web_book",
                                          place: webPlace(deck), unit: "page")
            } else {
                prompt += unseenTranscript(conv, for: p, prior: q.prior, web: deck)
            }
            var newPages: [Int] = []
            if !seenPages.contains(page), readThisPage, let t = snap.page, !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt += WebContext.page(t, url: url)
                newPages.append(page)
            }
            var images: [URL] = []
            var sentView = false
            if lastView != viewKey, let image = snap.view {
                if viewShot == nil { viewShot = ImageAttachments.make(image: image, label: "On screen", detail: "") }
                if let v = viewShot { images.append(v.url); sentView = true }
            }
            if let a = q.area { images.append(a.url) }
            images += q.shots.map(\.url)
            if let quote = q.quote { prompt += DeckContext.excerpt(quote, for: p, otherChat: q.quoteFromOtherChat) }
            prompt += WebContext.questionNote(title: title, url: url, screen: snap.screen, view: sentView,
                                              sameView: lastView == viewKey, area: q.area.map { $0.section ?? "" },
                                              images: q.shots.map(\.detail), quote: q.quote != nil)
                + "\n<question>\n\(q.user.text)\n</question>"

            let before = SeenBefore(provider: p, fresh: fresh, by: conv.seenBy?[p.rawValue], slides: conv.seenSlides?[p.rawValue],
                                    view: conv.seenViews?[p.rawValue])
            store.update(deck.path, q.convID) { c in
                var sb = c.seenBy ?? [:]
                sb[p.rawValue] = q.prior.map(\.id) + [q.user.id]
                c.seenBy = sb
                var ss = c.seenSlides ?? [:]
                ss[p.rawValue] = Array(seenPages.union(newPages)).sorted()
                c.seenSlides = ss
                if sentView {
                    var sv = c.seenViews ?? [:]
                    sv[p.rawValue] = viewKey
                    c.seenViews = sv
                }
                if let i = c.messages.firstIndex(where: { $0.id == id }), c.messages[i].status == .streaming {
                    c.messages[i].activity = "starting…"
                }
            }
            if let m = store.conversation(deck.path, q.convID)?.messages.first(where: { $0.id == id }) {
                push(m, deck: deck.path, conv: q.convID, immediate: true)
            }
            seenBefore[id] = before
            let cfg = configs[id] ?? (model: model.claudeModel, effort: model.claudeEffort, fast: false)
            run(id, by: p, deck: deck.path, conv: q.convID, resume: resume,
                BackendRequest(prompt: prompt, instructions: Prompts.webTutor, imageURLs: images, resume: resume,
                               model: cfg.model, effort: cfg.effort, fastMode: cfg.fast, readableDirs: [], toolsOff: true))
        }
        store.save(deck.path)
    }

    /// Earlier messages as a quoted block, for an assistant that has not seen them. Pictures are not sent again; the
    /// assistant is told which were there (by their labels). A quoted passage is text, so it comes along.
    /// `place` names where a message was asked ("slide 4"; in a web tab, the page's title), `unit` what an area is of.
    static func transcript(_ msgs: [ChatMessage], tag: String, you: Provider? = nil,
                           place: (Int) -> String = { "slide \($0)" }, unit: String = "slide") -> String {
        guard !msgs.isEmpty else { return "" }
        var s = "<\(tag)>\n"
        for m in msgs {
            var who = m.role == .user ? "Student" : (m.provider?.displayName ?? "Assistant")
            if m.role == .assistant, let you, m.provider == you {
                who += " (your own earlier answer as the student saw it; it was cut off before it reached you)"
            }
            let whereAt = m.page.map { ", " + place($0) } ?? ""
            var body = m.text.count > 2500 ? String(m.text.prefix(2500)) + " …" : m.text
            if m.role == .user {
                if m.areaThumb != nil { body += " [asked about an area of the \(unit) that the student selected]" }
                if let images = m.images, !images.isEmpty {
                    let names = images.map { "“\($0.label)”" }.joined(separator: ", ")
                    body += " [\(images.count == 1 ? "an image" : "\(images.count) images") the student attached went with this, "
                        + "not included here: \(names)]"
                }
                if let q = m.quote {
                    let clip = q.text.count > 1500 ? String(q.text.prefix(1500)) + " …" : q.text
                    body += "\n(With this passage quoted from \(q.source)\(q.section.map { " › \($0)" } ?? ""): \(clip))"
                }
            }
            s += "[\(who)\(whereAt)]: \(body)\n\n"
        }
        return s + "</\(tag)>\n\n"
    }

    private func readableDirs(for deck: Deck) -> [URL] {
        var dirs = Set<String>()
        dirs.insert(deck.url.deletingLastPathComponent().path)
        for f in deck.contextFiles { dirs.insert(URL(fileURLWithPath: f).deletingLastPathComponent().path) }
        for w in deck.walkthroughs { dirs.insert(URL(fileURLWithPath: w.path).deletingLastPathComponent().path) }
        return dirs.sorted().map { URL(fileURLWithPath: $0) }
    }

    private func apply(_ ev: BackendEvent, id: String, provider: Provider, deck: String, conv: String, usedResume: String?) {
        // The deck's PDF may have been renamed or moved since the question was sent (followMoves keeps runWhere current).
        let deck = runWhere[id]?.deck ?? deck
        if case .usage(let w) = ev { setUsage(provider, w); return }
        if case .saved = ev { saved.insert(id); return }
        var updated: ChatMessage?
        var finished = false
        var sessionChanged = false
        store.update(deck, conv) { t in
            guard let i = t.messages.firstIndex(where: { $0.id == id }) else { return }
            var m = t.messages[i]
            switch ev {
            case .session(let s):
                // A stopped run's late session id must not replace the one a newer question is using.
                guard running[id] != nil else { break }
                if t.session(for: provider) != s { t.setSession(s, for: provider) }
                sessionChanged = true
            case .model(let name):
                m.model = name
            case .delta(let s):
                m.text += s
                if stopping[id] == nil { m.activity = nil }   // keep "stopping…"
            case .replace(let s):
                m.text = s
            case .activity(let a):
                if stopping[id] == nil { m.activity = a }
            case .finished:
                if m.status == .streaming {
                    // Stopped, unless the turn had already completed when Stop was pressed.
                    m.status = running[id] == nil && !saved.contains(id) ? .stopped : (m.text.isEmpty ? .error : .done)
                    if m.status == .error { m.error = "No answer came back." }
                }
                m.activity = nil
                finished = true
            case .usage, .saved:
                break   // handled before the update
            case .notKept:
                if !m.text.isEmpty { m.notInSession = true }
            case .failed(let e):
                m.status = .error
                m.error = e
                m.needsSignIn = SignIn.isSignInError(e, provider) ? true : nil
                m.activity = nil
                finished = true
                // Only a missing/broken session is dropped (then the next question re-sends the deck);
                // limits, overload and network errors keep it.
                let l = e.lowercased()
                if usedResume != nil,
                   l.contains("no conversation found") || l.contains("session") && (l.contains("not found") || l.contains("invalid"))
                    || l.contains("rollout") || l.contains("thread") && l.contains("not found") {
                    t.setSession(nil, for: provider)
                }
            }
            t.messages[i] = m
            updated = m
            if finished {
                if m.status == .done { seenBefore[id] = nil } else { rollBackSeen(id, &t) }
            }
        }
        if finished {
            running.removeValue(forKey: id)
            stopping.removeValue(forKey: id)
            saved.remove(id)
            runWhere.removeValue(forKey: id)
        }
        if finished || sessionChanged { store.save(deck) }
        if let updated { push(updated, deck: deck, conv: conv, immediate: finished) }
        if finished, let updated { answerEnded(updated) }
    }

    /// A stopped or failed run: the assistant's session may not have taken in this turn, so it hasn't "seen"
    /// what was sent with it. A session that this run started is dropped (the next question starts afresh).
    private func rollBackSeen(_ id: String, _ c: inout Conversation) {
        guard let b = seenBefore.removeValue(forKey: id) else { return }
        if b.fresh { c.setSession(nil, for: b.provider); return }
        guard c.session(for: b.provider) != nil else { return }
        var sb = c.seenBy ?? [:]
        sb[b.provider.rawValue] = b.by
        c.seenBy = sb
        var ss = c.seenSlides ?? [:]
        ss[b.provider.rawValue] = b.slides
        c.seenSlides = ss
        if b.view != nil || c.seenViews?[b.provider.rawValue] != nil {
            var sv = c.seenViews ?? [:]
            sv[b.provider.rawValue] = b.view
            c.seenViews = sv.isEmpty ? nil : sv
        }
    }

    /// Stop: the answers still running in the deck's current conversation (on any slide), from the assistants
    /// being asked (`providers`; nil = all). In Both mode a follow-up to Claude alone doesn't stop ChatGPT.
    func stopVisible(providers: Set<Provider>? = nil) {
        guard let d = model.deck else { return }
        let conv = store.current(d.path), convID = conv.id
        for (id, w) in runWhere where w.deck == d.path && w.conv == convID {
            if let providers, let p = conv.messages.first(where: { $0.id == id })?.provider, !providers.contains(p) { continue }
            // Still waiting for its web page to be read: it never started, so it just ends here.
            if awaitingPage.remove(id) != nil {
                runWhere.removeValue(forKey: id)
                store.update(d.path, convID) { c in
                    if let i = c.messages.firstIndex(where: { $0.id == id }), c.messages[i].status == .streaming {
                        c.messages[i].status = .stopped
                        c.messages[i].activity = nil
                    }
                }
                store.save(d.path)
                if let m = store.current(d.path).messages.first(where: { $0.id == id }) {
                    push(m, deck: d.path, conv: convID, immediate: true)
                    answerEnded(m)
                }
                continue
            }
            guard let h = running.removeValue(forKey: id) else { continue }   // already stopping
            stopping[id] = h
            h.cancel()
            // The answer stays "stopping…" (so that assistant takes no new question) until its CLI has exited:
            // Claude Code saves the partial answer to the session first. apply(.finished) then marks it stopped
            // and settles what the assistant has seen, knowing whether the partial answer was kept.
            store.update(d.path, convID) { c in
                if let i = c.messages.firstIndex(where: { $0.id == id }), c.messages[i].status == .streaming {
                    c.messages[i].activity = "stopping…"
                }
            }
            if let m = store.current(d.path).messages.first(where: { $0.id == id }) {
                push(m, deck: d.path, conv: convID, immediate: true)
            }
            // cancel() ends the process within ~3 s (SIGINT, then SIGTERM, then SIGKILL); if no exit is ever
            // reported, close the answer anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.forceStopped(id) }
        }
    }

    /// Safety net for a stopped run whose exit was never reported.
    private func forceStopped(_ id: String) {
        guard let w = runWhere[id], running[id] == nil else { return }
        runWhere.removeValue(forKey: id)
        stopping.removeValue(forKey: id)?.terminateNow()
        saved.remove(id)
        store.update(w.deck, w.conv) { c in
            if let i = c.messages.firstIndex(where: { $0.id == id }), c.messages[i].status == .streaming {
                c.messages[i].status = .stopped
                c.messages[i].activity = nil
            }
            rollBackSeen(id, &c)
        }
        store.save(w.deck)
        if let m = store.conversation(w.deck, w.conv)?.messages.first(where: { $0.id == id }) {
            push(m, deck: w.deck, conv: w.conv, immediate: true)
            answerEnded(m)
        }
    }

    /// An answer's run ended (apply or forceStopped; not on quit). Once every answer to a question failed or was
    /// stopped before any text, its pictures and quote go back into the chat box, so it can be asked again.
    private func answerEnded(_ m: ChatMessage) {
        guard let question = askedWith.first(where: { $0.value.runs.contains(m.id) })?.key,
              var sent = askedWith.removeValue(forKey: question) else { return }
        switch sent.ended(m.id, status: m.status, text: m.text) {
        case .wait: askedWith[question] = sent
        case .forget: break
        case .giveBack: giveBack(sent)
        }
    }

    /// Puts an unanswered question's pictures in front of the chat box, and its quote if the box has none and its
    /// deck is open, with a note saying so.
    private func giveBack(_ sent: AskedWith) {
        let before = pendingImages.count
        pendingImages = sent.pictures(before: pendingImages, inFlight: imagesInFlight)
        var quote = false
        if let q = sent.quote, pendingQuote == nil, model.deck?.path == sent.deck {
            pendingQuote = q
            quoteDeck = sent.deck
            quoteConversation = sent.quoteConversation
            quote = true
        }
        guard let text = AskedWith.backNote(pictures: pendingImages.count - before, quote: quote) else { return }
        pushAttachments()
        note(text, error: false)
    }

    private func deleteChat(_ id: String) {
        guard let d = model.deck, let c = store.conversation(d.path, id) else { return }
        let a = NSAlert()
        a.messageText = "Delete this chat?"
        a.informativeText = "It has \(c.messages.filter { $0.role == .user }.count) questions. This can't be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for (rid, w) in runWhere where w.deck == d.path && w.conv == id {
            running.removeValue(forKey: rid)?.cancel()
            awaitingPage.remove(rid)
            stopping.removeValue(forKey: rid)
            saved.remove(rid)
            runWhere.removeValue(forKey: rid)
            seenBefore.removeValue(forKey: rid)
        }
        // Its questions' pictures go with it.
        askedWith = askedWith.filter { $0.value.deck != d.path || $0.value.conversation != id }
        store.delete(d.path, id)
        model.refreshChatPages()
        showCurrent()
    }

    /// On quit: keep what has streamed so far, mark it stopped, save, and end the CLIs right away.
    func stopAll() {
        askedWith.removeAll()   // nothing goes back into the chat box on the way out
        awaitingPage.removeAll()   // never started: marked stopped below with the rest
        // Stop the way the Stop button does (SIGINT), so Claude Code keeps the partial answer in its session;
        // give the CLIs a moment, then end whatever is still running.
        for (id, h) in running { h.cancel(); stopping[id] = h }
        running.removeAll()   // apply(.finished) now reads these as stopped, unless the turn was saved
        let all = stopping
        let deadline = Date().addingTimeInterval(1.5)
        // Spin the run loop (not sleep) so queued output and exit reports reach apply() and settle each run;
        // apply(.finished) removes a run from `stopping` (and `runWhere`) once its exit is in.
        while !stopping.isEmpty && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        var decks = Set<String>()
        for (id, w) in runWhere {
            let h = all[id]
            let done = saved.contains(id)
            let lost = !done && (h.map { $0.isRunning || ($0.exitStatus ?? 0) != 0 } ?? false)
            store.update(w.deck, w.conv) { c in
                if let i = c.messages.firstIndex(where: { $0.id == id }), c.messages[i].status == .streaming {
                    c.messages[i].status = done ? .done : .stopped
                    c.messages[i].activity = nil
                    if lost, c.messages[i].provider == .claude, !c.messages[i].text.isEmpty { c.messages[i].notInSession = true }
                }
                if done { seenBefore[id] = nil } else { rollBackSeen(id, &c) }
            }
            decks.insert(w.deck)
        }
        for d in decks { store.save(d) }
        for (_, h) in all where h.isRunning { h.terminateNow() }
        stopping.removeAll()
        saved.removeAll()
        running.removeAll()
        runWhere.removeAll()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let u = action.request.url
        let isMain = action.targetFrame?.isMainFrame ?? true
        if isMain {
            // Only the initial load (or a reload) of chat.html itself; links open in the browser.
            if action.navigationType != .formSubmitted, let u, u.isFileURL, u.lastPathComponent == "chat.html", u.query == nil {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, let u, ["http", "https"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u)
            }
            decisionHandler(.cancel)
            return
        }
        // Visual iframes: their srcdoc, plus the scripts and styles a visual may pull from a CDN.
        if action.navigationType == .formSubmitted || action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(["about", "https", "data", "blob"].contains(u?.scheme ?? "about") ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.reload()
    }
}

/// WKUserContentController keeps its handlers alive; this breaks the cycle.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: ChatController?
    init(_ t: ChatController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit exposes handlers to every frame, including the sandboxed "Visualize it" iframes;
        // only the chat page's own main frame may send commands.
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.lastPathComponent == "chat.html",
              let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { target?.handle(body) }
    }
}
