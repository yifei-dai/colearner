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
    private var runWhere: [String: (deck: String, page: Int)] = [:]
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
        webView.window?.makeFirstResponder(webView)
        guard ready else { return }
        webView.evaluateJavaScript("window.CL && CL.focusInput()", completionHandler: nil)
    }

    /// Re-render the chat panel for the slide on screen.
    func showCurrent() {
        guard ready else { return }
        dirty.removeAll()
        guard let d = model.deck else {
            js("setThread", ["hasDeck": false, "messages": [], "others": [], "provider": model.provider])
            return
        }
        let t = store.thread(d.path, model.page)
        js("setThread", [
            "hasDeck": true, "deckTitle": d.title, "page": model.page, "pageCount": model.pageCount,
            "messages": t.messages.map(\.js), "others": store.pagesWithChats(d.path), "provider": model.provider,
        ] as [String: Any])
    }

    private func isVisible(_ deck: String, _ page: Int) -> Bool {
        model.deck?.path == deck && model.page == page
    }

    private func push(_ m: ChatMessage, deck: String, page: Int, immediate: Bool = false) {
        guard isVisible(deck, page) else { return }
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
            send(text: text, display: display, choice: p)
        case "stop":
            stopVisible()
        case "gotoSlide":
            if let p = body["page"] as? Int { model.page = p }
        case "clearThread":
            clearVisible()
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

    func send(text: String, display: String?, choice: String) {
        guard let deck = model.deck, let doc = model.document else { return }
        let page = model.page
        let providers: [Provider] = choice == "both" ? [.claude, .codex] : [Provider(rawValue: choice) ?? .claude]
        let before = store.thread(deck.path, page)
        // Only the assistants being asked must be free (in Both mode Claude often finishes long before ChatGPT).
        if before.messages.contains(where: { $0.status == .streaming && providers.contains($0.provider ?? .claude) }) { return }

        var context: SlideContext?
        let user = ChatMessage(role: .user, text: text, display: display)
        store.update(deck.path, page) { $0.messages.append(user) }
        push(user, deck: deck.path, page: page, immediate: true)
        // Everything finished so far on this slide (answers still streaming are not "said" yet).
        let prior = before.messages.filter { $0.status != .streaming && !$0.text.isEmpty }

        for p in providers {
            let resume = before.session(for: p)
            var prompt: String
            var image: URL?
            if resume == nil {
                if context == nil { context = SlideContext.make(deck: deck, document: doc, page: page, texts: model.slideTexts) }
                guard let ctx = context else { continue }
                prompt = ctx.promptHeader(includeFiles: p == .claude)
                    + transcript(Array(prior.suffix(8)), tag: "earlier_conversation_on_this_slide")
                    + "<question>\n\(text)\n</question>"
                image = ctx.pngURL
            } else {
                // The session already has its own turns; add what it hasn't seen: the other assistant's answers
                // (so "ChatGPT says 2 solutions, you say 4" works) and questions that were sent only to the other one.
                let seen = Set(before.seenBy?[p.rawValue] ?? prior.map(\.id))
                let missed = prior.filter { !seen.contains($0.id) && $0.provider != p }
                prompt = missed.isEmpty ? text
                    : transcript(missed, tag: "messages_on_this_slide_you_have_not_seen") + "<question>\n\(text)\n</question>"
            }
            store.update(deck.path, page) { t in
                var map = t.seenBy ?? [:]
                map[p.rawValue] = prior.map(\.id) + [user.id]
                t.seenBy = map
            }
            var a = ChatMessage(role: .assistant, provider: p, text: "", status: .streaming)
            a.activity = "starting…"
            let (mid, eff) = p == .claude ? (model.claudeModel, model.claudeEffort) : (model.codexModel, model.codexEffort)
            a.model = ModelCatalog.label(p, mid) + " · " + eff
            store.update(deck.path, page) { $0.messages.append(a) }
            push(a, deck: deck.path, page: page, immediate: true)

            let req = BackendRequest(
                prompt: prompt, instructions: Prompts.tutor, imageURL: image, resume: resume,
                model: mid, effort: eff,
                readableDirs: readableDirs(for: deck))
            let id = a.id
            let backend: Backend = p == .claude ? claude : codex
            runWhere[id] = (deck.path, page)
            let handle = backend.start(req) { [weak self] ev in
                self?.apply(ev, id: id, provider: p, deck: deck.path, page: page, usedResume: resume)
            }
            if let handle { running[id] = handle }
        }
        store.save(deck.path)
        model.refreshChatPages()
    }

    /// Earlier messages as a quoted block, for an assistant that has not seen them.
    private func transcript(_ msgs: [ChatMessage], tag: String) -> String {
        guard !msgs.isEmpty else { return "" }
        var s = "<\(tag)>\n"
        for m in msgs {
            let who = m.role == .user ? "Student" : (m.provider?.displayName ?? "Assistant")
            let body = m.text.count > 2500 ? String(m.text.prefix(2500)) + " …" : m.text
            s += "[\(who)]: \(body)\n\n"
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

    private func apply(_ ev: BackendEvent, id: String, provider: Provider, deck: String, page: Int, usedResume: String?) {
        if case .usage(let w) = ev { setUsage(provider, w); return }
        var updated: ChatMessage?
        var finished = false
        var sessionChanged = false
        store.update(deck, page) { t in
            guard let i = t.messages.firstIndex(where: { $0.id == id }) else { return }
            var m = t.messages[i]
            switch ev {
            case .session(let s):
                t.setSession(s, for: provider)
                sessionChanged = true
            case .model(let name):
                m.model = name
            case .delta(let s):
                m.text += s
                m.activity = nil
            case .replace(let s):
                m.text = s
            case .activity(let a):
                m.activity = a
            case .finished:
                if m.status == .streaming {
                    m.status = running[id] == nil ? .stopped : (m.text.isEmpty ? .error : .done)
                    if m.status == .error { m.error = "No answer came back." }
                }
                m.activity = nil
                finished = true
            case .usage:
                break   // handled before the update
            case .failed(let e):
                m.status = .error
                m.error = e
                m.activity = nil
                finished = true
                // Only a missing/broken session is dropped (then the next question re-sends the slide);
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
        }
        if finished {
            running.removeValue(forKey: id)
            runWhere.removeValue(forKey: id)
        }
        if finished || sessionChanged { store.save(deck) }
        if let updated { push(updated, deck: deck, page: page, immediate: finished) }
    }

    func stopVisible() {
        guard let d = model.deck else { return }
        let page = model.page
        for (id, w) in runWhere where w.deck == d.path && w.page == page {
            if let h = running.removeValue(forKey: id) { h.cancel() }
            store.update(d.path, page) { t in
                if let i = t.messages.firstIndex(where: { $0.id == id }), t.messages[i].status == .streaming {
                    t.messages[i].status = .stopped
                    t.messages[i].activity = nil
                }
            }
            if let m = store.thread(d.path, page).messages.first(where: { $0.id == id }) {
                push(m, deck: d.path, page: page, immediate: true)
            }
        }
        store.save(d.path)
    }

    private func clearVisible() {
        guard let d = model.deck else { return }
        let page = model.page
        let t = store.thread(d.path, page)
        guard !t.messages.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Delete the chat on slide \(page)?"
        a.informativeText = "This removes \(t.messages.count) messages. It can't be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for (id, w) in runWhere where w.deck == d.path && w.page == page {
            running.removeValue(forKey: id)?.cancel()
            runWhere.removeValue(forKey: id)
        }
        store.clear(d.path, page)
        model.refreshChatPages()
        showCurrent()
    }

    /// On quit: keep what has streamed so far, mark it stopped, save, and end the CLIs right away.
    func stopAll() {
        var decks = Set<String>()
        for (id, w) in runWhere {
            store.update(w.deck, w.page) { t in
                if let i = t.messages.firstIndex(where: { $0.id == id }), t.messages[i].status == .streaming {
                    t.messages[i].status = .stopped
                    t.messages[i].activity = nil
                }
            }
            decks.insert(w.deck)
        }
        for d in decks { store.save(d) }
        for (_, h) in running { h.terminateNow() }
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
