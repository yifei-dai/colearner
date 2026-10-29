import AppKit
import Foundation
import PDFKit
import Testing
@testable import CoLearner

@MainActor
struct StudyPDFTests {
    @Test func notesMapRefreshesExistingSlidesAndDiscoversNewDecks() throws {
        let fixture = try NotesFixture()
        defer { fixture.remove() }
        try fixture.write([(deck: "first.pdf", slide: 1)])
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "first.pdf") == [1: 1])
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "second.pdf").isEmpty)

        try fixture.write([(deck: "second.pdf", slide: 4), (deck: "first.pdf", slide: 1),
                           (deck: "first.pdf", slide: 2)])
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "first.pdf") == [1: 2, 2: 3])
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "second.pdf") == [4: 1])
    }

    @Test func notesMapRetriesMissingInvalidAndRecreatedFiles() throws {
        let fixture = try NotesFixture()
        defer { fixture.remove() }
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "first.pdf").isEmpty)
        try Data("PDF build in progress".utf8).write(to: fixture.url, options: .atomic)
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "first.pdf").isEmpty)
        try fixture.write([(deck: "first.pdf", slide: 3)])
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "first.pdf") == [3: 1])

        try FileManager.default.removeItem(at: fixture.url)
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "first.pdf").isEmpty)
        try fixture.write([(deck: "first.pdf", slide: 5)])
        #expect(ScribeMap.pages(notes: fixture.url.path, deckFile: "first.pdf") == [5: 1])
    }

    @Test func notesViewerChangesDeckMapAndReloadsReplacement() throws {
        let fixture = try NotesFixture()
        defer { fixture.remove() }
        try fixture.write([(deck: "first.pdf", slide: 1), (deck: "second.pdf", slide: 7)])
        let viewer = StudyPDFController()
        viewer.show(fixture.studyPage, deckFile: "first.pdf", slide: 1, follow: true)
        let original = try #require(viewer.view.document)
        #expect(original.pageCount == 2)
        #expect(viewer.status == "Notes page 1 shows slide 1")

        viewer.show(fixture.studyPage, deckFile: "second.pdf", slide: 7, follow: true)
        #expect(viewer.view.document === original)
        #expect(viewer.status == "Notes page 2 shows slide 7")
        #expect(viewer.view.currentPage === original.page(at: 1))

        try fixture.write([(deck: "second.pdf", slide: 7), (deck: "first.pdf", slide: 2),
                           (deck: "first.pdf", slide: 1)])
        viewer.show(fixture.studyPage, deckFile: "second.pdf", slide: 7, follow: true)
        let replacement = try #require(viewer.view.document)
        #expect(replacement !== original)
        #expect(replacement.pageCount == 3)
        #expect(viewer.status == "Notes page 1 shows slide 7")
        #expect(viewer.view.currentPage === replacement.page(at: 0))
        viewer.show(fixture.studyPage, deckFile: "first.pdf", slide: 1, follow: true)
        #expect(viewer.status == "Notes page 3 shows slide 1")
    }

    @Test func notesViewerRecoversAfterDeletionAndFailedBuild() throws {
        let fixture = try NotesFixture()
        defer { fixture.remove() }
        try fixture.write([(deck: "first.pdf", slide: 1)])
        let viewer = StudyPDFController()
        viewer.show(fixture.studyPage, deckFile: "first.pdf", slide: 1, follow: true)
        #expect(viewer.view.document != nil)

        try FileManager.default.removeItem(at: fixture.url)
        viewer.show(fixture.studyPage, deckFile: "first.pdf", slide: 1, follow: false)
        #expect(viewer.view.document == nil)
        #expect(viewer.status == nil)

        try Data("PDF build in progress".utf8).write(to: fixture.url, options: .atomic)
        viewer.show(fixture.studyPage, deckFile: "first.pdf", slide: 1, follow: true)
        #expect(viewer.view.document == nil)
        try fixture.write([(deck: "first.pdf", slide: 1), (deck: "first.pdf", slide: 2)])
        viewer.show(fixture.studyPage, deckFile: "first.pdf", slide: 2, follow: true)
        #expect(viewer.view.document?.pageCount == 2)
        #expect(viewer.status == "Notes page 2 shows slide 2")
    }

    /// Ask quotes the text selected in the notes only while it is on screen; once Follow slides has moved the notes on,
    /// the page on screen goes instead.
    @Test func notesAskLeavesASelectionTheNotesMovedAwayFrom() throws {
        let fixture = try NotesFixture()
        defer { fixture.remove() }
        try fixture.write((1...8).map { (deck: "deck.pdf", slide: $0) })
        let viewer = StudyPDFController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        viewer.show(fixture.studyPage, deckFile: "deck.pdf", slide: 1, follow: true)
        let doc = try #require(viewer.view.document)
        let first = try #require(doc.page(at: 0))
        viewer.view.setCurrentSelection(first.selection(for: first.bounds(for: .cropBox)), animate: false)
        let quote = try #require(viewer.selectionQuote())
        #expect(quote.section == "page 1" && quote.text == "Notes page 1")

        viewer.show(fixture.studyPage, deckFile: "deck.pdf", slide: 5, follow: true)
        #expect(viewer.status == "Notes page 5 shows slide 5")
        #expect(viewer.selectionQuote() == nil)
        #expect(viewer.pageImage()?.page == 5)

        // Back on page 1, the selection (still there) is quoted again.
        viewer.show(fixture.studyPage, deckFile: "deck.pdf", slide: 1, follow: true)
        #expect(viewer.selectionQuote()?.section == "page 1")
    }

    /// In crop mode (or with ⌥ held) the area layer over the notes has the mouse; the wheel still scrolls them. A mouse
    /// wheel, because a pixel (trackpad-style) wheel event without phases later stops the test runner's run loop: the
    /// run then ends early, with exit status 0 and no summary.
    @Test func notesScrollUnderTheAreaLayer() throws {
        let fixture = try NotesFixture()
        defer { fixture.remove() }
        try fixture.write((1...8).map { (deck: "deck.pdf", slide: $0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // As in the Walkthrough tab: the notes in a box, the area layer on top.
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        window.contentView = box
        let viewer = StudyPDFController()
        viewer.view.frame = box.bounds
        box.addSubview(viewer.view)
        let layer = AreaSelectView(hint: "")
        layer.frame = box.bounds
        layer.scrollTarget = viewer.view
        layer.isActive = { true }
        box.addSubview(layer)
        viewer.show(fixture.studyPage, deckFile: "deck.pdf", slide: 1, follow: false)
        box.layoutSubtreeIfNeeded()

        let pointer = NSPoint(x: 250, y: 350)
        #expect(box.hitTest(pointer) === layer)
        let clip = try #require(viewer.view.documentView?.enclosingScrollView?.contentView)
        let top = clip.bounds.origin.y
        layer.scrollWheel(with: try wheel(-10, at: pointer))
        #expect(abs(clip.bounds.origin.y - top) > 50, "the notes scrolled")
    }

    /// A mouse wheel turned `lines` with the pointer at `p` (screen points; the window sits at the origin).
    private func wheel(_ lines: Int32, at p: NSPoint) throws -> NSEvent {
        let e = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        e.location = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)   // global: from the top left
        return try #require(NSEvent(cgEvent: e))
    }
}

/// Minimal real PDFs with the same XObject stamps that pdfTeX places on included lecture slides, and a line of text
/// ("Notes page N") on each page.
private struct NotesFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("notes.pdf") }
    var studyPage: StudyPage { StudyPage(title: "Notes", path: url.path) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoLearner-Notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func write(_ slides: [(deck: String, slide: Int)]) throws {
        let kids = slides.indices.map { "\(3 + $0 * 3) 0 R" }.joined(separator: " ")
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\(kids)] /Count \(slides.count) >>"]
        let font = 3 + slides.count * 3
        for (index, slide) in slides.enumerated() {
            let page = 3 + index * 3
            let content = "BT /F1 24 Tf 72 700 Td (Notes page \(index + 1)) Tj ET\n/Slide Do"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(font) 0 R >> /XObject << /Slide \(page + 1) 0 R >> >> /Contents \(page + 2) 0 R >>")
            objects.append("<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /PTEX.FileName (\(slide.deck)) /PTEX.PageNumber \(slide.slide) /Length 0 >>\nstream\n\nendstream")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        // Like a TeX compiler's completed output, replace the file at the same path.
        try pdf.write(to: url, options: .atomic)
    }
}
