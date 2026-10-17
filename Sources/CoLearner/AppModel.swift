import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum RightTab: String { case chat, walkthrough }

@MainActor
final class AppModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published var openDecks: [Deck] = []
    @Published private(set) var deck: Deck?
    @Published private(set) var document: PDFDocument?
    @Published var page: Int = 1 {
        didSet {
            let clamped = min(max(page, 1), max(pageCount, 1))
            if clamped != page { page = clamped; return }
            if page != oldValue { pageDidChange() }
        }
    }
    @Published var rightTab: RightTab = .chat
    @Published var chatPages: Set<Int> = []
    @Published var provider: String = UserDefaults.standard.string(forKey: "provider") ?? "claude" {
        didSet { UserDefaults.standard.set(provider, forKey: "provider") }
    }
    @Published var claudeModel: String = UserDefaults.standard.string(forKey: "claudeModel") ?? "" {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }
    @Published var codexEffort: String = UserDefaults.standard.string(forKey: "codexEffort") ?? "medium" {
        didSet { UserDefaults.standard.set(codexEffort, forKey: "codexEffort") }
    }
    @Published var selectedStudyPage: [String: String] = [:]   // deck path -> study page path
    @Published var followSlides = true

    lazy var chat = ChatController(model: self)
    lazy var walk = WalkthroughController()
    lazy var studyPDF = StudyPDFController()
    private let thumbs = NSCache<NSString, NSImage>()

    var deckID: String { deck?.path ?? "" }
    var pageCount: Int { document?.pageCount ?? 0 }

    init() {
        reloadLibrary()
        restoreSession()
    }

    // MARK: library

    func reloadLibrary() {
        courses = Library.load()
        // Refresh open tabs with the new library data (links may have changed).
        let all = Dictionary(courses.flatMap(\.decks).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        openDecks = openDecks.map { all[$0.path] ?? $0 }
        if let d = deck, let fresh = all[d.path] { deck = fresh }
    }

    func deck(path: String) -> Deck? {
        courses.flatMap(\.decks).first { $0.path == path }
    }

    // MARK: opening decks

    func open(_ d: Deck) {
        if deck?.path == d.path { return }
        if let cur = deck { UserDefaults.standard.set(page, forKey: "lastPage.\(cur.path)") }
        guard let doc = Self.makeDocument(for: d) else {
            let a = NSAlert()
            a.messageText = "Could not open \(d.title)"
            a.informativeText = d.path
            a.runModal()
            return
        }
        if !openDecks.contains(where: { $0.path == d.path }) { openDecks.append(d) }
        thumbs.removeAllObjects()
        deck = d
        document = doc
        let last = UserDefaults.standard.integer(forKey: "lastPage.\(d.path)")
        page = min(max(last, 1), max(doc.pageCount, 1))
        saveSession()
        chatPages = Set(chat.store.pagesWithChats(d.path))
        chat.showCurrent()
    }

    func close(_ d: Deck) {
        guard let i = openDecks.firstIndex(where: { $0.path == d.path }) else { return }
        UserDefaults.standard.set(d.path == deck?.path ? page : UserDefaults.standard.integer(forKey: "lastPage.\(d.path)"),
                                  forKey: "lastPage.\(d.path)")
        openDecks.remove(at: i)
        if deck?.path == d.path {
            if openDecks.isEmpty {
                deck = nil
                document = nil
                chatPages = []
                chat.showCurrent()
            } else {
                let next = openDecks[min(i, openDecks.count - 1)]
                deck = nil
                open(next)
            }
        }
        saveSession()
    }

    /// One PDF page per slide. 2-up handouts are split into two cropped pages.
    static func makeDocument(for d: Deck) -> PDFDocument? {
        guard let src = PDFDocument(url: d.url) else { return nil }
        guard d.layout.isTwoUp, let frames = d.layout.frames else { return src }
        let out = PDFDocument()
        var n = 0
        for i in 0..<src.pageCount {
            guard let pg = src.page(at: i) else { continue }
            for f in frames where f.count == 4 {
                let rect = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
                // Skip an empty bottom frame on the last page of an odd-count deck.
                if i == src.pageCount - 1, f != frames[0], (pg.selection(for: rect)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !Self.frameHasInk(pg, rect) {
                    continue
                }
                guard let copy = pg.copy() as? PDFPage else { continue }
                copy.setBounds(rect, for: .mediaBox)
                copy.setBounds(rect, for: .cropBox)
                out.insert(copy, at: n)
                n += 1
            }
        }
        return n > 0 ? out : src
    }

    /// True if anything but white is drawn inside `rect` (used for slides that are pure images).
    private static func frameHasInk(_ page: PDFPage, _ rect: CGRect) -> Bool {
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

    func linkStudyPagePanel() {
        guard let d = deck else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.html, .pdf]
        p.message = "Choose a walkthrough or review page (.html) or a notes PDF for \(d.title)"
        guard p.runModal() == .OK, let url = p.url else { return }
        var links = Library.loadUserLinks()
        var list = links.walkthroughs[d.path] ?? []
        let page = StudyPage(title: url.deletingPathExtension().lastPathComponent, path: url.standardizedFileURL.path)
        if !list.contains(where: { $0.path == page.path }) { list.append(page) }
        links.walkthroughs[d.path] = list
        Library.saveUserLinks(links)
        reloadLibrary()
        selectedStudyPage[d.path] = page.path
    }

    // MARK: pages

    private func pageDidChange() {
        if let d = deck { UserDefaults.standard.set(page, forKey: "lastPage.\(d.path)") }
        chat.showCurrent()
    }

    func go(_ delta: Int) { page += delta }

    func thumbnail(_ p: Int) -> NSImage? {
        let key = "\(deckID)#\(p)" as NSString
        if let img = thumbs.object(forKey: key) { return img }
        guard let pg = document?.page(at: p - 1) else { return nil }
        let img = pg.thumbnail(of: NSSize(width: 208, height: 132), for: .cropBox)
        thumbs.setObject(img, forKey: key)
        return img
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
        UserDefaults.standard.set(deck?.path, forKey: "currentDeck")
    }

    private func restoreSession() {
        let paths = UserDefaults.standard.stringArray(forKey: "openDecks") ?? []
        let cur = UserDefaults.standard.string(forKey: "currentDeck")
        openDecks = paths.compactMap { deck(path: $0) }
        if let cur, let d = deck(path: cur) {
            open(d)
        } else if let first = openDecks.first {
            open(first)
        }
    }
}
