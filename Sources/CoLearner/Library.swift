import Foundation

/// A study page (walkthrough, review, recap, mind map) shown in the Walkthrough tab.
struct StudyPage: Codable, Hashable, Identifiable {
    var title: String
    var path: String
    /// How the page's slide numbers relate to app slides, passed to the indexer: nil = the indexer's default for the course the page names
    /// ("plus1": footer N -> PDF N+1; "half": two slides per PDF page; otherwise "identity": slide N = PDF N), and
    /// "identity" for 2-up handouts (the app splits them).
    var numbering: String?
    /// For pages written against an older version of the deck: page's PDF page ("ref") -> app slide.
    var map: [String: Int]?
    var id: String { path }
    var isPDF: Bool { path.lowercased().hasSuffix(".pdf") }
}

/// How slides sit on the PDF pages. Some handouts put two slides on each page.
struct SlideLayout: Codable, Hashable {
    var kind: String            // "single" or "twoUp"
    /// Slide frames in PDF points (origin bottom-left), in reading order on the page.
    var frames: [[Double]]?

    static let single = SlideLayout(kind: "single", frames: nil)
    var isTwoUp: Bool { kind == "twoUp" && (frames?.count ?? 0) >= 2 }
}

struct Deck: Hashable, Identifiable {
    var path: String
    var title: String
    var courseID: String
    var courseName: String
    var walkthroughs: [StudyPage]
    /// Text files the assistant may read for extra context (e.g. typed scribe notes).
    var contextFiles: [String]
    var layout: SlideLayout = .single
    /// How study pages of this course number slides ("identity" for 2-up handouts); used for pages linked by hand.
    var studyNumbering: String? = nil
    /// The deck's title in library.json ("L7 Topic"), when it has one: study pages are matched against it
    /// too, since the deck shows its real file name ("Lecture 7").
    var knownTitle: String? = nil
    /// Where the PDF was when Co-learner first listed it, if it was renamed or moved since. Scribe notes and
    /// walkthrough pages name decks by that file name.
    var knownPath: String? = nil
    var id: String { path }
    /// The file name study pages know this deck by (its first one).
    var knownFile: String { URL(fileURLWithPath: knownPath ?? path).lastPathComponent }

    /// The deck file name the scribe notes at `notes` were made from: the first name, or the current one for notes
    /// built after a rename.
    func scribeFile(_ notes: String) -> String {
        guard knownPath != nil, ScribeMap.pages(notes: notes, deckFile: knownFile).isEmpty else { return knownFile }
        return url.lastPathComponent
    }
    var url: URL { URL(fileURLWithPath: path) }
}

/// library.json: each course's folder (how its slides sit, where its study pages are) and notes on single decks
/// (title, study pages, readable notes). Which PDFs are listed is up to the sections (sections.json).
struct LibraryFile: Codable {
    struct CourseEntry: Codable {
        var id: String
        var name: String
        var short: String
        var root: String
        var slideDirs: [String]
        var exclude: [String]?
        var layout: SlideLayout?
        /// Folders searched for walkthrough pages and notes PDFs (StudyDiscovery).
        var studyDirs: [String]?
        /// How discovered pages number their slides ("identity" for 2-up handouts, which the app splits).
        var studyNumbering: String?
    }
    struct DeckEntry: Codable {
        var title: String?
        var course: String?
        var walkthroughs: [StudyPage]?
        var context: [String]?
        var hidden: Bool?
        var order: Double?
        var layout: SlideLayout?
    }
    var courses: [CourseEntry]
    var decks: [String: DeckEntry]?
}

/// Links the user adds from inside the app (stored in Application Support, merged over library.json).
struct UserLinks: Codable {
    var walkthroughs: [String: [StudyPage]] = [:]
    var extraDecks: [String] = []
    /// deck path -> pages the user unlinked (listed, discovered or linked before). Optional so older files still load.
    var unlinked: [String: [StudyPage]]?

    func isUnlinked(_ page: String, from deck: String) -> Bool {
        unlinked?[deck]?.contains { $0.path == page } ?? false
    }

    /// The same links after decks were renamed or moved (`follow` gives a deck's new path).
    func following(_ follow: (String) -> String) -> UserLinks {
        func merge(_ a: [StudyPage], _ b: [StudyPage]) -> [StudyPage] { a + b.filter { p in !a.contains { $0.path == p.path } } }
        var out = self
        out.walkthroughs = Dictionary(walkthroughs.map { (follow($0.key), $0.value) }, uniquingKeysWith: merge)
        out.unlinked = unlinked.map { u in Dictionary(u.map { (follow($0.key), $0.value) }, uniquingKeysWith: merge) }
        var seen = Set<String>()
        out.extraDecks = extraDecks.map(follow).filter { seen.insert($0).inserted }
        return out
    }
}

enum AppPaths {
    static var support: URL {
        let u = ProcessInfo.processInfo.environment["COLEARNER_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Co-learner", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var chats: URL {
        let u = support.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var cache: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Co-learner", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var userLinks: URL { support.appendingPathComponent("links.json") }
    static var sections: URL { support.appendingPathComponent("sections.json") }
    static var trackedFiles: URL { support.appendingPathComponent("files.json") }

    /// Bundled resources: Contents/Resources in the .app, or the source tree during `swift run`.
    static var resources: URL {
        if let r = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: r.appendingPathComponent("Web/chat.html").path) {
            return r
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }
    static var web: URL { resources.appendingPathComponent("Web", isDirectory: true) }
    static var libraryJSON: URL {
        // A library.json next to the app's support folder wins, so it can be edited without rebuilding.
        let override = support.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: override.path) { return override }
        return resources.appendingPathComponent("library.json")
    }
}

/// Everything the lecture page, the Lectures menu and the tabs show.
struct LibraryContents: Equatable {
    var sections: [SectionContents] = []
    /// Every PDF the sections list, as a deck, by path.
    var decks: [String: Deck] = [:]
    /// macOS refused to read a linked folder (the one-time Desktop prompt was declined).
    var denied = false
}

enum Library {
    static func readFile() -> LibraryFile? {
        guard let data = try? Data(contentsOf: AppPaths.libraryJSON),
              let file = try? JSONDecoder().decode(LibraryFile.self, from: data) else {
            NSLog("Co-learner: could not read library.json at \(AppPaths.libraryJSON.path)")
            return nil
        }
        return file
    }

    /// The course whose folder holds `path` (the innermost one).
    static func course(for path: String, in file: LibraryFile?) -> LibraryFile.CourseEntry? {
        file?.courses.filter { path.hasPrefix(URL(fileURLWithPath: $0.root).standardizedFileURL.path + "/") }
            .max { $0.root.count < $1.root.count }
    }

    /// The sections at first launch, as the lecture list was before them: one per library.json course linked to its
    /// slide folders (decks library.json hides stay hidden, decks it lists elsewhere are linked one by one), then
    /// "Other PDFs" with the PDFs opened by hand.
    static func initialSections(_ file: LibraryFile?, extraDecks: [String] = loadUserLinks().extraDecks) -> SectionsFile {
        var out = SectionsFile()
        let fm = FileManager.default
        let overrides = file?.decks ?? [:]
        for c in file?.courses ?? [] {
            let folders = c.slideDirs.map { URL(fileURLWithPath: c.root).appendingPathComponent($0).standardizedFileURL.path }
            var s = LibrarySection(id: c.id, name: c.name, items: folders.map { LinkedItem(kind: .folder, path: $0) })
            let inFolders = { (p: String) in folders.contains { p.hasPrefix($0 + "/") } }
            for (path, o) in overrides.sorted(by: { $0.key < $1.key }) {
                if o.hidden == true, inFolders(path) { s.hidden = (s.hidden ?? []) + [path] }
                if o.course == c.id, o.hidden != true, !inFolders(path), fm.fileExists(atPath: path) {
                    s.items.append(LinkedItem(kind: .file, path: path))
                }
            }
            out.sections.append(s)
        }
        let listed = Set(out.sections.flatMap { $0.items.map(\.path) })
        let extra = extraDecks.filter { !listed.contains($0) && fm.fileExists(atPath: $0) }
        if !extra.isEmpty {
            out.sections.append(LibrarySection(id: "other", name: "Other PDFs", items: extra.map { LinkedItem(kind: .file, path: $0) }))
        }
        return out
    }

    /// The decks for every PDF the sections list, with what library.json and the user's links say about each.
    /// `aliases` maps a renamed or moved PDF to the path library.json knows it by.
    static func decks(for sections: [SectionContents], file: LibraryFile?, aliases: [String: String],
                      links: UserLinks = loadUserLinks()) -> [String: Deck] {
        // Outside every course folder a deck goes by a section's name: the same one whatever the sections' order.
        var section: [String: (id: String, name: String)] = [:]
        var shown = Set<String>()   // listed, not only hidden
        for s in sections {
            for path in s.files where section[path].map({ s.id < $0.id }) ?? true { section[path] = (s.id, s.section.name) }
            shown.formUnion(s.links.compactMap(\.node).flatMap(\.files))
        }
        var decks: [String: Deck] = [:]
        for (path, s) in section {
            decks[path] = makeDeck(path: path, file: file, aliases: aliases, section: s.name, links: links)
        }
        // Study pages made after library.json was written: found by looking in each course's study folders, among
        // the listed (not hidden) decks in its slide folders.
        let overrides = file?.decks ?? [:]
        for c in file?.courses ?? [] {
            guard let dirs = c.studyDirs, !dirs.isEmpty else { continue }
            let found = decks.values.filter { d in
                shown.contains(d.path) && (inSlideFolders(d.path, of: c, aliases: aliases) || overrides[aliases[d.path] ?? d.path]?.course == c.id)
            }.sorted { $0.path < $1.path }
            guard !found.isEmpty else { continue }
            let extra = StudyDiscovery.scan(root: c.root, dirs: dirs, numbering: c.studyNumbering, decks: found)
            for var d in found {
                for p in extra.pages[d.path] ?? [] where !d.walkthroughs.contains(where: { $0.path == p.path })
                    && !links.isUnlinked(p.path, from: d.path) {
                    d.walkthroughs.append(p)
                }
                // A notes .tex goes with its PDF: unlinking the PDF also stops Claude reading the .tex.
                let unlinkedTex = Set((links.unlinked?[d.path] ?? []).filter(\.isPDF).map {
                    URL(fileURLWithPath: $0.path).deletingPathExtension().appendingPathExtension("tex").path })
                for f in extra.context[d.path] ?? [] where !d.contextFiles.contains(f) && !unlinkedTex.contains(f) {
                    d.contextFiles.append(f)
                }
                // Walkthrough pages before notes PDFs, keeping each group's order.
                d.walkthroughs = d.walkthroughs.filter { !$0.isPDF } + d.walkthroughs.filter(\.isPDF)
                decks[d.path] = d
            }
        }
        return decks
    }

    /// True if the PDF is in one of the course's slide folders (at any depth), where it is or where library.json knew it.
    static func inSlideFolders(_ path: String, of c: LibraryFile.CourseEntry, aliases: [String: String]) -> Bool {
        let folders = c.slideDirs.map { URL(fileURLWithPath: c.root).appendingPathComponent($0).standardizedFileURL.path }
        return [path, aliases[path] ?? path].contains { p in folders.contains { p.hasPrefix($0 + "/") } }
    }

    /// A deck for a PDF no section lists (a tab or a chat whose PDF was unlinked), made the same way.
    static func looseDeck(path: String, file: LibraryFile?, aliases: [String: String]) -> Deck? {
        var dir: ObjCBool = false
        guard path.lowercased().hasSuffix(".pdf"), FileManager.default.fileExists(atPath: path, isDirectory: &dir),
              !dir.boolValue else { return nil }
        return makeDeck(path: path, file: file, aliases: aliases, section: "Other PDFs", links: loadUserLinks())
    }

    /// A deck shows its real file name. Course settings come from the course folder it is in (2-up slides only in
    /// the course's slide folders); outside every course folder it goes by `section`.
    static func makeDeck(path: String, file: LibraryFile?, aliases: [String: String], section: String, links: UserLinks) -> Deck {
        let known = aliases[path] ?? path
        let entry = file?.decks?[known]
        let course = course(for: path, in: file) ?? course(for: known, in: file)
        let inSlides = course.map { inSlideFolders(path, of: $0, aliases: aliases) } ?? false
        var pages = entry?.walkthroughs ?? []
        for p in links.walkthroughs[path] ?? [] where !pages.contains(where: { $0.path == p.path }) {
            pages.append(p)
        }
        pages = pages.filter { FileManager.default.fileExists(atPath: $0.path) && !links.isUnlinked($0.path, from: path) }
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // Unlinking a notes PDF also stops Claude from reading the .tex of the same name.
        let unlinkedTex = Set((links.unlinked?[path] ?? []).filter(\.isPDF).map {
            URL(fileURLWithPath: $0.path).deletingPathExtension().appendingPathExtension("tex").path })
        let context = (entry?.context ?? []).filter { FileManager.default.fileExists(atPath: $0) && !unlinkedTex.contains($0) }
        return Deck(path: path, title: title, courseID: course?.id ?? "other", courseName: course?.name ?? section,
                    walkthroughs: pages, contextFiles: context,
                    layout: entry?.layout ?? (inSlides ? course?.layout : nil) ?? .single, studyNumbering: course?.studyNumbering,
                    knownTitle: entry?.title, knownPath: known == path ? nil : known)
    }

    /// Where Rename File… puts a PDF named `name` (typed without ".pdf", or with it), or why it can't.
    static func renameTarget(_ path: String, to name: String) -> (path: String?, problem: String?) {
        let old = URL(fileURLWithPath: path)
        let ext = old.pathExtension.isEmpty ? "pdf" : old.pathExtension
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.lowercased().hasSuffix("." + ext.lowercased()) { n = String(n.dropLast(ext.count + 1)).trimmingCharacters(in: .whitespaces) }
        guard !n.isEmpty, !n.hasPrefix("."), !n.contains("/"), !n.contains(":") else {
            return (nil, "A file name can't be empty, start with a dot, or contain “/” or “:”.")
        }
        return (old.deletingLastPathComponent().appendingPathComponent(n + "." + ext).path, nil)
    }

    static func loadUserLinks() -> UserLinks {
        guard let d = try? Data(contentsOf: AppPaths.userLinks),
              let l = try? JSONDecoder().decode(UserLinks.self, from: d) else { return UserLinks() }
        return l
    }

    static func saveUserLinks(_ l: UserLinks) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(l) { try? d.write(to: AppPaths.userLinks, options: .atomic) }
    }
}
