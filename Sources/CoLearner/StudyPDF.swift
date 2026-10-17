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
    private var path: String?
    private var map: [Int: Int] = [:]

    func show(_ page: StudyPage, deckFile: String, slide: Int, follow: Bool) {
        if page.path != path {
            path = page.path
            view.document = PDFDocument(url: URL(fileURLWithPath: page.path))
            map = ScribeMap.pages(notes: page.path, deckFile: deckFile)
        } else if map.isEmpty {
            map = ScribeMap.pages(notes: page.path, deckFile: deckFile)
        }
        guard follow else { return }
        guard let doc = view.document, let hit = ScribeMap.page(for: slide, in: map), let target = doc.page(at: hit.page - 1) else {
            status = map.isEmpty ? "These notes don't show slides from this deck" : nil
            return
        }
        status = hit.exact ? "Notes page \(hit.page) shows slide \(slide)" : "Notes page \(hit.page) (nearest slide shown before \(slide))"
        if view.currentPage !== target { view.go(to: target) }
    }

    /// Keep the mapping fresh when another deck uses the same notes file.
    func reset() { path = nil; map = [:]; status = nil }
}
