import SwiftUI
import PDFKit
import WebKit
import UniformTypeIdentifiers

enum RightTab: String, CaseIterable { case chat, walkthrough }

@MainActor
final class AppModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published private(set) var libraryRevision = 0
    @Published var openDecks: [Deck] = []
    /// A browser-style "New Tab" (shows the lecture list; picking a lecture opens it there).
    @Published var newTab = false
    /// The Co-learner window (set by MainView), whatever the right panel shows.
    weak var mainWindow: NSWindow? {
        didSet {
            guard let w = mainWindow, w !== oldValue else { return }
            // Closing the main window quits the app: close the pop-outs with it, keeping them for next launch.
            mainWindowObserver.map(NotificationCenter.default.removeObserver)
            mainWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.popOuts.closeAllForQuit()
                    self?.mainWindowClosed = true
                }
            }
            if !popOutsRestored {
                popOutsRestored = true
                let saved = (UserDefaults.standard.stringArray(forKey: "poppedOut") ?? []).compactMap(RightTab.init(rawValue:))
                DispatchQueue.main.async { for t in RightTab.allCases where saved.contains(t) { self.popOut(t) } }
            }
        }
    }
    private var mainWindowObserver: NSObjectProtocol?
    private var popOutsRestored = false
    /// The main window was closed while the app stayed open (Settings or a visual window); SwiftUI shows the
    /// same window again on reopen, so this is noticed in MainView.onAppear (mainWindowAppeared).
    private var mainWindowClosed = false

    /// MainView appeared: after a close and reopen of the main window, bring its pop-outs back.
    func mainWindowAppeared() {
        guard mainWindowClosed else { return }
        mainWindowClosed = false
        DispatchQueue.main.async {
            for t in RightTab.allCases where self.poppedOut.contains(t) && self.popOuts.window(for: t) == nil {
                self.popOuts.show(t)
            }
            self.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// Chat / Walkthrough shown in windows of their own (see PopOutWindows).
    @Published private(set) var poppedOut: Set<RightTab> = []
    lazy var popOuts = PopOutWindows(model: self)

    /// The panel the right side shows: the chosen tab, or the other one if the chosen one is popped out.
    var shownRightTab: RightTab {
        guard poppedOut.contains(rightTab) else { return rightTab }
        return RightTab.allCases.first { !poppedOut.contains($0) } ?? rightTab
    }

    func popOut(_ tab: RightTab) {
        if poppedOut.contains(tab) { popOuts.show(tab); return }
        poppedOut.insert(tab)
        if rightTab == tab, let other = RightTab.allCases.first(where: { !poppedOut.contains($0) }) { rightTab = other }
        UserDefaults.standard.set(poppedOut.map(\.rawValue), forKey: "poppedOut")
        // Next turn: the right panel has let go of the view by then.
        DispatchQueue.main.async { self.popOuts.show(tab) }
    }

    /// Put a popped-out panel back next to the slides (its window closes; with no window, e.g. while the main
    /// window is closed, just mark it docked).
    func dock(_ tab: RightTab) {
        if popOuts.window(for: tab) == nil { didClosePopOut(tab) } else { popOuts.close(tab) }
    }

    func togglePopOut(_ tab: RightTab) { poppedOut.contains(tab) ? dock(tab) : popOut(tab) }

    /// Its window was closed (Put back, the close button, or ⌘W).
    func didClosePopOut(_ tab: RightTab) {
        poppedOut.remove(tab)
        rightTab = tab
        UserDefaults.standard.set(poppedOut.map(\.rawValue), forKey: "poppedOut")
    }

    /// Bring a panel into view: its pop-out window, or its tab next to the slides.
    func showPanel(_ tab: RightTab) {
        if poppedOut.contains(tab) { popOuts.show(tab) } else { rightTab = tab }
    }
    @Published private(set) var deck: Deck?
    @Published private(set) var document: PDFDocument?
    private var documentRevision: FileRevision?
    private var documentThumbnailKey = ""
    @Published var page: Int = 1 {
        didSet {
            let clamped = min(max(page, 1), max(pageCount, 1))
            if clamped != page { page = clamped; return }   // re-enters didSet once with the clamped value
            if page != lastNotifiedPage { lastNotifiedPage = page; pageDidChange() }
        }
    }
    private var lastNotifiedPage = 0
    /// Each slide's own text (2-up handouts are read per frame from the original page).
    private(set) var slideTexts: [String] = []
    /// Set when macOS refused access to a course folder (the one-time Desktop prompt was declined).
    @Published var folderAccessDenied = false
    @Published var rightTab: RightTab = .chat
    @Published var chatPages: Set<Int> = []
    @Published var provider: String = UserDefaults.standard.string(forKey: "provider") ?? "claude" {
        didSet { UserDefaults.standard.set(provider, forKey: "provider") }
    }
    // Model and effort per assistant (chosen in the chat's pickers or in Settings).
    @Published var claudeModel: String = UserDefaults.standard.string(forKey: "claudeModel") ?? "opus" {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel"); chat.pushConfig() }
    }
    @Published var claudeEffort: String = UserDefaults.standard.string(forKey: "claudeEffort") ?? "medium" {
        didSet { UserDefaults.standard.set(claudeEffort, forKey: "claudeEffort"); chat.pushConfig() }
    }
    @Published var codexModel: String = UserDefaults.standard.string(forKey: "codexModel") ?? CodexBackend.defaultModel {
        didSet {
            UserDefaults.standard.set(codexModel, forKey: "codexModel")
            // Not every model has every effort level (the luna models stop at max).
            if let m = ModelCatalog.model(.codex, codexModel), !m.efforts.contains(codexEffort) { codexEffort = m.defaultEffort }
            chat.pushConfig()
        }
    }
    @Published var codexEffort: String = UserDefaults.standard.string(forKey: "codexEffort") ?? "medium" {
        didSet { UserDefaults.standard.set(codexEffort, forKey: "codexEffort"); chat.pushConfig() }
    }
    @Published var codexFastMode: Bool = UserDefaults.standard.bool(forKey: "codexFastMode") {
        didSet { UserDefaults.standard.set(codexFastMode, forKey: "codexFastMode"); chat.pushConfig() }
    }
    @Published var selectedStudyPage: [String: String] = [:]   // deck path -> study page path
    @Published var followSlides = true
    /// "system" (follow macOS), "light" or "dark". The chat and study pages follow it too.
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appearance")
            applyAppearance()
        }
    }
    /// True while the user is dragging out an area of the slide to ask about.
    @Published var selectingArea = false

    lazy var chat = ChatController(model: self)
    lazy var walk: WalkthroughController = {
        let w = WalkthroughController()
        w.onTurn = { [weak self] d in self?.go(d) }
        return w
    }()
    lazy var studyPDF = StudyPDFController()
    let thumbs = ThumbStore()

    var deckID: String { deck?.path ?? "" }
    var pageCount: Int { document?.pageCount ?? 0 }

    init() {
        applyAppearance()
        // v0.1 stored "" for "default Claude model".
        ensureModelChoices()
        reloadLibrary()
        restoreSession()
        installArrowKeys()
    }

    /// The chosen models must exist and be shown in the menu; otherwise take the first one shown.
    /// Runs at launch and whenever the model lists refresh (a model can disappear or be hidden).
    func ensureModelChoices() {
        let cat = ModelCatalog.shared
        // If the lists changed so that every model is hidden, show the first one again.
        for p in Provider.allCases where cat.visible(p).isEmpty {
            if let f = ModelCatalog.list(p).first { cat.setHidden(p, f.id, false) }
        }
        if ModelCatalog.model(.claude, claudeModel) == nil || cat.isHidden(.claude, claudeModel),
           let first = cat.visible(.claude).first { claudeModel = first.id }
        if ModelCatalog.model(.codex, codexModel) == nil || cat.isHidden(.codex, codexModel),
           let first = cat.visible(.codex).first { codexModel = first.id }
        if let m = ModelCatalog.model(.claude, claudeModel), !m.efforts.contains(claudeEffort) { claudeEffort = m.defaultEffort }
        if let m = ModelCatalog.model(.codex, codexModel), !m.efforts.contains(codexEffort) { codexEffort = m.defaultEffort }
    }

    /// ← and → turn slides anywhere in the window, except while typing in a text box or using a visual.
    private func installArrowKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if let self, e.keyCode == 53, self.selectingArea, NSApp.modalWindow == nil,
               let w = e.window, w === (self.mainWindow ?? w) || self.popOuts.contains(w), !(w is NSPanel) {
                self.selectingArea = false   // Esc ends area selection (other windows keep their Esc)
                return nil
            }
            guard let self, e.keyCode == 123 || e.keyCode == 124,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  self.document != nil, let w = e.window, !(w is NSPanel) else { return e }
            // Only the main window (it holds the right panel), not Settings or a pop-out visual.
            if let main = self.mainWindow {
                guard w === main || self.popOuts.contains(w) else { return e }
            } else {
                let panels: [NSView] = [self.chat.webView, self.walk.webView, self.studyPDF.view]
                guard panels.contains(where: { $0.window === w }) else { return e }
            }
            let fr = w.firstResponder
            if fr is NSText { return e }                    // a native text field
            // Inside the chat or a walkthrough page, the page itself turns the slide unless a text box,
            // slider or visual has focus (see chat.js and WalkthroughController.arrowScript).
            if let v = fr as? NSView, v is WKWebView || v.enclosingWebView != nil { return e }
            self.go(e.keyCode == 123 ? -1 : 1)
            return nil
        }
    }

    // MARK: library

    func reloadLibrary() {
        let (loaded, denied) = Library.load()
        courses = loaded
        folderAccessDenied = denied
        // Refresh open tabs with the new library data (links may have changed).
        let all = Dictionary(courses.flatMap(\.decks).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        openDecks = openDecks.map { all[$0.path] ?? $0 }
        if let d = deck, var fresh = all[d.path] {
            fresh.layout = d.layout   // keep the slide frames measured when the deck was opened
            deck = fresh
        }
        libraryRevision += 1
        if let d = deck {
            _ = refreshDocumentIfNeeded()
            chat.sourcesDidChange(for: deck ?? d)
        }
    }

    func deck(path: String) -> Deck? {
        courses.flatMap(\.decks).first { $0.path == path }
    }

    // MARK: opening decks

    // MARK: tabs

    /// ⌘T / +: a New Tab showing the lecture list. The deck on screen stays open in its own tab.
    func openNewTab() {
        newTab = true
        showNewTab()
    }

    /// Bring the New Tab to the front (the open decks keep their tabs).
    func showNewTab() {
        guard newTab else { return }
        if let cur = deck { UserDefaults.standard.set(page, forKey: "lastPage.\(cur.path)") }
        selectingArea = false
        deck = nil
        document = nil
        slideTexts = []
        chatPages = []
        chat.showCurrent()
        // Not saved: on the next launch the deck shown before the New Tab comes back.
    }

    func closeNewTab() {
        let wasShown = deck == nil
        newTab = false
        if wasShown { showRemainingTab(preferred: nil) }
    }

    /// ⌘W closes the tab on screen, as in a browser. Other windows (Settings, a pop-out visual) close as usual;
    /// with no tab left it does nothing (closing the window would quit the app).
    func closeCurrentTab() {
        guard let key = NSApp.keyWindow else { return }   // e.g. the window is minimized
        if let main = mainWindow, key !== main { key.performClose(nil); return }
        if let d = deck { close(d) }
        else if newTab { closeNewTab() }
        else if !openDecks.isEmpty { showRemainingTab(preferred: nil) }
        else { NSSound.beep() }
    }

    /// After the tab on screen went away: show the deck tab at `preferred`, else the others from the right.
    /// A tab whose PDF no longer opens is dropped. With none left, the lecture list shows (in the New Tab
    /// if there is one).
    private func showRemainingTab(preferred: Int?) {
        deck = nil
        var order = Array(openDecks.indices.reversed())
        if let p = preferred, openDecks.indices.contains(p) { order.removeAll { $0 == p }; order.insert(p, at: 0) }
        for d in order.map({ openDecks[$0] }) {
            switchTo(d)
            if deck != nil { break }
            openDecks.removeAll { $0.path == d.path }
        }
        if deck == nil {
            document = nil
            slideTexts = []
            chatPages = []
            chat.showCurrent()
        }
        saveSession()
    }

    /// Clicking a deck's tab: just show it (a New Tab stays where it is).
    func switchTo(_ d: Deck) {
        let keep = newTab
        open(d)
        newTab = keep
    }

    /// Open a lecture from the Lectures menu or the lecture list. From a New Tab, it takes that tab's place.
    @discardableResult
    func open(_ d: Deck) -> Bool {
        var d = d
        if deck?.path == d.path {
            guard refreshDocumentIfNeeded() else { return false }
            if let deck { chat.sourcesDidChange(for: deck) }
            return true
        }
        if let cur = deck { UserDefaults.standard.set(page, forKey: "lastPage.\(cur.path)") }
        let revision = FileRevision.read(d.path)
        guard let doc = Self.makeDocument(for: d) else {
            let a = NSAlert()
            a.messageText = "Could not open \(d.title)"
            a.informativeText = d.path
            a.runModal()
            return false
        }
        if let f = doc.frames { d.layout.frames = f }   // the frames actually used (also keys the slide-image cache)
        if deck == nil { newTab = false }   // picked in the New Tab (or nothing was open)
        selectingArea = false
        if !openDecks.contains(where: { $0.path == d.path }) { openDecks.append(d) }
        deck = d
        document = doc.document
        documentRevision = revision
        documentThumbnailKey = "\(d.path)|\(String(describing: revision))|\(d.layout.frames ?? [])"
        slideTexts = doc.texts
        let last = UserDefaults.standard.integer(forKey: "lastPage.\(d.path)")
        lastNotifiedPage = 0
        page = min(max(last, 1), max(doc.document.pageCount, 1))
        saveSession()
        chatPages = Set(chat.store.pagesWithChats(d.path))
        chat.sourcesDidChange(for: d)
        chat.showCurrent()
        return true
    }

    /// Reload a replaced PDF before sending context, so the text, images and displayed slides agree.
    @discardableResult
    func refreshDocumentIfNeeded() -> Bool {
        guard var d = deck else { return false }
        let revision = FileRevision.read(d.path)
        guard revision != documentRevision else { return document != nil }
        guard let made = Self.makeDocument(for: d) else {
            let alert = NSAlert()
            alert.messageText = "Could not reload \(d.title)"
            alert.informativeText = "The PDF changed or is unavailable. Restore the file before asking about it.\n\(d.path)"
            alert.runModal()
            return false
        }
        if let frames = made.frames { d.layout.frames = frames }
        document = made.document
        documentRevision = revision
        documentThumbnailKey = "\(d.path)|\(String(describing: revision))|\(d.layout.frames ?? [])"
        slideTexts = made.texts
        deck = d
        if let i = openDecks.firstIndex(where: { $0.path == d.path }) { openDecks[i] = d }
        selectingArea = false
        chat.clearArea()
        page = min(max(page, 1), max(made.document.pageCount, 1))
        chat.showCurrent()
        return true
    }

    func close(_ d: Deck) {
        guard let i = openDecks.firstIndex(where: { $0.path == d.path }) else { return }
        UserDefaults.standard.set(d.path == deck?.path ? page : UserDefaults.standard.integer(forKey: "lastPage.\(d.path)"),
                                  forKey: "lastPage.\(d.path)")
        openDecks.remove(at: i)
        if deck?.path == d.path {
            selectingArea = false
            showRemainingTab(preferred: openDecks.isEmpty ? nil : min(i, openDecks.count - 1))   // a New Tab stays
            return
        }
        saveSession()
    }

    /// One PDF page per slide, plus each slide's text. 2-up handouts are split into two cropped pages; their
    /// text is read per frame from the original page (cropped copies share one text layer).
    nonisolated static func makeDocument(for d: Deck) -> (document: PDFDocument, texts: [String], frames: [[Double]]?)? {
        guard let src = PDFDocument(url: d.url) else { return nil }
        guard d.layout.isTwoUp, let configured = d.layout.frames else {
            let texts = (0..<src.pageCount).map { src.page(at: $0)?.string ?? "" }
            return (src, texts, nil)
        }
        // Measure where the slides sit in this deck (new decks may shift a few points); library.json is the fallback.
        let frames = FrameDetector.frames(for: src) ?? configured
        let out = PDFDocument()
        var texts: [String] = []
        for i in 0..<src.pageCount {
            guard let pg = src.page(at: i) else { continue }
            for f in frames where f.count == 4 {
                let rect = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
                let text = pg.selection(for: rect)?.string ?? ""
                // Skip an empty bottom frame on the last page of an odd-count deck.
                if i == src.pageCount - 1, f != frames[0], text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !Self.frameHasInk(pg, rect) {
                    continue
                }
                guard let copy = pg.copy() as? PDFPage else { continue }
                copy.setBounds(rect, for: .mediaBox)
                copy.setBounds(rect, for: .cropBox)
                out.insert(copy, at: texts.count)
                texts.append(text)
            }
        }
        if texts.isEmpty { return (src, (0..<src.pageCount).map { src.page(at: $0)?.string ?? "" }, nil) }
        return (out, texts, frames)
    }

    /// True if anything but white is drawn inside `rect` (used for slides that are pure images).
    nonisolated private static func frameHasInk(_ page: PDFPage, _ rect: CGRect) -> Bool {
        let w = 60, h = 45
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / rect.width, y: CGFloat(h) / rect.height)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let data = ctx.data else { return true }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var dark = 0
        // Ignore the 2-px border where the frame outline itself is drawn.
        for y in 2..<(h - 2) { for x in 2..<(w - 2) {
            let o = (y * w + x) * 4
            if Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2]) < 700 { dark += 1 }
        } }
        return dark > 10
    }

    func openPDFPanel() {
        selectingArea = false
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = false
        p.message = "Choose a lecture PDF"
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = url.standardizedFileURL.path
        if deck(path: path) == nil {
            var links = Library.loadUserLinks()
            if !links.extraDecks.contains(path) { links.extraDecks.append(path) }
            Library.saveUserLinks(links)
            reloadLibrary()
        }
        if let d = deck(path: path) { open(d) }
    }

    /// Link a walkthrough / review page or a notes PDF to the open deck. It syncs to the slides like the
    /// built-in links: HTML pages through their slide references, notes PDFs through their slide stamps.
    func linkStudyPagePanel() {
        guard let d = deck else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.html, .pdf]
        p.message = "Choose a walkthrough or review page (.html) or a notes PDF for \(d.title)"
        if let dir = d.walkthroughs.first.map({ URL(fileURLWithPath: $0.path).deletingLastPathComponent() }) { p.directoryURL = dir }
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = url.standardizedFileURL.path
        var links = Library.loadUserLinks()
        links.unlinked?[d.path]?.removeAll { $0.path == path }
        // Already linked (by the library or by looking)? Just show it.
        if !d.walkthroughs.contains(where: { $0.path == path }) {
            var list = links.walkthroughs[d.path] ?? []
            let isPDF = url.pathExtension.lowercased() == "pdf"
            let page = StudyPage(title: url.deletingPathExtension().lastPathComponent, path: path,
                                 numbering: isPDF ? nil : d.studyNumbering)
            if !list.contains(where: { $0.path == path }) { list.append(page) }
            links.walkthroughs[d.path] = list
        }
        Library.saveUserLinks(links)
        reloadLibrary()
        selectedStudyPage[d.path] = path
        showPanel(.walkthrough)
    }

    /// Remove a page from the open deck's Walkthrough tab (whether it came from the library, from looking,
    /// or from an earlier link). It stays out until linked again.
    func unlinkStudyPage(_ page: StudyPage) {
        guard let d = deck else { return }
        var links = Library.loadUserLinks()
        links.walkthroughs[d.path]?.removeAll { $0.path == page.path }
        var un = links.unlinked ?? [:]
        if !(un[d.path] ?? []).contains(where: { $0.path == page.path }) { un[d.path, default: []].append(page) }
        links.unlinked = un
        Library.saveUserLinks(links)
        if selectedStudyPage[d.path] == page.path { selectedStudyPage[d.path] = nil }
        reloadLibrary()
    }

    /// Undo an unlink.
    func relinkStudyPage(_ page: StudyPage) {
        guard let d = deck else { return }
        var links = Library.loadUserLinks()
        links.unlinked?[d.path]?.removeAll { $0.path == page.path }
        Library.saveUserLinks(links)
        reloadLibrary()
        // A page that was linked by hand (not listed in the library or found by looking) is linked by hand again.
        if deck?.walkthroughs.contains(where: { $0.path == page.path }) == false {
            links.walkthroughs[d.path, default: []].append(page)
            Library.saveUserLinks(links)
            reloadLibrary()
        }
        selectedStudyPage[d.path] = page.path
    }

    /// Pages unlinked from the open deck that still exist (for "Link again").
    var unlinkedStudyPages: [StudyPage] {
        guard let d = deck else { return [] }
        return (Library.loadUserLinks().unlinked?[d.path] ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: pages

    private func pageDidChange() {
        if let d = deck { UserDefaults.standard.set(page, forKey: "lastPage.\(d.path)") }
        chat.showCurrent()
    }

    // MARK: appearance

    static let appearances: [(id: String, label: String, icon: String)] = [
        ("system", "Automatic", "circle.lefthalf.filled"), ("light", "Light", "sun.max"), ("dark", "Dark", "moon"),
    ]

    func applyAppearance() {
        // Web views (chat, walkthroughs, visuals) follow the app's appearance, so their CSS dark mode switches too.
        switch appearance {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    // MARK: selecting an area of the slide

    func beginAreaSelection() {
        guard document != nil else { return }
        if !poppedOut.contains(.chat) { rightTab = .chat }   // a popped-out chat stays where it is
        selectingArea = true
        // Started from a pop-out (or Settings): the slide's window must be key for the crosshair, the drag and Esc.
        if let w = mainWindow, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }

    func cancelAreaSelection() { selectingArea = false }

    /// The dragged box, in page coordinates: render it and hand it to the chat.
    func finishAreaSelection(page pdfPage: PDFPage, rect: CGRect) {
        selectingArea = false
        guard let doc = document else { return }
        let index = doc.index(for: pdfPage)
        guard index != NSNotFound, let cut = SlideImages.area(page: pdfPage, rect: rect) else { return }
        if index + 1 != page { page = index + 1 }
        if !poppedOut.contains(.chat) { rightTab = .chat }
        chat.setArea(page: index + 1, url: cut.url, thumb: cut.thumb)
    }

    func go(_ delta: Int) {
        let t = min(max(page + delta, 1), max(pageCount, 1))
        if t != page { page = t }
    }

    func thumbnail(_ p: Int) -> NSImage? {
        thumbs.image(key: "\(documentThumbnailKey)#\(p)", page: document?.page(at: p - 1))
    }

    func refreshChatPages() {
        guard let d = deck else { chatPages = []; return }
        chatPages = Set(chat.store.pagesWithChats(d.path))
    }

    var currentStudyPages: [StudyPage] { deck?.walkthroughs ?? [] }

    var currentStudyPage: StudyPage? {
        guard let d = deck else { return nil }
        let pages = d.walkthroughs
        if let sel = selectedStudyPage[d.path], let p = pages.first(where: { $0.path == sel }) { return p }
        // A walkthrough page wins; with only notes PDFs, take the one whose slides are closest to this slide
        // (one deck can be split across two notes files).
        if let html = pages.first(where: { !$0.isPDF }) { return html }
        let file = d.url.lastPathComponent
        func distance(_ p: StudyPage) -> Int {
            let keys = ScribeMap.pages(notes: p.path, deckFile: file).keys
            guard let lo = keys.min(), let hi = keys.max() else { return .max }
            return page < lo ? lo - page : (page > hi ? page - hi : 0)
        }
        return pages.min { distance($0) < distance($1) } ?? pages.first
    }

    // MARK: session

    private func saveSession() {
        UserDefaults.standard.set(openDecks.map(\.path), forKey: "openDecks")
        // While the New Tab is shown, the deck shown before it stays the one to bring back at launch.
        if let d = deck { UserDefaults.standard.set(d.path, forKey: "currentDeck") }
        else if openDecks.isEmpty { UserDefaults.standard.removeObject(forKey: "currentDeck") }
    }

    private func restoreSession() {
        let paths = UserDefaults.standard.stringArray(forKey: "openDecks") ?? []
        let cur = UserDefaults.standard.string(forKey: "currentDeck")
        openDecks = paths.compactMap { deck(path: $0) }
        // The deck that was on screen first, then the other tabs in order; a tab whose PDF no longer opens
        // is dropped (one alert each), so a broken file can't leave every tab unselected at each launch.
        var order = openDecks
        if let i = order.firstIndex(where: { $0.path == cur }) { order.insert(order.remove(at: i), at: 0) }
        var dropped = false
        for d in order {
            open(d)
            if deck != nil { break }   // open() saved the session
            openDecks.removeAll { $0.path == d.path }
            dropped = true
        }
        // Nothing resolved (e.g. Desktop access denied, so the library is empty): keep the saved tabs for next time.
        if dropped { saveSession() }
    }
}

private extension NSView {
    var enclosingWebView: WKWebView? {
        var v = superview
        while let s = v { if let w = s as? WKWebView { return w }; v = s.superview }
        return nil
    }
}
