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
        if before.messages.contains(where: { $0.status == .streaming }) { return }

        var context: SlideContext?
        let user = ChatMessage(role: .user, text: text, display: display)
        store.update(deck.path, page) { $0.messages.append(user) }
        push(user, deck: deck.path, page: page, immediate: true)

        for p in providers {
            let resume = before.session(for: p)
            var prompt = text
            var image: URL?
            if resume == nil {
                if context == nil { context = SlideContext.make(deck: deck, document: doc, page: page) }
                guard let ctx = context else { continue }
                prompt = ctx.promptHeader(includeFiles: p == .claude) + earlierTurns(before, for: p) + "<question>\n\(text)\n</question>"
                image = ctx.pngURL
            }
            var a = ChatMessage(role: .assistant, provider: p, text: "", status: .streaming)
            a.activity = "starting…"
            store.update(deck.path, page) { $0.messages.append(a) }
            push(a, deck: deck.path, page: page, immediate: true)

            let req = BackendRequest(
                prompt: prompt, instructions: Prompts.tutor, imageURL: image, resume: resume,
                model: p == .claude ? model.claudeModel : nil,
                effort: p == .codex ? model.codexEffort : nil,
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

    /// When a provider joins a slide conversation late, tell it what was said so far.
    private func earlierTurns(_ t: ChatThread, for p: Provider) -> String {
        let prior = t.messages.filter { $0.status != .streaming && !$0.text.isEmpty }
        guard !prior.isEmpty else { return "" }
        var s = "<earlier_conversation_on_this_slide>\n"
        for m in prior.suffix(8) {
            let who = m.role == .user ? "Student" : (m.provider?.displayName ?? "Assistant")
            let body = m.text.count > 2500 ? String(m.text.prefix(2500)) + " …" : m.text
            s += "[\(who)]: \(body)\n\n"
        }
        return s + "</earlier_conversation_on_this_slide>\n\n"
    }

    private func readableDirs(for deck: Deck) -> [URL] {
        var dirs = Set<String>()
        dirs.insert(deck.url.deletingLastPathComponent().path)
        for f in deck.contextFiles { dirs.insert(URL(fileURLWithPath: f).deletingLastPathComponent().path) }
        for w in deck.walkthroughs { dirs.insert(URL(fileURLWithPath: w.path).deletingLastPathComponent().path) }
        return dirs.sorted().map { URL(fileURLWithPath: $0) }
    }

    private func apply(_ ev: BackendEvent, id: String, provider: Provider, deck: String, page: Int, usedResume: String?) {
        var updated: ChatMessage?
        var finished = false
        store.update(deck, page) { t in
            guard let i = t.messages.firstIndex(where: { $0.id == id }) else { return }
            var m = t.messages[i]
            switch ev {
            case .session(let s):
                t.setSession(s, for: provider)
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
            case .failed(let e):
                m.status = .error
                m.error = e
                m.activity = nil
                finished = true
                // A broken resume would fail every follow-up; start fresh (with the slide) next time.
                if usedResume != nil { t.setSession(nil, for: provider) }
            }
            t.messages[i] = m
            updated = m
        }
        if finished {
            running.removeValue(forKey: id)
            runWhere.removeValue(forKey: id)
            store.save(deck)
        }
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

    func stopAll() {
        for (_, h) in running { h.cancel() }
        running.removeAll()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Keep the chat page in place; open real links in the browser.
        if action.navigationType == .linkActivated, let u = action.request.url {
            if ["http", "https"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { target?.handle(body) }
    }
}
