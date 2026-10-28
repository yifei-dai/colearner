import SwiftUI
import PDFKit

/// A notes PDF (e.g. typed scribe notes) in the Walkthrough tab, kept on the page that shows the current slide.
@MainActor
final class StudyPDFController: ObservableObject {
    let view: PDFView = {
        let v = PDFView()
        v.displayMode = .singlePageContinuous
        v.autoScales = true
        v.displaysPageBreaks = true
        v.backgroundColor = NSColor.underPageBackgroundColor
        return v
    }()
    @Published private(set) var status: String?
    /// The notes on screen: their file and the study page's title.
    private(set) var path: String?
    private(set) var title: String?
    private var revision: FileRevision?
    private var mapDeck: String?
    private var map: [Int: Int] = [:]

    func show(_ page: StudyPage, deckFile: String, slide: Int, follow: Bool) {
        let currentRevision = FileRevision.read(page.path)
        let fileChanged = page.path != path || currentRevision != revision
        title = page.title
        if fileChanged || view.document == nil {
            path = page.path
            view.document = currentRevision == nil ? nil : PDFDocument(url: URL(fileURLWithPath: page.path))
            revision = view.document == nil ? nil : currentRevision
            status = nil
        }
        // One notes file covers two decks (03a and 03b): the map belongs to the (file, deck) pair.
        if fileChanged || deckFile != mapDeck || map.isEmpty {
            map = ScribeMap.pages(notes: page.path, deckFile: deckFile)
            mapDeck = deckFile
        }
        guard follow else { return }
        guard let doc = view.document, let hit = ScribeMap.page(for: slide, in: map), let target = doc.page(at: hit.page - 1) else {
            status = map.isEmpty ? "These notes don't show slides from this deck" : nil
            return
        }
        status = hit.exact ? "Notes page \(hit.page) shows slide \(slide)" : "Notes page \(hit.page) (nearest slide shown before \(slide))"
        if view.currentPage !== target { view.go(to: target) }
    }

    // MARK: asking about the notes

    /// The text selected in the notes, as a quote for the chat ("page N": where the selection starts).
    func selectionQuote() -> ChatQuote? {
        guard let title, let doc = view.document, let sel = view.currentSelection,
              let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let index = sel.pages.first.map { doc.index(for: $0) } ?? NSNotFound
        return ChatQuote(source: title, section: index == NSNotFound ? nil : "page \(index + 1)",
                         text: String(text.prefix(ChatQuote.maxText)), kind: "notes")
    }

    /// The notes page on screen as a picture (at the size Claude reads), with its page number.
    func pageImage() -> (image: CGImage, page: Int)? {
        guard let doc = view.document, let p = view.currentPage else { return nil }
        let index = doc.index(for: p)
        guard index != NSNotFound,
              let image = SlideImages.render(p, rect: p.bounds(for: .cropBox), longEdge: SlideImages.longEdge)?.cgImage else { return nil }
        return (image, index + 1)
    }

    /// Part of a notes page (`rect` in page coordinates) as a picture, sharp enough for small print, as for slides.
    func areaImage(page p: PDFPage, rect: CGRect) -> (image: CGImage, page: Int)? {
        guard let doc = view.document, p.document === doc else { return nil }
        let index = doc.index(for: p)
        let r = rect.intersection(p.bounds(for: .cropBox))
        guard index != NSNotFound, r.width >= 4, r.height >= 4,
              let image = SlideImages.render(p, rect: r, longEdge: min(SlideImages.longEdge, max(r.width, r.height) * 4))?.cgImage
        else { return nil }
        return (image, index + 1)
    }
}
