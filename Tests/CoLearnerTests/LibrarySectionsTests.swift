import Foundation
import Testing
@testable import CoLearner

/// The lecture page's sections: linking, hiding, dragging between sections, what a linked folder shows (real names,
/// subfolders), the sections made from library.json at first launch, and the course settings each deck gets.
@Suite(.serialized)
@MainActor
struct LibrarySectionsTests {
    /// A course folder like the real ones: lectures/{before mid/{01a-intro, 01b-transformations}, 7a, 7b, notes.txt,
    /// .hidden.pdf, empty/, App.app/}, plus Assignments/hw1.pdf and recitations/rec6.pdf.
    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sections-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["Robotics/lectures/before mid", "Robotics/lectures/empty", "Robotics/lectures/App.app/Contents",
                  "Robotics/Assignments", "Robotics/recitations"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for f in ["Robotics/lectures/before mid/01a-intro.pdf", "Robotics/lectures/before mid/01b-transformations.pdf",
                  "Robotics/lectures/7a-bayes-estimation.pdf", "Robotics/lectures/7b-mc-localization.pdf",
                  "Robotics/lectures/10-planning.pdf", "Robotics/lectures/notes.txt", "Robotics/lectures/.hidden.pdf",
                  "Robotics/lectures/App.app/Contents/inside.pdf", "Robotics/Assignments/hw1.pdf",
                  "Robotics/recitations/rec6.pdf"] {
            try Data("%PDF-1.4\n".utf8).write(to: root.appendingPathComponent(f))
        }
        return root
    }

    private func item(_ path: String, _ kind: LinkedItem.Kind) -> LinkedItem { LinkedItem(kind: kind, path: path) }

    // MARK: the model

    @Test func linkingKeepsOrderSkipsDuplicatesAndBringsHiddenBack() {
        var f = SectionsFile()
        let a = f.addSection(named: "AI")
        f.link([item("/c/lectures", .folder), item("/c/rec.pdf", .file)], to: a)
        f.link([item("/c/lectures", .folder)], to: a)                          // already there: nothing new
        #expect(f.section(a)?.items.map(\.path) == ["/c/lectures", "/c/rec.pdf"])
        f.link([item("/x/new.pdf", .file)], to: a, at: 1)
        #expect(f.section(a)?.items.map(\.path) == ["/c/lectures", "/x/new.pdf", "/c/rec.pdf"])
        f.link([item("/c/rec.pdf", .file)], to: a, at: 0)                       // linked already: moves to the top
        #expect(f.section(a)?.items.map(\.path) == ["/c/rec.pdf", "/c/lectures", "/x/new.pdf"])
        f.hide("/c/lectures/old.pdf", in: a)
        #expect(f.isHidden("/c/lectures/old.pdf", in: f.section(a)!))
        f.link([item("/c/lectures/old.pdf", .file)], to: a)                     // inside a linked folder: shown again
        #expect(!f.isHidden("/c/lectures/old.pdf", in: f.section(a)!))
        #expect(f.section(a)?.items.count == 3)
    }

    @Test func hidingAFolderHidesWhatIsInsideIt() {
        var f = SectionsFile()
        let r = f.addSection(named: "Robotics")
        f.link([item("/c/lectures", .folder)], to: r)
        f.hide("/c/lectures/before mid", in: r)
        let s = f.section(r)!
        #expect(f.isHidden("/c/lectures/before mid/01a.pdf", in: s))
        #expect(!f.isHidden("/c/lectures/before midterm.pdf", in: s))
        f.unhide("/c/lectures/before mid/01a.pdf", in: r)                      // showing a file inside shows the folder
        #expect(f.section(r)?.hidden == nil)
    }

    @Test func draggingMovesBetweenSectionsAndOptionKeepsBoth() {
        var f = SectionsFile()
        let ai = f.addSection(named: "AI"), other = f.addSection(named: "Other PDFs")
        f.link([item("/c/AI/lectures", .folder)], to: ai)
        f.link([item("/c/AI/rec6.pdf", .file), item("/d/paper.pdf", .file)], to: other)
        let rec = f.section(other)!.items[0]

        // A linked PDF moves to the section it is dropped on, at the place it was dropped.
        f.drop(LibraryDrag(what: .item, section: other, item: rec.id), on: ai, at: 0, copy: false, make: item)
        #expect(f.section(ai)?.items.map(\.path) == ["/c/AI/rec6.pdf", "/c/AI/lectures"])
        #expect(f.section(other)?.items.map(\.path) == ["/d/paper.pdf"])

        // With Option it stays where it was too.
        let paper = f.section(other)!.items[0]
        f.drop(LibraryDrag(what: .item, section: other, item: paper.id), on: ai, at: nil, copy: true, make: item)
        #expect(f.section(ai)?.items.last?.path == "/d/paper.pdf")
        #expect(f.section(other)?.items.map(\.path) == ["/d/paper.pdf"])
        #expect(f.section(ai)?.items.last?.id != paper.id)

        // A PDF from inside a linked folder: linked in the new section, hidden in the old one.
        let inside = LibraryDrag(what: .inside, section: ai, path: "/c/AI/lectures/7-old.pdf", kind: .file)
        f.drop(inside, on: other, at: nil, copy: false, make: item)
        #expect(f.section(other)?.items.map(\.path) == ["/d/paper.pdf", "/c/AI/lectures/7-old.pdf"])
        #expect(f.isHidden("/c/AI/lectures/7-old.pdf", in: f.section(ai)!))

        // Dropped back on its own section, a hidden file comes back.
        f.drop(inside, on: ai, at: nil, copy: false, make: item)
        #expect(!f.isHidden("/c/AI/lectures/7-old.pdf", in: f.section(ai)!))

        // Reordering inside a section, and moving sections.
        let first = f.section(ai)!.items[0]
        f.drop(LibraryDrag(what: .item, section: ai, item: first.id), on: ai, at: 3, copy: false, make: item)
        #expect(f.section(ai)?.items.last?.path == "/c/AI/rec6.pdf")
        f.drop(LibraryDrag(what: .section, section: other), on: ai, at: 0, copy: false, make: item)
        #expect(f.sections.map(\.name) == ["Other PDFs", "AI"])
        f.move(section: other, to: 2)
        #expect(f.sections.map(\.name) == ["AI", "Other PDFs"])
    }

    @Test func pathsFollowARenameOrMove() {
        var f = SectionsFile()
        let r = f.addSection(named: "Robotics"), x = f.addSection(named: "Exam")
        f.link([item("/c/lectures", .folder)], to: r)
        f.link([item("/c/lectures/before mid/01a.pdf", .file)], to: x)
        f.hide("/c/lectures/before mid/old.pdf", in: r)
        f.expanded = ["\(r)|/c/lectures/before mid", "\(r)|/c/lectures/before midterm"]
        f.move(path: "/c/lectures/before mid", to: "/c/lectures/pre-midterm")
        #expect(f.section(x)?.items.first?.path == "/c/lectures/pre-midterm/01a.pdf")
        #expect(f.section(r)?.hidden == ["/c/lectures/pre-midterm/old.pdf"])
        #expect(f.expanded == ["\(r)|/c/lectures/pre-midterm", "\(r)|/c/lectures/before midterm"])
        f.move(path: "/c/lectures", to: "/c/Lectures 2026")
        #expect(f.section(r)?.items.first?.path == "/c/Lectures 2026")
        #expect(f.section(x)?.items.first?.path == "/c/Lectures 2026/pre-midterm/01a.pdf")
        f.remove(section: r)
        #expect(f.sections.map(\.name) == ["Exam"])
        #expect(f.expanded?.isEmpty == true)
    }

    // MARK: what a section shows

    @Test func aLinkedFolderShowsItsRealContentsWithSubfolders() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let lectures = root.appendingPathComponent("Robotics/lectures").standardizedFileURL.path
        var f = SectionsFile()
        let r = f.addSection(named: "Robotics")
        f.link([item(lectures, .folder), item(root.appendingPathComponent("Robotics/recitations/rec6.pdf").path, .file),
                item(root.appendingPathComponent("gone.pdf").path, .file)], to: r)
        f.hide(lectures + "/7b-mc-localization.pdf", in: r)
        let (sections, denied) = LibraryScanner.read(f)
        #expect(!denied)
        let s = try #require(sections.first)
        let node = try #require(s.links[0].node)
        // Folders first, then PDFs in Finder's order (10 after 7); no hidden files, packages, empty folders or .txt.
        #expect(node.children.map(\.name) == ["before mid", "7a-bayes-estimation", "10-planning"])
        #expect(node.children[0].children.map(\.name) == ["01a-intro", "01b-transformations"])
        #expect(s.links[1].node?.name == "rec6")
        #expect(s.links[2].node == nil)                                          // a linked PDF that is gone
        #expect(s.hidden.map(\.name) == ["7b-mc-localization"])
        #expect(Set(s.files.map { URL(fileURLWithPath: $0).lastPathComponent }) == [
            "01a-intro.pdf", "01b-transformations.pdf", "7a-bayes-estimation.pdf", "10-planning.pdf", "rec6.pdf",
            "7b-mc-localization.pdf"])
    }

    // MARK: first launch

    private func libraryFile(root: URL) throws -> LibraryFile {
        let r = root.appendingPathComponent("Robotics").path
        let json = """
        {"courses": [{"id": "rob", "name": "Intro to Robotics", "short": "Robotics", "root": "\(r)",
                      "slideDirs": ["lectures"], "layout": {"kind": "twoUp", "frames": [[1, 2, 3, 4], [5, 6, 7, 8]]}}],
         "decks": {"\(r)/lectures/7a-bayes-estimation.pdf": {"title": "L07a Bayes Estimation"},
                   "\(r)/lectures/10-planning.pdf": {"hidden": true},
                   "\(r)/recitations/rec6.pdf": {"course": "rob"}}}
        """
        return try JSONDecoder().decode(LibraryFile.self, from: Data(json.utf8))
    }

    @Test func firstLaunchMakesTheSectionsTheListUsedToShow() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try libraryFile(root: root)
        let opened = root.appendingPathComponent("Robotics/Assignments/hw1.pdf").path
        let f = Library.initialSections(file, extraDecks: [opened, "/nowhere/gone.pdf"])
        #expect(f.sections.map(\.name) == ["Intro to Robotics", "Other PDFs"])
        let robotics = f.sections[0]
        #expect(robotics.id == "rob")
        #expect(robotics.items.map(\.kind) == [.folder, .file])                  // the slide folder, then rec6
        #expect(robotics.items[1].path.hasSuffix("/recitations/rec6.pdf"))
        #expect(robotics.hidden?.count == 1 && robotics.hidden?[0].hasSuffix("/10-planning.pdf") == true)
        #expect(f.sections[1].items.map(\.path) == [opened])
    }

    @Test func decksShowRealNamesAndTakeCourseSettingsFromTheirFolder() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try libraryFile(root: root)
        var f = Library.initialSections(file, extraDecks: [])
        let lectures = f.sections[0].items[0].path
        let exam = f.addSection(named: "Exam prep")
        f.link([item(root.appendingPathComponent("Robotics/Assignments/hw1.pdf").path, .file)], to: exam)
        let (sections, _) = LibraryScanner.read(f)
        let renamed = lectures + "/before mid/01a-intro.pdf"
        let decks = Library.decks(for: sections, file: file, aliases: [renamed: lectures + "/old name.pdf"], links: UserLinks())

        let bayes = try #require(decks[lectures + "/7a-bayes-estimation.pdf"])
        #expect(bayes.title == "7a-bayes-estimation")                            // the real name, not library.json's
        #expect(bayes.knownTitle == "L07a Bayes Estimation")
        #expect(bayes.courseID == "rob" && bayes.courseName == "Intro to Robotics")
        #expect(bayes.layout.isTwoUp)                                            // in the slide folder: 2-up
        #expect(decks[renamed]?.layout.isTwoUp == true)                          // also in a subfolder of it
        #expect(decks[renamed]?.knownFile == "old name.pdf")
        // In the course folder but not its slide folders: the course, but one slide per page.
        let hw = try #require(decks[root.appendingPathComponent("Robotics/Assignments/hw1.pdf").standardizedFileURL.path])
        #expect(hw.courseID == "rob" && !hw.layout.isTwoUp)
        // Hidden decks still open (they are decks), they are just not listed.
        #expect(decks[lectures + "/10-planning.pdf"] != nil)
        // Outside every course folder a deck goes by its section's name.
        let loose = Library.looseDeck(path: root.appendingPathComponent("Robotics/../outside.pdf").path, file: file, aliases: [:])
        #expect(loose == nil)                                                    // no such file
        let outside = root.appendingPathComponent("outside.pdf")
        try Data("%PDF".utf8).write(to: outside)
        #expect(Library.looseDeck(path: outside.path, file: file, aliases: [:])?.courseName == "Other PDFs")
    }

    @Test func renameTakesTheNameWithOrWithoutPdf() {
        #expect(Library.renameTarget("/c/l/7a.pdf", to: " 07a Bayes ").path == "/c/l/07a Bayes.pdf")
        #expect(Library.renameTarget("/c/l/7a.pdf", to: "07a Bayes.PDF").path == "/c/l/07a Bayes.pdf")
        #expect(Library.renameTarget("/c/l/Lecture 7.pdf", to: "L7 Classification").path == "/c/l/L7 Classification.pdf")
        for bad in ["", "  ", ".hidden", "a/b", "a:b", ".pdf"] { #expect(Library.renameTarget("/c/l/7a.pdf", to: bad).problem != nil) }
    }

    /// Decks now show their file names; the assistants' sessions don't restart for that alone.
    @Test func sessionStampsIgnoreTheNewNames() {
        var old = Deck(path: "/c/lectures/Lecture 7.pdf", title: "L7 Classification", courseID: "ml",
                       courseName: "Machine Learning", walkthroughs: [], contextFiles: [])
        var now = old
        now.title = "Lecture 7"
        now.knownTitle = "L7 Classification"
        #expect(SourceRevision.context(for: now) == SourceRevision.context(for: old))
        // A PDF opened by hand used to be in "Other PDFs"; in its course folder it now takes the course's name.
        old.courseName = "Other PDFs"
        #expect(SourceRevision.equivalents(for: now).contains(SourceRevision.context(for: old)))
        #expect(SourceRevision.equivalents(for: old).isEmpty)
    }
}
