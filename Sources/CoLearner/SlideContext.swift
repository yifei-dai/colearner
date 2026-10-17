import AppKit
import PDFKit
import CryptoKit

/// What gets attached to the first question on a slide: a PNG of the slide plus its text.
struct SlideContext {
    var deck: Deck
    var page: Int          // 1-based PDF page number
    var pageCount: Int
    var text: String
    var prevText: String?
    var nextText: String?
    var pngURL: URL

    @MainActor
    static func make(deck: Deck, document: PDFDocument, page: Int) -> SlideContext? {
        guard let pdfPage = document.page(at: page - 1) else { return nil }
        let png = renderPNG(pdfPage, deckPath: deck.path, page: page)
        func text(_ p: Int) -> String? {
            guard p >= 1, p <= document.pageCount, let s = document.page(at: p - 1)?.string else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard let png else { return nil }
        return SlideContext(deck: deck, page: page, pageCount: document.pageCount,
                            text: text(page) ?? "(no extractable text on this slide; rely on the image)",
                            prevText: text(page - 1), nextText: text(page + 1), pngURL: png)
    }

    /// Renders the page so its long edge is 1568 px (the largest size Claude uses without downscaling).
    static func renderPNG(_ page: PDFPage, deckPath: String, page number: Int) -> URL? {
        let h = SHA256.hash(data: Data(deckPath.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        let dir = AppPaths.cache.appendingPathComponent("slides", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(h)-p\(number).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        var box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        if page.rotation % 180 != 0 { box.size = CGSize(width: box.height, height: box.width) }
        let scale = 1568 / max(box.width, box.height)
        let w = Int((box.width * scale).rounded()), hgt = Int((box.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: hgt, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: hgt))
        cg.scaleBy(x: scale, y: scale)
        page.transform(cg, for: .cropBox)   // moves the crop box to the origin and applies the page rotation
        page.draw(with: .cropBox, to: cg)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + " …"
    }

    /// The text block that opens a slide conversation. Only Claude can read files, so only it gets the list.
    func promptHeader(includeFiles: Bool) -> String {
        var s = "<slide_context>\n"
        s += "Course: \(deck.courseName)\n"
        s += "Lecture deck: \(deck.title) (PDF: \(deck.path))\n"
        s += "Current slide: \(page) of \(pageCount) (PDF page number). The slide image is attached.\n"
        s += "Text extracted from slide \(page):\n\"\"\"\n\(Self.clip(text, 4000))\n\"\"\"\n"
        if let prevText { s += "Text of slide \(page - 1) (previous):\n\"\"\"\n\(Self.clip(prevText, 1500))\n\"\"\"\n" }
        if let nextText { s += "Text of slide \(page + 1) (next):\n\"\"\"\n\(Self.clip(nextText, 1500))\n\"\"\"\n" }
        let files = deck.walkthroughs.map { "- Study page (\($0.title)): \($0.path)" } + deck.contextFiles.map { "- Lecture notes: \($0)" }
        if includeFiles, !files.isEmpty {
            s += "Related files you may read only if the question needs more than the slide:\n" + files.joined(separator: "\n") + "\n"
        }
        s += "</slide_context>\n\n"
        return s
    }
}
