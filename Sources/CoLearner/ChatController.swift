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
    private var seenBefore: [String: (provider: Provider, fresh: Bool, by: [String]?, slides: [Int]?)] = [:]
    private var dirty: [String: ChatMessage] = [:]
    private var flushScheduled = false
    /// Last plan usage per assistant (kept across launches). Updated after every answer and on demand.
    private struct Usage { var plan: String?; var windows: [UsageWindow]; var updated: Double; var loading = false; var error: String? }
    private var usage: [Provider: Usage] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(self), name: "cl")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        let web = AppPaths.web
        webView.loadFileURL(web.appendingPathComponent("chat.html"), allowingReadAccessTo: web)
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
                "hint": ModelCatalog.effortHint,
                "updated": cat.updated[p] ?? 0,
                "refreshing": cat.refreshing,
            ]
        }
        js("setConfig", ["claude": entry(.claude, model.claudeModel, model.claudeEffort),
                         "codex": entry(.codex, model.codexModel, model.codexEffort)])
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
            d[p.rawValue] = e
        }
        js("setUsage", d)
    }

    func focusInput() {
        // A popped-out chat window has to become key to take typing.
        if NSApp.isActive, let w = webView.window, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
        webView.window?.makeFirstResponder(webView)
        guard ready else { return }
        webView.evaluateJavaScript("window.CL && CL.focusInput()", completionHandler: nil)
    }

    /// Re-render the chat panel: the deck's current conversation (chat.js shows this slide's part, or all).
    func showCurrent() {
        guard ready else { return }
        // Send queued updates first (in order), so the page's copy is current when setThread compares.
        for (_, m) in dirty { js("upsertMessage", m.js) }
        dirty.removeAll()
        guard let d = model.deck else {
            area = nil
            js("setThread", ["hasDeck": false, "messages": [], "pages": [], "provider": model.provider, "history": [],
                             "area": NSNull(), "conversation": NSNull()] as [String: Any])
            return
        }
        // A selected area belongs to its slide; moving on drops it.
        if let a = area, a.deck != d.path || a.page != model.page { area = nil }
        let conv = store.current(d.path)
        var areaJS: Any = NSNull()
        if let a = area { areaJS = ["page": a.page, "thumb": a.thumb] }
        js("setThread", [
            "hasDeck": true, "deckTitle": d.title, "page": model.page, "pageCount": model.pageCount,
            "messages": conv.messages.map(\.js), "pages": conv.pages, "provider": model.provider,
            "conversation": ["id": conv.id, "legacy": conv.legacy ?? false, "created": conv.created.timeIntervalSince1970],
            "history": store.conversations(d.path).map { c -> [String: Any] in
                ["id": c.id, "created": c.created.timeIntervalSince1970, "count": c.messages.filter { $0.role == .user }.count,
                 "legacy": c.legacy ?? false, "current": c.id == conv.id,
                 "first": c.messages.first(where: { $0.role == .user }).map { $0.display ?? String($0.text.prefix(60)) } ?? ""]
            },
            "area": areaJS,
        ] as [String: Any])
    }

    private func isVisible(_ deck: String, _ conv: String) -> Bool {
        model.deck?.path == deck && store.current(deck).id == conv
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

    /// An area of a slide the user cut out (button "Select area", or ⌥-drag on the slide).
    struct Area { var deck: String; var page: Int; var url: URL; var thumb: String }
    private(set) var area: Area?

    func setArea(page: Int, url: URL, thumb: String) {
        guard let d = model.deck else { return }
        area = Area(deck: d.path, page: page, url: url, thumb: thumb)
        js("setArea", ["page": page, "thumb": thumb])
        DispatchQueue.main.async { [weak self] in self?.focusInput() }
    }

    func clearArea() {
        area = nil
        js("setArea", NSNull())
    }

    func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            ready = true
            showCurrent()
            pushConfig()
            loadUsage()
            refreshModels()
        case "turn":
            if let d = body["delta"] as? Int { model.go(d) }
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
        case "send":
            let text = body["text"] as? String ?? ""
            let display = body["display"] as? String
            let p = body["provider"] as? String ?? model.provider
            if p != model.provider { model.provider = p }
            send(text: text, display: display, choice: p, useArea: body["useArea"] as? Bool ?? true)
        case "stop":
            let ps = (body["providers"] as? [String])?.compactMap(Provider.init(rawValue:))
            stopVisible(providers: ps.map(Set.init))
        case "gotoSlide":
            if let p = body["page"] as? Int { model.page = p }
        case "selectArea":
            model.beginAreaSelection()
        case "clearArea":
            clearArea()
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

    /// A changed PDF or linked file set invalidates both providers' cached context, including history
    /// conversations. Cancel affected active runs before their old file manifest can be used again.
    func sourcesDidChange(for deck: Deck) {
        let revision = SourceRevision.context(for: deck)
        var changed = false
        for conversation in store.conversations(deck.path) {
            let affected = Provider.allCases.filter { conversation.contextRevisions?[$0.rawValue] != revision }
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
    /// the other assistant's messages.
    func send(text: String, display: String?, choice: String, useArea: Bool) {
        guard model.refreshDocumentIfNeeded() else { return }
        guard let deck = model.deck, let doc = model.document else { return }
        let page = model.page, count = model.pageCount
        let providers: [Provider] = choice == "both" ? [.claude, .codex] : [Provider(rawValue: choice) ?? .claude]
        var conv = store.current(deck.path)
        // Only the assistants being asked must be free (one session can't answer two questions at once).
        if conv.messages.contains(where: { $0.status == .streaming && providers.contains($0.provider ?? .claude) }) { return }
        sourcesDidChange(for: deck)
        conv = store.current(deck.path)
        let convID = conv.id
        let areaNow = useArea ? area.flatMap { $0.deck == deck.path && $0.page == page ? $0 : nil } : nil

        var user = ChatMessage(role: .user, text: text, display: display)
        user.page = page
        user.areaThumb = areaNow?.thumb
        // Everything finished so far (answers still streaming are not "said" yet).
        let prior = conv.messages.filter { $0.status != .streaming && !$0.text.isEmpty }
        store.update(deck.path, convID) { $0.messages.append(user) }
        push(user, deck: deck.path, conv: convID, immediate: true)
        if areaNow != nil { clearArea() }   // an area goes with one question

        let mentioned = DeckContext.referencedSlides(in: text, pageCount: count)
        for p in providers {
            let resume = conv.session(for: p)
            let fresh = resume == nil
            let seenSlides = fresh ? [] : Set(conv.seenSlides?[p.rawValue] ?? [])
            var prompt = ""
            if fresh {
                prompt += DeckContext.header(deck: deck, texts: model.slideTexts, includeFiles: p == .claude)
                prompt += transcript(Array(prior.suffix(12)), tag: "earlier_conversation_about_this_deck")
            } else {
                // The session has its own turns; add what it hasn't seen: the other assistant's answers and
                // questions that were sent only to the other one.
                let seen = Set(conv.seenBy?[p.rawValue] ?? prior.map(\.id))
                let unseen = prior.filter { !seen.contains($0.id) && ($0.provider != p || $0.notInSession == true) }
                prompt += transcript(unseen, tag: "messages_in_this_chat_you_have_not_seen", you: p)
            }
            var images: [URL] = []
            var shown: [Int] = []
            for n in [page] + mentioned where !seenSlides.contains(n) && !shown.contains(n) && shown.count < 5 {
                if let u = SlideImages.png(deck: deck, document: doc, page: n) { images.append(u); shown.append(n) }
            }
            if let a = areaNow { images.append(a.url) }
            var note = "[The student is on slide \(page) of \(count).]"
            var parts = shown.map { "slide \($0)" }
            if areaNow != nil { parts.append("the area of slide \(page) the student selected") }
            if !parts.isEmpty { note += " Attached images, in order: " + parts.joined(separator: ", ") + "." }
            if areaNow != nil { note += " The question is about the selected area." }
            prompt += note + "\n<question>\n\(text)\n</question>"

            let before = (provider: p, fresh: fresh, by: conv.seenBy?[p.rawValue], slides: conv.seenSlides?[p.rawValue])
            store.update(deck.path, convID) { c in
                var sb = c.seenBy ?? [:]
                sb[p.rawValue] = prior.map(\.id) + [user.id]
                c.seenBy = sb
                var ss = c.seenSlides ?? [:]
                ss[p.rawValue] = Array(Set(seenSlides).union(shown)).sorted()
                c.seenSlides = ss
            }
            var a = ChatMessage(role: .assistant, provider: p, text: "", status: .streaming)
            a.activity = "starting…"
            a.page = page
            let (mid, eff) = p == .claude ? (model.claudeModel, model.claudeEffort) : (model.codexModel, model.codexEffort)
            a.model = ModelCatalog.label(p, mid) + " · " + eff
            seenBefore[a.id] = before
            store.update(deck.path, convID) { $0.messages.append(a) }
            push(a, deck: deck.path, conv: convID, immediate: true)

            var dirs = readableDirs(for: deck)
            if p == .claude { dirs.append(SlideImages.folder(for: deck)) }
            let req = BackendRequest(prompt: prompt, instructions: Prompts.tutor, imageURLs: images, resume: resume,
                                     model: mid, effort: eff, readableDirs: dirs)
            let id = a.id
            let backend: Backend = p == .claude ? claude : codex
            runWhere[id] = (deck.path, convID)
            let handle = backend.start(req) { [weak self] ev in
                self?.apply(ev, id: id, provider: p, deck: deck.path, conv: convID, usedResume: resume)
            }
            if let handle { running[id] = handle }
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

    /// Earlier messages as a quoted block, for an assistant that has not seen them.
    private func transcript(_ msgs: [ChatMessage], tag: String, you: Provider? = nil) -> String {
        guard !msgs.isEmpty else { return "" }
        var s = "<\(tag)>\n"
        for m in msgs {
            var who = m.role == .user ? "Student" : (m.provider?.displayName ?? "Assistant")
            if m.role == .assistant, let you, m.provider == you {
                who += " (your own earlier answer as the student saw it; it was cut off before it reached you)"
            }
            let whereAt = m.page.map { ", slide \($0)" } ?? ""
            let body = m.text.count > 2500 ? String(m.text.prefix(2500)) + " …" : m.text
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
    }

    /// Stop: the answers still running in the deck's current conversation (on any slide), from the assistants
    /// being asked (`providers`; nil = all). In Both mode a follow-up to Claude alone doesn't stop ChatGPT.
    func stopVisible(providers: Set<Provider>? = nil) {
        guard let d = model.deck else { return }
        let conv = store.current(d.path), convID = conv.id
        for (id, w) in runWhere where w.deck == d.path && w.conv == convID {
            if let providers, let p = conv.messages.first(where: { $0.id == id })?.provider, !providers.contains(p) { continue }
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
        }
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
            stopping.removeValue(forKey: rid)
            saved.remove(rid)
            runWhere.removeValue(forKey: rid)
            seenBefore.removeValue(forKey: rid)
        }
        store.delete(d.path, id)
        model.refreshChatPages()
        showCurrent()
    }

    /// On quit: keep what has streamed so far, mark it stopped, save, and end the CLIs right away.
    func stopAll() {
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
