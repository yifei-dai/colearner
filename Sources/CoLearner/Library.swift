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
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

struct Course: Identifiable, Hashable {
    var id: String
    var name: String
    var short: String
    var decks: [Deck]
}

/// library.json: which folders hold slides and which study pages belong to which deck.
private struct LibraryFile: Codable {
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

enum Library {
    /// The courses, and whether macOS refused access to any slide folder.
    static func load() -> ([Course], Bool) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: AppPaths.libraryJSON),
              let file = try? JSONDecoder().decode(LibraryFile.self, from: data) else {
            NSLog("Co-learner: could not read library.json at \(AppPaths.libraryJSON.path)")
            return ([], false)
        }
        var denied = false
        let links = loadUserLinks()
        let overrides = file.decks ?? [:]
        var courses: [Course] = []
        var seen = Set<String>()

        for c in file.courses {
            var found: [(Deck, Double)] = []
            for dir in c.slideDirs {
                let base = URL(fileURLWithPath: c.root).appendingPathComponent(dir)
                let items: [URL]
                do {
                    items = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                } catch {
                    if (error as NSError).code == CocoaError.fileReadNoPermission.rawValue
                        || ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM) {
                        denied = true
                    }
                    continue
                }
                for u in items where u.pathExtension.lowercased() == "pdf" {
                    let path = u.standardizedFileURL.path
                    if (c.exclude ?? []).contains(where: { path.contains($0) }) { continue }
                    let o = overrides[path]
                    if o?.hidden == true { continue }
                    seen.insert(path)
                    found.append((makeDeck(path: path, course: c, entry: o, links: links), o?.order ?? .infinity))
                }
            }
            // Decks listed explicitly for this course that live outside its slide folders.
            for (path, o) in overrides where o.course == c.id && !seen.contains(path) && o.hidden != true {
                guard fm.fileExists(atPath: path) else { continue }
                seen.insert(path)
                found.append((makeDeck(path: path, course: c, entry: o, links: links), o.order ?? .infinity))
            }
            found.sort { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
            }
            // Study pages made after library.json was written: found by looking, added after the listed ones.
            if let dirs = c.studyDirs, !dirs.isEmpty {
                let extra = StudyDiscovery.scan(root: c.root, dirs: dirs, numbering: c.studyNumbering, decks: found.map(\.0))
                for i in found.indices {
                    var d = found[i].0
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
                    found[i].0 = d
                }
            }
            courses.append(Course(id: c.id, name: c.name, short: c.short, decks: found.map { $0.0 }))
        }

        // PDFs opened by hand with "Open PDF…".
        let extra = links.extraDecks.filter { !seen.contains($0) && fm.fileExists(atPath: $0) }
        if !extra.isEmpty {
            let other = LibraryFile.CourseEntry(id: "other", name: "Other PDFs", short: "Other", root: "/", slideDirs: [],
                                                exclude: nil, layout: nil, studyDirs: nil, studyNumbering: nil)
            let decks = extra.map { makeDeck(path: $0, course: other, entry: overrides[$0], links: links) }
            courses.append(Course(id: "other", name: "Other PDFs", short: "Other", decks: decks))
        }
        return (courses, denied)
    }

    private static func makeDeck(path: String, course: LibraryFile.CourseEntry, entry: LibraryFile.DeckEntry?, links: UserLinks) -> Deck {
        var pages = entry?.walkthroughs ?? []
        for p in links.walkthroughs[path] ?? [] where !pages.contains(where: { $0.path == p.path }) {
            pages.append(p)
        }
        pages = pages.filter { FileManager.default.fileExists(atPath: $0.path) && !links.isUnlinked($0.path, from: path) }
        let title = entry?.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // Unlinking a notes PDF also stops Claude from reading the .tex of the same name.
        let unlinkedTex = Set((links.unlinked?[path] ?? []).filter(\.isPDF).map {
            URL(fileURLWithPath: $0.path).deletingPathExtension().appendingPathExtension("tex").path })
        let context = (entry?.context ?? []).filter { FileManager.default.fileExists(atPath: $0) && !unlinkedTex.contains($0) }
        return Deck(path: path, title: title, courseID: course.id, courseName: course.name,
                    walkthroughs: pages, contextFiles: context,
                    layout: entry?.layout ?? course.layout ?? .single, studyNumbering: course.studyNumbering)
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
