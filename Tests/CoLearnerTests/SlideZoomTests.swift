import AppKit
import Foundation
import PDFKit
import Testing
@testable import CoLearner

/// An enlarged slide stays enlarged on the next slide (a real PDFView in a window; the pinch is the magnification of
/// its inner scroll view, which is all a pinch changes).
@MainActor
struct SlideZoomTests {
    @Test func pinchedSlideStaysEnlargedOnTheSamePartOfTheNextSlide() throws {
        let slide = try SlideFixture()
        defer { slide.close() }
        let v = slide.view, fit = v.scaleFactorForSizeToFit
        try slide.pinch(2)
        try slide.scroll(dx: 60, dy: 40)
        #expect(v.autoScales)   // what a pinch leaves behind: without the fix the next page fits again
        let before = v.convert(v.bounds, to: try #require(v.currentPage))

        v.go(to: try #require(slide.document.page(at: 1)), keepingZoom: true)
        slide.settle()
        #expect(v.currentPage === slide.document.page(at: 1))
        #expect(abs(v.scaleFactor / fit - 2) < 0.01)
        let after = v.convert(v.bounds, to: try #require(v.currentPage))
        #expect(abs(after.minX - before.minX) < 2 && abs(after.maxY - before.maxY) < 2)
        #expect(abs(after.width - before.width) < 2)

        // And on the slides after it, back included.
        v.go(to: try #require(slide.document.page(at: 3)), keepingZoom: true)
        v.go(to: try #require(slide.document.page(at: 0)), keepingZoom: true)
        slide.settle()
        #expect(abs(v.scaleFactor / fit - 2) < 0.01)
        let back = v.convert(v.bounds, to: try #require(v.currentPage))
        #expect(abs(back.minX - before.minX) < 2 && abs(back.maxY - before.maxY) < 2)
    }

    @Test func slideThatFitsKeepsFittingTheWindow() throws {
        let slide = try SlideFixture()
        defer { slide.close() }
        let v = slide.view
        v.go(to: try #require(slide.document.page(at: 1)), keepingZoom: true)
        slide.settle()
        #expect(v.autoScales)
        #expect(abs(v.scaleFactor / v.scaleFactorForSizeToFit - 1) < 0.001)
        slide.resize(1000, 700)
        #expect(abs(v.scaleFactor / v.scaleFactorForSizeToFit - 1) < 0.001)
    }

    @Test func pinchingBackToFitOrSmallerFitsAgain() throws {
        let slide = try SlideFixture()
        defer { slide.close() }
        let v = slide.view
        try slide.pinch(2)
        #expect(v.holdZoom(smallerIsFit: true))
        #expect(!v.autoScales)
        slide.resize(1000, 700)   // a held zoom does not follow the window
        #expect(v.scaleFactor / v.scaleFactorForSizeToFit > 1.5)

        try slide.pinch(to: v.scaleFactorForSizeToFit * 1.01)   // about back at fitting
        #expect(!v.holdZoom(smallerIsFit: true))
        #expect(v.autoScales)
        slide.resize(800, 600)
        #expect(abs(v.scaleFactor / v.scaleFactorForSizeToFit - 1) < 0.001)

        try slide.pinch(0.5)   // a slide pinched smaller than fitting goes back to fitting
        #expect(!v.holdZoom(smallerIsFit: true))
        slide.settle()
        #expect(v.autoScales)
        #expect(abs(v.scaleFactor / v.scaleFactorForSizeToFit - 1) < 0.001)

        try slide.pinch(0.5)   // notes may stay small
        #expect(v.holdZoom())
        #expect(abs(v.scaleFactor / v.scaleFactorForSizeToFit - 0.5) < 0.01)
    }
}

/// A four-slide deck in a slide view like the app's, in a window.
@MainActor
private struct SlideFixture {
    let window: NSWindow
    let view = PDFView()
    let document: PDFDocument

    init() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for i in 0..<4 {
            ctx.beginPDFPage(nil)
            ctx.fill(CGRect(x: 100 + 50 * i, y: 100, width: 300, height: 200))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        document = try #require(PDFDocument(data: data as Data))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.autoresizingMask = [.width, .height]
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.autoScales = true
        view.displaysPageBreaks = false
        window.contentView?.addSubview(view)
        view.document = document
        settle()
    }

    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    func close() { window.close() }

    func resize(_ w: CGFloat, _ h: CGFloat) {
        window.setContentSize(NSSize(width: w, height: h))
        settle()
    }

    private var scrollView: NSScrollView {
        get throws { try #require(view.documentView?.enclosingScrollView) }
    }

    /// What a pinch does: the inner scroll view's magnification changes, nothing else.
    func pinch(_ factor: CGFloat) throws { try pinch(to: view.scaleFactor * factor) }
    func pinch(to scale: CGFloat) throws {
        try scrollView.magnification = scale
        settle()
    }

    func scroll(dx: CGFloat, dy: CGFloat) throws {
        let s = try scrollView
        var o = s.contentView.bounds.origin
        o.x += dx
        o.y += dy
        s.contentView.scroll(to: o)
        s.reflectScrolledClipView(s.contentView)
        settle()
    }
}
