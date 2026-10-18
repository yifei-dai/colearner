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
}

/// Minimal real PDFs with the same XObject stamps that pdfTeX places on included lecture slides.
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
        for (index, slide) in slides.enumerated() {
            let page = 3 + index * 3
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Slide \(page + 1) 0 R >> >> /Contents \(page + 2) 0 R >>")
            objects.append("<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /PTEX.FileName (\(slide.deck)) /PTEX.PageNumber \(slide.slide) /Length 0 >>\nstream\n\nendstream")
            objects.append("<< /Length 9 >>\nstream\n/Slide Do\nendstream")
        }
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
