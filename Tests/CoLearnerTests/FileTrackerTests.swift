import CoreServices
import Foundation
import Testing
@testable import CoLearner

/// PDFs renamed or moved in Finder keep their chats and settings: the tracker finds them again (same inode and size
/// among the listed PDFs, or by bookmark), chat files take the new name, links and per-deck settings follow, and the
/// watcher notices changes in linked folders.
@Suite(.serialized)
@MainActor
struct FileTrackerTests {
    private func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.standardizedFileURL
    }

    private func pdf(_ u: URL, _ text: String = "%PDF-1.4\n") throws -> String {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u.standardizedFileURL.path
    }

    private func mv(_ a: String, _ b: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: b).deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(Darwin.rename(a, b) == 0)
    }

    @Test func aRenamedPDFIsFoundByItsInodeAndKeepsItsLibraryName() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try pdf(dir.appendingPathComponent("lectures/01a-intro.pdf"))
        let b = try pdf(dir.appendingPathComponent("lectures/01b-transformations.pdf"), "%PDF other\n")
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        t.register([a, b])
        let renamed = dir.appendingPathComponent("lectures/L01a Introduction.pdf").path
        try mv(a, renamed)
        let moves = t.followFiles(listed: [renamed, b]).files
        #expect(moves == [PathMove(old: a, new: renamed)])
        t.moved(moves)
        #expect(t.aliases[renamed] == a)
        #expect(t.followFiles(listed: [renamed, b]).files.isEmpty)
        // Renamed again: library.json still knows it by its first path.
        let again = dir.appendingPathComponent("lectures/intro.pdf").path
        try mv(renamed, again)
        t.moved(t.followFiles(listed: [again, b]).files)
        #expect(t.aliases[again] == a)
        // A fresh tracker reads what was saved.
        #expect(FileTracker(url: dir.appendingPathComponent("files.json")).aliases[again] == a)
    }

    @Test func onlyTheCapitalsChanged() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try pdf(dir.appendingPathComponent("lecture 7.pdf"))
        let upper = dir.appendingPathComponent("Lecture 7.pdf").path
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        t.register([a])
        try mv(a, upper)
        // On a case-insensitive disk the old spelling still "exists"; the listing shows the new one.
        guard FileManager.default.fileExists(atPath: a) else { return }
        #expect(t.followFiles(listed: [upper]).files == [PathMove(old: a, new: upper)])
    }

    @Test func aPDFMovedOutOfTheLinkedFoldersIsFoundByItsBookmark() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try pdf(dir.appendingPathComponent("lectures/7a.pdf"))
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        t.register([a])
        let away = dir.appendingPathComponent("elsewhere/7a.pdf").path
        try mv(a, away)
        #expect(t.followFiles(listed: []).files == [PathMove(old: a, new: away)])
        // Into the Trash counts as gone, not moved.
        let b = try pdf(dir.appendingPathComponent("lectures/7b.pdf"))
        t.register([b])
        try mv(b, dir.appendingPathComponent(".Trash/7b.pdf").path)
        #expect(t.followFiles(listed: []).files.allSatisfy { $0.old != b })
    }

    @Test func aRenamedSubfolderMovesWithItsPDFs() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = try pdf(dir.appendingPathComponent("lectures/before mid/01a.pdf"))
        let two = try pdf(dir.appendingPathComponent("lectures/before mid/01b.pdf"), "%PDF b\n")
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        t.register([one, two])
        let old = dir.appendingPathComponent("lectures/before mid").path, new = dir.appendingPathComponent("lectures/pre-midterm").path
        try mv(old, new)
        let moves = t.followFiles(listed: [new + "/01a.pdf", new + "/01b.pdf"])
        #expect(moves.folders == [PathMove(old: old, new: new)])
        #expect(Set(moves.files) == [PathMove(old: one, new: new + "/01a.pdf"), PathMove(old: two, new: new + "/01b.pdf")])
    }

    /// Finder's "Keep Both" when merging R5 into R6: R5/notes.pdf became "R6/notes 2.pdf" next to R6's own notes.pdf.
    /// R5 didn't simply move to R6, so nothing of R5/notes may land on R6/notes.
    @Test func aFolderMergedWithKeepBothIsNotAFolderMove() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try pdf(dir.appendingPathComponent("R5/a.pdf"))
        let notes5 = try pdf(dir.appendingPathComponent("R5/notes.pdf"), "%PDF five\n")
        let notes6 = try pdf(dir.appendingPathComponent("R6/notes.pdf"), "%PDF six\n")
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        t.register([a, notes5, notes6])
        let r6 = dir.appendingPathComponent("R6").path
        try mv(a, r6 + "/a.pdf")
        try mv(notes5, r6 + "/notes 2.pdf")
        try FileManager.default.removeItem(atPath: dir.appendingPathComponent("R5").path)
        let moves = t.followFiles(listed: [r6 + "/a.pdf", r6 + "/notes.pdf", r6 + "/notes 2.pdf"])
        #expect(moves.folders.isEmpty)
        #expect(Set(moves.files) == [PathMove(old: a, new: r6 + "/a.pdf"), PathMove(old: notes5, new: r6 + "/notes 2.pdf")])
    }

    @Test func aNewFileWhereTheOldOneWasIsANewDeck() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try pdf(dir.appendingPathComponent("a.pdf"))
        let b = dir.appendingPathComponent("b.pdf").path
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        t.register([a])
        try mv(a, b)
        _ = try pdf(URL(fileURLWithPath: a), "%PDF a newer download\n")
        #expect(t.followFiles(listed: [a, b]).files == [PathMove(old: a, new: b)])
    }

    @Test func swappedNamesSwapTheirState() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try pdf(dir.appendingPathComponent("a.pdf")), b = try pdf(dir.appendingPathComponent("b.pdf"), "%PDF bb\n")
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        t.register([a, b])
        let tmp = dir.appendingPathComponent("tmp.pdf").path
        try mv(a, tmp); try mv(b, a); try mv(tmp, b)
        #expect(Set(t.followFiles(listed: [a, b]).files) == [PathMove(old: a, new: b), PathMove(old: b, new: a)])
    }

    @Test func aLinkedFolderRenamedInFinderIsFollowed() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try pdf(dir.appendingPathComponent("lectures/1.pdf"))
        let lectures = dir.appendingPathComponent("lectures").path
        var f = SectionsFile()
        let s = f.addSection(named: "AI")
        f.link([LinkedItem.make(path: lectures, kind: .folder)], to: s)
        let t = FileTracker(url: dir.appendingPathComponent("files.json"))
        #expect(t.followLinks(&f).isEmpty)
        let renamed = dir.appendingPathComponent("Lectures 2026").path
        try mv(lectures, renamed)
        #expect(t.followLinks(&f) == [PathMove(old: lectures, new: renamed)])
        #expect(f.section(s)?.items.first?.path == renamed)
        // Only the capitals of a linked folder changed: on a disk that ignores them the old spelling still opens.
        let caps = dir.appendingPathComponent("LECTURES 2026").path
        try mv(renamed, caps)
        if FileManager.default.fileExists(atPath: renamed) {
            #expect(t.followLinks(&f) == [PathMove(old: renamed, new: caps)])
            #expect(f.section(s)?.items.first?.path == caps)
        }
        // A linked PDF moved to the Trash isn't followed there.
        let rec = try pdf(dir.appendingPathComponent("rec.pdf"))
        f.link([LinkedItem.make(path: rec, kind: .file)], to: s)
        try mv(rec, dir.appendingPathComponent(".Trash/rec.pdf").path)
        #expect(t.followLinks(&f).isEmpty)
        #expect(f.section(s)?.items.last?.path == rec)
    }

    // MARK: what follows a move

    private func chat(_ store: ChatStore, _ deck: String, _ texts: String...) {
        let c = store.current(deck)
        store.update(deck, c.id) { conv in for t in texts { conv.messages.append(ChatMessage(role: .user, text: t)) } }
        store.save(deck)
    }

    private func texts(_ store: ChatStore, _ deck: String) -> Set<String> {
        Set(store.conversations(deck).flatMap { $0.messages.map(\.text) })
    }

    @Test func chatFilesTakeTheNewNameAndNothingFollowsTheOldPath() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chats = dir.appendingPathComponent("chats")
        let old = "/c/lectures/01a-intro.pdf", new = "/c/lectures/before mid/L01a Intro.pdf"
        let store = ChatStore(directory: chats)
        chat(store, old, "What is a frame?")
        let conv = store.current(old).id
        store.move(PathMove(old: old, new: new))
        let names = try FileManager.default.contentsOfDirectory(atPath: chats.path)
        #expect(names == [ChatArchiveFile.base(new) + ".chat2.json"])
        #expect(ChatArchiveFile.decode(chats.appendingPathComponent(names[0]))?.deckPath == new)
        #expect(store.current(new).id == conv)
        #expect(texts(store, new) == ["What is a frame?"])
        // A new PDF at the old path is a new deck: it shows nothing of the moved one, and writes nothing into it.
        #expect(texts(store, old).isEmpty)
        chat(store, old, "about the new download")
        #expect(texts(store, new) == ["What is a frame?"])
        #expect(texts(ChatStore(directory: chats), old) == ["about the new download"])
        #expect(ChatStore(directory: chats).current(new).id == conv)
        // Search finds both, each under its own deck.
        let found = ChatSearch.find(directory: chats, cached: [:], query: "a")
        #expect(Set(found.map(\.deckPath)) == [old, new])
    }

    /// A PDF put where another was (Finder's Replace, or trash the old one and rename the new one onto its name):
    /// whichever side was open this session, both histories end up under the path, in one file, findable.
    @Test func replacingAPDFKeepsBothHistories() throws {
        for (loadSource, loadTarget) in [(true, false), (false, true), (true, true), (false, false)] {
            let dir = try folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            let chats = dir.appendingPathComponent("chats")
            let v2 = "/c/lectures/8-AI_csp v2.pdf", v1 = "/c/lectures/8-AI_csp.pdf"
            let writer = ChatStore(directory: chats)
            chat(writer, v1, "old question 1", "old question 2")
            chat(writer, v2, "new question")
            let store = ChatStore(directory: chats)
            if loadSource { _ = store.current(v2) }
            if loadTarget { _ = store.current(v1) }
            store.move(PathMove(old: v2, new: v1))
            #expect(texts(store, v1) == ["old question 1", "old question 2", "new question"], "\(loadSource) \(loadTarget)")
            store.save(v1)   // what opening the deck does next
            let fresh = ChatStore(directory: chats)
            #expect(texts(fresh, v1) == ["old question 1", "old question 2", "new question"], "\(loadSource) \(loadTarget)")
            #expect(fresh.current(v1).messages.map(\.text) == ["new question"])
            #expect(texts(fresh, v2).isEmpty)
            let main = chats.appendingPathComponent(ChatArchiveFile.base(v1) + ".chat2.json")
            #expect(ChatArchiveFile.decode(main)?.deckPath == v1)
            #expect(Set(ChatSearch.find(directory: chats, cached: [:], query: "question").map(\.deckPath)) == [v1])
        }
    }

    @Test func aMovedFolderTakesAllItsDecksChats() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chats = dir.appendingPathComponent("chats")
        let writer = ChatStore(directory: chats)
        for p in ["/c/mid/a.pdf", "/c/mid/b.pdf", "/c/new/a.pdf"] { chat(writer, p, "about \(p)") }
        // A fresh store (nothing in memory) moves /c/mid to /c/new, where a.pdf already has its own chat.
        let store = ChatStore(directory: chats)
        store.move(PathMove(old: "/c/mid", new: "/c/new"))
        #expect(texts(store, "/c/new/a.pdf") == ["about /c/mid/a.pdf", "about /c/new/a.pdf"])
        #expect(texts(store, "/c/new/b.pdf") == ["about /c/mid/b.pdf"])
        let names = try FileManager.default.contentsOfDirectory(atPath: chats.path)
        #expect(!names.contains(ChatArchiveFile.base("/c/mid/a.pdf") + ".chat2.json"))
        #expect(names.contains { $0.contains(".moved-") })                    // the merged-in file is kept aside
        // The file kept aside is not a deck's chat file: a later move of /c/mid doesn't pick it up.
        store.move(PathMove(old: "/c/mid", new: "/c/elsewhere"))
        #expect(texts(store, "/c/elsewhere/a.pdf").isEmpty)
    }

    @Test func linksAndPerDeckSettingsFollow() {
        var links = UserLinks()
        links.walkthroughs["/c/a.pdf"] = [StudyPage(title: "W", path: "/w.html")]
        links.walkthroughs["/c/b.pdf"] = [StudyPage(title: "X", path: "/x.html")]
        links.unlinked = ["/c/a.pdf": [StudyPage(title: "N", path: "/n.pdf")]]
        links.extraDecks = ["/c/a.pdf", "/c/b.pdf"]
        let follow = { (p: String) in p == "/c/a.pdf" ? "/c/b.pdf" : p }
        let moved = links.following(follow)
        #expect(moved.walkthroughs["/c/b.pdf"]?.map(\.path) == ["/x.html", "/w.html"] || moved.walkthroughs["/c/b.pdf"]?.map(\.path) == ["/w.html", "/x.html"])
        #expect(moved.walkthroughs["/c/a.pdf"] == nil)
        #expect(moved.unlinked?["/c/b.pdf"]?.map(\.path) == ["/n.pdf"])
        #expect(moved.extraDecks == ["/c/b.pdf"])

        let suite = "colearner-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(12, forKey: "lastPage./c/lectures/7a.pdf")
        d.set(3, forKey: "lastPage./c/other.pdf")
        d.set(["/c/lectures/7a.pdf", "/c/other.pdf"], forKey: "openDecks")
        d.set("/c/lectures/7a.pdf", forKey: "currentDeck")
        let m = PathMove(old: "/c/lectures", new: "/c/Lectures 2026")
        PathMove.moveDefaults(in: d) { m.apply($0) ?? $0 }
        #expect(d.integer(forKey: "lastPage./c/Lectures 2026/7a.pdf") == 12)
        #expect(d.object(forKey: "lastPage./c/lectures/7a.pdf") == nil)
        #expect(d.integer(forKey: "lastPage./c/other.pdf") == 3)
        #expect(d.stringArray(forKey: "openDecks") == ["/c/Lectures 2026/7a.pdf", "/c/other.pdf"])
        #expect(d.string(forKey: "currentDeck") == "/c/Lectures 2026/7a.pdf")
        // Swapped names swap their slides; none is lost.
        d.set(12, forKey: "lastPage./c/a.pdf")
        d.set(30, forKey: "lastPage./c/b.pdf")
        PathMove.moveDefaults(in: d) { $0 == "/c/a.pdf" ? "/c/b.pdf" : $0 == "/c/b.pdf" ? "/c/a.pdf" : $0 }
        #expect(d.integer(forKey: "lastPage./c/a.pdf") == 30 && d.integer(forKey: "lastPage./c/b.pdf") == 12)
    }

    // MARK: watching

    @Test func theWatcherNoticesPDFsAndFoldersButNotFinderClutter() async throws {
        #expect(LibraryWatcher.matters("/c/lectures/7a.pdf", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)))
        #expect(LibraryWatcher.matters("/c/lectures/new folder",
                                       flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)))
        #expect(!LibraryWatcher.matters("/c/lectures/.DS_Store", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)))
        #expect(!LibraryWatcher.matters("/c/lectures/notes.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)))
        #expect(LibraryWatcher.matters("/c/lectures", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)))

        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lectures/before mid"), withIntermediateDirectories: true)
        var f = SectionsFile()
        f.link([LinkedItem(kind: .folder, path: dir.appendingPathComponent("lectures").path)], to: f.addSection(named: "R"))
        var fired = 0
        let w = LibraryWatcher { fired += 1 }
        w.watch(f)
        try await Task.sleep(for: .milliseconds(300))
        _ = try pdf(dir.appendingPathComponent("lectures/before mid/02a.pdf"))
        for _ in 0..<60 where fired == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(fired == 1)
    }
}
