import AppKit
import Foundation
import Testing
@testable import CoLearner

/// A drop as AppKit hands it to the outline (no real drag session in tests).
final class FakeDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    init(_ pb: NSPasteboard, mask: NSDragOperation) { draggingPasteboard = pb; draggingSourceOperationMask = mask }
    var draggingSource: Any? { nil }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// The app side of the lecture page, as AppModel does it but without the app: edits apply to `sectionsFile` and
/// the page is shown again.
@MainActor
final class FakeLibrary: LibraryActions {
    var sectionsFile: SectionsFile
    var opened: [String] = []
    var linked: [(paths: [String], section: String, index: Int?)] = []
    var renamed: [(path: String, name: String)] = []
    weak var page: LibraryOutline?

    init(_ f: SectionsFile) { sectionsFile = f }

    func show() { page?.show(LibraryScanner.read(sectionsFile).sections, file: sectionsFile) }
    func openDeck(at path: String) { opened.append(path) }
    func editSections(_ change: (inout SectionsFile) -> Void) { change(&sectionsFile); show() }
    func noteSections(_ change: (inout SectionsFile) -> Void) { change(&sectionsFile) }
    func link(_ urls: [URL], to section: String, at index: Int?) { linked.append((urls.map(\.path), section, index)) }
    func linkPanel(_ kind: LinkedItem.Kind, to section: String) {}
    func newSection() {}
    func removeSection(_ id: String) {}
    func renameFile(_ path: String, to name: String) -> String? { renamed.append((path, name)); return nil }
}

@Suite(.serialized)
@MainActor
struct LibraryPageTests {
    /// Robotics: lectures/{before mid/{01a-intro, 01b}, 7a, 7b}; AI: lectures/{1-intro, 2-agents}; Other: rec6.pdf.
    @MainActor
    private struct Page {
        let root: URL
        let outline: LibraryOutline
        let app: FakLib
        let window: NSWindow
        var ov: NSOutlineView { outline.outline }

        /// The row with this title among the rows on screen.
        func row(_ title: String) -> LibraryRow? {
            (0..<ov.numberOfRows).compactMap { ov.item(atRow: $0) as? LibraryRow }.first { $0.title == title }
        }
        func section(_ name: String) -> LibraryRow? { outline.rows.first { $0.title == name } }
        var titles: [String] { (0..<ov.numberOfRows).compactMap { (ov.item(atRow: $0) as? LibraryRow)?.title } }
        func close() { window.orderOut(nil); try? FileManager.default.removeItem(at: root) }
    }
    private typealias FakLib = FakeLibrary

    private func page() throws -> Page {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-\(UUID().uuidString)").standardizedFileURL
        let fm = FileManager.default
        for f in ["R/lectures/before mid/01a-intro.pdf", "R/lectures/before mid/01b.pdf", "R/lectures/7a.pdf",
                  "R/lectures/7b.pdf", "A/lectures/1-intro.pdf", "A/lectures/2-agents.pdf", "A/rec6.pdf"] {
            let u = root.appendingPathComponent(f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("%PDF".utf8).write(to: u)
        }
        var f = SectionsFile()
        f.link([LinkedItem(kind: .folder, path: root.appendingPathComponent("R/lectures").path)], to: f.addSection(named: "Robotics", id: "r"))
        f.link([LinkedItem(kind: .folder, path: root.appendingPathComponent("A/lectures").path)], to: f.addSection(named: "AI", id: "a"))
        f.link([LinkedItem(kind: .file, path: root.appendingPathComponent("A/rec6.pdf").path)], to: f.addSection(named: "Other PDFs", id: "o"))
        f.addSection(named: "Empty", id: "e")
        let outline = LibraryOutline()
        let app = FakeLibrary(f)
        app.page = outline
        outline.actions = app
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 640, height: 900), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = outline.scroll
        app.show()
        return Page(root: root, outline: outline, app: app, window: window)
    }

    private func pasteboard() -> NSPasteboard { NSPasteboard(name: .init("colearner-page-\(UUID().uuidString)")) }

    @Test func sectionsShowLinkedFoldersOpenAndSubfoldersClosed() throws {
        let p = try page()
        defer { p.close() }
        #expect(p.titles == ["Robotics", "lectures", "before mid", "7a", "7b", "AI", "lectures", "1-intro", "2-agents",
                             "Other PDFs", "rec6", "Empty",
                             "Nothing linked yet. Use + to link a folder or PDFs, or drop them here from Finder."])
        // A click on a subfolder opens it (and is remembered); a click on a PDF opens the deck.
        p.outline.activate(try #require(p.row("before mid")))
        #expect(p.titles.contains("01a-intro"))
        #expect(p.app.sectionsFile.expanded == ["r|" + p.root.appendingPathComponent("R/lectures/before mid").path])
        p.outline.activate(try #require(p.row("01a-intro")))
        #expect(p.app.opened == [p.root.appendingPathComponent("R/lectures/before mid/01a-intro.pdf").path])
        // A click on a heading closes the section, and it stays closed when the page is drawn again.
        p.outline.activate(try #require(p.section("AI")))
        #expect(!p.titles.contains("1-intro"))
        #expect(p.app.sectionsFile.section("a")?.collapsed == true)
        p.app.show()
        #expect(!p.titles.contains("1-intro") && p.titles.contains("01a-intro"))
    }

    @Test func rightClickMenusFitTheRow() throws {
        let p = try page()
        defer { p.close() }
        func titles(_ r: LibraryRow?) -> [String] { (r.map { p.outline.menuItems(for: $0) } ?? []).map { $0.isSeparatorItem ? "-" : $0.title } }
        #expect(titles(p.section("AI")) == ["Link Folder…", "Link PDFs…", "-", "Rename Section", "Remove Section…", "-", "New Section"])
        #expect(titles(p.row("7a")) == ["Open", "Show in Finder", "Rename File…", "-", "Hide from Section"])
        #expect(titles(p.row("before mid")) == ["Show in Finder", "-", "Hide from Section"])
        #expect(titles(p.row("rec6")) == ["Open", "Show in Finder", "Rename File…", "-", "Remove from Section"])
        // Hide: the PDF goes under "Hidden (1)", whose menu brings it back.
        let b7 = try #require(p.row("7b"))
        let hide = try #require(p.outline.menuItems(for: b7).last)
        _ = hide.target?.perform(hide.action)
        #expect(!p.titles.contains("7b") && p.titles.contains("Hidden (1)"))
        p.outline.activate(try #require(p.row("Hidden (1)")))
        #expect(titles(p.row("7b")) == ["Show in Section Again", "-", "Open", "Show in Finder"])
        let hidden7b = try #require(p.row("7b"))
        let again = try #require(p.outline.menuItems(for: hidden7b).first)
        _ = again.target?.perform(again.action)
        #expect(p.titles.contains("7b") && !p.titles.contains("Hidden (1)"))
    }

    @Test func dragARowToAnotherSectionMovesItAndOptionKeepsBoth() throws {
        let p = try page()
        defer { p.close() }
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        func drag(_ r: LibraryRow) {
            pb.clearContents()
            pb.writeObjects([p.outline.outlineView(p.ov, pasteboardWriterForItem: r)!])
        }
        // rec6 (linked in Other PDFs) dropped on a PDF row in AI: the drop goes to the AI section, as a move.
        drag(try #require(p.row("rec6")))
        let onRow = p.outline.outlineView(p.ov, validateDrop: FakeDrop(pb, mask: [.move, .copy]),
                                          proposedItem: p.row("1-intro"), proposedChildIndex: NSOutlineViewDropOnItemIndex)
        #expect(onRow == .move)
        #expect(p.outline.outlineView(p.ov, acceptDrop: FakeDrop(pb, mask: [.move, .copy]), item: p.section("AI"),
                                      childIndex: NSOutlineViewDropOnItemIndex))
        #expect(p.app.sectionsFile.section("a")?.items.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["lectures", "rec6.pdf"])
        #expect(p.app.sectionsFile.section("o")?.items.isEmpty == true)

        // 7a from Robotics' folder, with Option, between AI's items: linked at the top of AI, still in Robotics.
        drag(try #require(p.row("7a")))
        #expect(p.outline.outlineView(p.ov, validateDrop: FakeDrop(pb, mask: .copy), proposedItem: p.section("AI"),
                                      proposedChildIndex: 0) == .copy)
        #expect(p.outline.outlineView(p.ov, acceptDrop: FakeDrop(pb, mask: .copy), item: p.section("AI"), childIndex: 0))
        #expect(p.app.sectionsFile.section("a")?.items.first?.path == p.root.appendingPathComponent("R/lectures/7a.pdf").path)
        #expect(p.app.sectionsFile.section("r")?.hidden == nil)
        // Without Option it would leave Robotics (hidden there).
        drag(try #require(p.row("7b")))
        #expect(p.outline.outlineView(p.ov, acceptDrop: FakeDrop(pb, mask: [.move, .copy]), item: p.section("Empty"),
                                      childIndex: NSOutlineViewDropOnItemIndex))
        #expect(p.app.sectionsFile.section("r")?.hidden == [p.root.appendingPathComponent("R/lectures/7b.pdf").path])
        #expect(p.app.sectionsFile.section("e")?.items.count == 1)

        // Dropping a listed PDF back on its own section does nothing, so it is refused.
        drag(try #require(p.row("before mid")))
        #expect(p.outline.outlineView(p.ov, validateDrop: FakeDrop(pb, mask: [.move, .copy]), proposedItem: p.section("Robotics"),
                                      proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
    }

    @Test func sectionsReorderBetweenHeadingsOnly() throws {
        let p = try page()
        defer { p.close() }
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([p.outline.outlineView(p.ov, pasteboardWriterForItem: try #require(p.section("Other PDFs")))!])
        // Over a row inside AI: the drop line goes after the AI section.
        #expect(p.outline.outlineView(p.ov, validateDrop: FakeDrop(pb, mask: [.move, .copy]), proposedItem: p.row("2-agents"),
                                      proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        #expect(p.outline.outlineView(p.ov, acceptDrop: FakeDrop(pb, mask: [.move, .copy]), item: nil, childIndex: 0))
        #expect(p.app.sectionsFile.sections.map(\.name) == ["Other PDFs", "Robotics", "AI", "Empty"])
    }

    @Test func pdfsAndFoldersDroppedFromFinderAreLinked() throws {
        let p = try page()
        defer { p.close() }
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let notes = p.root.appendingPathComponent("A/notes.txt")
        try Data("x".utf8).write(to: notes)
        pb.clearContents()
        pb.writeObjects([p.root.appendingPathComponent("A/lectures") as NSURL, p.root.appendingPathComponent("A/rec6.pdf") as NSURL,
                         notes as NSURL])
        let op = p.outline.outlineView(p.ov, validateDrop: FakeDrop(pb, mask: [.copy, .link, .generic]),
                                       proposedItem: p.section("Empty"), proposedChildIndex: NSOutlineViewDropOnItemIndex)
        #expect(op == .link)
        #expect(p.outline.outlineView(p.ov, acceptDrop: FakeDrop(pb, mask: [.copy, .link]), item: p.section("Empty"),
                                      childIndex: NSOutlineViewDropOnItemIndex))
        #expect(p.app.linked.count == 1)
        #expect(p.app.linked.first?.paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["lectures", "rec6.pdf"])
        #expect(p.app.linked.first?.section == "e")
        // Only a text file: nothing to link.
        pb.clearContents()
        pb.writeObjects([notes as NSURL])
        #expect(p.outline.outlineView(p.ov, validateDrop: FakeDrop(pb, mask: [.copy, .link]), proposedItem: p.section("AI"),
                                      proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
    }

    @Test func namesAreEditedInPlace() throws {
        let p = try page()
        defer { p.close() }
        // A section: type a name, press Return (here: leave the field).
        p.outline.beginRename(section: "e")
        let editor = try #require(p.window.firstResponder as? NSTextView)
        let f = try #require(editor.delegate as? NSTextField)
        #expect(f.isEditable)
        f.stringValue = "Exam 2 review"
        p.window.makeFirstResponder(p.ov)
        #expect(p.app.sectionsFile.section("e")?.name == "Exam 2 review")
        #expect(p.section("Exam 2 review") != nil)

        // Esc leaves the name as it was.
        p.outline.beginRename(section: "a")
        let tv = try #require(p.window.firstResponder as? NSTextView)
        let g = try #require(tv.delegate as? NSTextField)
        g.stringValue = "Something else"
        #expect(p.outline.control(g, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(p.app.sectionsFile.section("a")?.name == "AI")

        // A PDF: Rename File… edits the real name (without .pdf) and hands it to the app.
        let a7 = try #require(p.row("7a"))
        let rename = try #require(p.outline.menuItems(for: a7).first { $0.title == "Rename File…" })
        _ = rename.target?.perform(rename.action)
        let editor2 = try #require(p.window.firstResponder as? NSTextView)
        let h = try #require(editor2.delegate as? NSTextField)
        #expect(h.stringValue == "7a")
        h.stringValue = "07a Bayes Estimation"
        p.window.makeFirstResponder(p.ov)
        #expect(p.app.renamed.map(\.name) == ["07a Bayes Estimation"])
        #expect(p.app.renamed.first?.path == p.root.appendingPathComponent("R/lectures/7a.pdf").path)
    }

    @Test func dropsUnderTheLastRowGoToTheEnd() throws {
        let p = try page()
        defer { p.close() }
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        // A PDF dropped in the empty space under the list: into the last section, not the first.
        pb.clearContents()
        pb.writeObjects([p.outline.outlineView(p.ov, pasteboardWriterForItem: try #require(p.row("rec6")))!])
        #expect(p.outline.outlineView(p.ov, validateDrop: FakeDrop(pb, mask: [.move, .copy]), proposedItem: nil,
                                      proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        #expect(p.outline.outlineView(p.ov, acceptDrop: FakeDrop(pb, mask: [.move, .copy]), item: nil,
                                      childIndex: NSOutlineViewDropOnItemIndex))
        #expect(p.app.sectionsFile.section("e")?.items.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["rec6.pdf"])
        #expect(p.app.sectionsFile.section("r")?.items.count == 1)
        // A heading dropped there becomes the last section.
        pb.clearContents()
        pb.writeObjects([p.outline.outlineView(p.ov, pasteboardWriterForItem: try #require(p.section("Robotics")))!])
        #expect(p.outline.outlineView(p.ov, acceptDrop: FakeDrop(pb, mask: [.move, .copy]), item: nil,
                                      childIndex: NSOutlineViewDropOnItemIndex))
        #expect(p.app.sectionsFile.sections.map(\.name) == ["AI", "Other PDFs", "Empty", "Robotics"])
    }

    @Test func aSubfolderLinkedOnItsOwnAndInsideItsParentHasRowsOfItsOwn() throws {
        let p = try page()
        defer { p.close() }
        let lectures = p.root.appendingPathComponent("R/lectures").path
        p.app.editSections { f in
            f.link([LinkedItem(kind: .folder, path: lectures + "/before mid")], to: "e")
            f.link([LinkedItem(kind: .folder, path: lectures)], to: "e")
        }
        p.app.show()
        for r in p.outline.rows where r.title == "Empty" {
            for link in r.children where link.isFolder { p.ov.expandItem(link, expandChildren: true) }
        }
        let rows = (0..<p.ov.numberOfRows).compactMap { p.ov.item(atRow: $0) as? LibraryRow }.filter { $0.title == "01a-intro" }
        #expect(rows.count >= 2)
        #expect(Set(rows.map { ObjectIdentifier($0) }).count == rows.count)    // one object per place
        #expect(rows.allSatisfy { p.ov.row(forItem: $0) >= 0 })
    }

    @Test func openingAClosedSectionOpensItsFoldersAsSaved() throws {
        let p = try page()
        defer { p.close() }
        p.outline.activate(try #require(p.row("before mid")))                 // saved open
        p.outline.activate(try #require(p.section("Robotics")))               // section closed
        p.app.show()                                                          // drawn again while closed (a relaunch)
        #expect(!p.titles.contains("7a"))
        // Closing the section left its folders' own state alone.
        #expect(p.app.sectionsFile.section("r")?.items.first?.collapsed == nil)
        #expect(p.app.sectionsFile.expanded?.count == 1)
        p.outline.activate(try #require(p.section("Robotics")))
        #expect(p.titles.contains("7a") && p.titles.contains("01a-intro"))
    }

    /// Finder changes something while a name is being typed: the page waits, and after the name is in it shows both
    /// (never the older state again).
    @Test func aReloadDuringRenameWaitsAndIsNotReplayedOverTheNewName() throws {
        let p = try page()
        defer { p.close() }
        p.outline.beginRename(section: "e")
        let editor = try #require(p.window.firstResponder as? NSTextView)
        let field = try #require(editor.delegate as? NSTextField)
        // A folder linked meanwhile (as a reload from Finder would bring it).
        p.app.sectionsFile.link([LinkedItem(kind: .folder, path: p.root.appendingPathComponent("A/lectures").path)], to: "e")
        p.app.show()
        #expect(p.titles.contains("Nothing linked yet. Use + to link a folder or PDFs, or drop them here from Finder."))
        field.stringValue = "Exam 2"
        p.window.makeFirstResponder(p.ov)
        #expect(p.section("Exam 2") != nil)
        #expect(!p.titles.contains("Nothing linked yet. Use + to link a folder or PDFs, or drop them here from Finder."))
        #expect(p.titles.filter { $0 == "1-intro" }.count == 2)
    }

    /// The highlight follows the pointer, one row at a time: rows that pass under a still pointer while scrolling
    /// don't stay lit.
    @Test func onlyTheRowUnderThePointerIsLit() throws {
        let p = try page()
        defer { p.close() }
        p.window.contentView?.layoutSubtreeIfNeeded()
        let views = (0..<p.ov.numberOfRows).compactMap { p.ov.rowView(atRow: $0, makeIfNecessary: true) as? LibraryRowView }
        func lit() -> [String] {
            views.indices.filter { views[$0].hovering }.compactMap { (p.ov.item(atRow: $0) as? LibraryRow)?.title }
        }
        func pointer(on title: String) throws -> NSPoint {
            let r = p.ov.rect(ofRow: p.ov.row(forItem: try #require(p.row(title))))
            return NSPoint(x: r.midX, y: r.midY)
        }
        // The pointer stays put while rows scroll under it: each step lights the row now there, and only that one.
        for title in ["7a", "7b", "AI", "1-intro", "2-agents", "rec6"] {
            p.outline.outline.hover(at: try pointer(on: title))
            #expect(lit() == [title])
        }
        // Leaving the list, or the page being drawn again with the pointer elsewhere, lights nothing.
        p.outline.outline.hover(at: NSPoint(x: -50, y: -50))
        #expect(lit().isEmpty)
        p.outline.outline.hover(at: try pointer(on: "7a"))
        p.app.show()
        let after = (0..<p.ov.numberOfRows).compactMap { p.ov.rowView(atRow: $0, makeIfNecessary: false) as? LibraryRowView }
        #expect(after.filter(\.hovering).count <= 1)
    }

    /// Pictures of the page (set COLEARNER_TEST_SNAPSHOTS=<folder>): the real course folders as the first launch lists
    /// them, and a small library with a "before mid" subfolder open, a hidden file and an empty section.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLEARNER_TEST_SNAPSHOTS"] != nil))
    func snapshots() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COLEARNER_TEST_SNAPSHOTS"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func render(_ outline: LibraryOutline, _ name: String, dark: Bool, height: CGFloat) throws {
            let w = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 760, height: height), styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: height))
            box.wantsLayer = true
            box.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).cgColor
            outline.scroll.frame = box.bounds.insetBy(dx: 16, dy: 8)
            box.addSubview(outline.scroll)
            w.contentView = box
            box.layoutSubtreeIfNeeded()
            outline.outline.sizeLastColumnToFit()
            box.layoutSubtreeIfNeeded()
            let rep = try #require(box.bitmapImageRepForCachingDisplay(in: box.bounds))
            box.cacheDisplay(in: box.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            w.orderOut(nil)
        }
        // The library on this Mac (read only); COLEARNER_SNAPSHOT_PDF can name an extra PDF for Other PDFs.
        let file = Library.readFile()
        let extra = ProcessInfo.processInfo.environment["COLEARNER_SNAPSHOT_PDF"].map { [$0] } ?? []
        let real = Library.initialSections(file, extraDecks: extra)
        // How long reading the library again takes (what coming back to the app costs), first and second time.
        for round in 1...2 {
            let t0 = Date()
            let read = LibraryScanner.read(real)
            let decks = Library.decks(for: read.sections, file: file, aliases: [:], links: UserLinks())
            print("library read \(round): \(decks.count) decks in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
        let app = FakeLibrary(real)
        let outline = LibraryOutline()
        app.page = outline
        outline.actions = app
        app.show()
        try render(outline, "real-light", dark: false, height: 2300)
        try render(outline, "real-dark", dark: true, height: 2300)

        let p = try page()
        defer { p.close() }
        p.outline.activate(try #require(p.row("before mid")))
        let b7 = try #require(p.row("7b"))
        let hide = try #require(p.outline.menuItems(for: b7).last)
        _ = hide.target?.perform(hide.action)
        p.outline.activate(try #require(p.row("Hidden (1)")))
        try render(p.outline, "small-light", dark: false, height: 560)
        try render(p.outline, "small-dark", dark: true, height: 560)
    }
}
