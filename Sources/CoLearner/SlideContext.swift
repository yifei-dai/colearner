import AppKit
import PDFKit
import CryptoKit

/// Slide images for the assistants: one PNG per slide in a per-deck cache folder (Claude may open any of
/// them itself), plus cropped areas the user selects on a slide.
enum SlideImages {
    /// Long edge in pixels: the largest size Claude uses without downscaling.
    static let longEdge: CGFloat = 1568

    /// cache/slides/<deck+version>/ — changes when the PDF is replaced or the 2-up frames change.
    static func cacheKey(for deck: Deck) -> String {
        let stamp = "\(deck.path)|\(String(describing: FileRevision.read(deck.path)))|\(deck.layout.frames ?? [])|v4"
        return String(SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func folder(for deck: Deck) -> URL {
        let dir = AppPaths.cache.appendingPathComponent("slides/\(cacheKey(for: deck))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for deck: Deck, page: Int) -> URL {
        folder(for: deck).appendingPathComponent("slide-\(page).png")
    }

    /// The PNG of one slide, rendered on first use.
    static func png(deck: Deck, document: PDFDocument, page: Int) -> URL? {
        let url = url(for: deck, page: page)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let p = document.page(at: page - 1) else { return nil }
        return write(render(p, rect: p.bounds(for: .cropBox), longEdge: longEdge), to: url) ? url : nil
    }

    /// Renders every slide in the background so Claude can open any of them (skips ones already there).
    static func prerenderAll(deck: Deck) {
        let dir = folder(for: deck)
        DispatchQueue.global(qos: .utility).async {
            guard let made = AppModel.makeDocument(for: deck) else { return }
            let doc = made.document
            for i in 0..<doc.pageCount {
                let url = dir.appendingPathComponent("slide-\(i + 1).png")
                if FileManager.default.fileExists(atPath: url.path) { continue }
                guard let p = doc.page(at: i) else { continue }
                _ = write(render(p, rect: p.bounds(for: .cropBox), longEdge: longEdge), to: url)
            }
        }
    }

    /// A selected area of a slide: a sharp PNG for the model and a small JPEG data URL for the chat.
    static func area(page: PDFPage, rect: CGRect) -> (url: URL, thumb: String)? {
        let crop = page.bounds(for: .cropBox)
        let r = rect.intersection(crop)
        guard r.width >= 4, r.height >= 4 else { return nil }
        // Sharp enough to read small text: about 4x screen size, at most the model's long edge.
        let edge = min(longEdge, max(r.width, r.height) * 4)
        guard let rep = render(page, rect: r, longEdge: edge) else { return nil }
        let dir = AppPaths.cache.appendingPathComponent("areas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        guard write(rep, to: url), let thumbRep = render(page, rect: r, longEdge: 320),
              let jpg = thumbRep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return (url, "data:image/jpeg;base64," + jpg.base64EncodedString())
    }

    /// Draws `rect` (page coordinates) of a page into a white bitmap whose long edge is `longEdge` pixels.
    static func render(_ page: PDFPage, rect r: CGRect, longEdge: CGFloat) -> NSBitmapImageRep? {
        guard r.width > 0, r.height > 0 else { return nil }
        // draw(with: .cropBox) maps page space through this transform (crop box to the origin, then rotation),
        // so work out where the area lands after it.
        let t = page.transform(for: .cropBox)
        let d = r.applying(t).standardized
        let scale = longEdge / max(d.width, d.height)
        let w = max(1, Int((d.width * scale).rounded())), h = max(1, Int((d.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -d.minX, y: -d.minY)
        page.draw(with: .cropBox, to: cg)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep?, to url: URL) -> Bool {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// What a new conversation is told about the deck.
enum DeckContext {
    /// Deck facts, every slide's text (text is cheap; images come one by one), and the files Claude may read.
    static func header(deck: Deck, texts: [String], includeFiles: Bool) -> String {
        let numbering = deck.layout.isTwoUp ? "slide numbers as printed on the slides" : "slide number = PDF page number"
        var s = "<lecture_deck>\n"
        s += "Course: \(deck.courseName)\n"
        s += "Deck: \(deck.title) — \(texts.count) slides (\(numbering)). PDF: \(deck.path)\n"
        s += "Text of every slide (extracted; formulas and figures may be garbled — the slide images are authoritative):\n"
        var budget = 60_000
        for (i, t) in texts.enumerated() {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            let clip = clean.count > 1_200 ? String(clean.prefix(1_200)) + " …" : clean
            let block = "--- Slide \(i + 1) ---\n\(clip.isEmpty ? "(no text; see the image)" : clip)\n"
            if budget - block.count < 0 { s += "--- Slides \(i + 1)–\(texts.count): text omitted (too long) ---\n"; break }
            budget -= block.count
            s += block
        }
        if includeFiles {
            s += "Slide images: \(SlideImages.folder(for: deck).path)/slide-N.png (open one with Read when you need a slide you haven't been shown).\n"
            s += "This is the current source list: read only these slide images and the related files listed below. "
                + "Earlier chat may mention removed files or older slides; those references do not grant permission to read removed files.\n"
            let files = deck.walkthroughs.filter { !$0.isPDF }.map { "- Study page (\($0.title)): \($0.path)" }
                + deck.contextFiles.map { f -> String in
                    if f.contains("/subtitles/") { return "- Transcript of the instructor's recorded lecture on this topic: \(f)" }
                    if f.hasSuffix(".tex") { return "- Typed lecture notes (LaTeX, includes remarks made in class): \(f)" }
                    return "- Lecture notes: \(f)"
                }
            if !files.isEmpty {
                s += "Related files you may read only if a question needs more than the slides (read only these):\n"
                    + files.joined(separator: "\n") + "\n"
                    + "Never open handwritten scans (*_inclass_notes.pdf, *_scribing_*.pdf).\n"
            } else {
                s += "No related files are currently linked.\n"
            }
        }
        s += "Use this current deck and its images as authoritative if earlier answers describe an older version.\n"
        return s + "</lecture_deck>\n\n"
    }

    /// The line before the question: the slide the student is on, the images attached (in order), and what "this" is.
    /// `images` are the prompt names of attached pictures ("an image the student pasted").
    static func questionNote(page: Int, count: Int, slides: [Int], area: Bool, images: [String], quote: Bool) -> String {
        var note = "[The student is on slide \(page) of \(count).]"
        var parts = slides.map { "slide \($0)" }
        if area { parts.append("the area of slide \(page) the student selected") }
        parts += images
        if !parts.isEmpty { note += " Attached images, in order: " + parts.joined(separator: ", ") + "." }
        // Everything the student attached, as the chat box shows it (none of them outranks the others).
        var about: [String] = []
        if area { about.append("the selected area") }
        if quote { about.append("the quoted passage") }
        if !images.isEmpty { about.append(images.count == 1 ? "the attached image" : "the attached images") }
        if let last = about.popLast() {
            note += " The question is about " + (about.isEmpty ? last : about.joined(separator: ", ") + " and " + last) + "."
        }
        return note
    }

    /// A passage the student quoted from the deck's walkthrough page or notes, or from an earlier answer, put before the
    /// question. `p` is the assistant being asked (an answer of its own is "your earlier answer").
    static func excerpt(_ q: ChatQuote, for p: Provider? = nil) -> String {
        let page = "the walkthrough page for this deck (a study page written from these slides)"
        let tag: String, intro: String
        switch q.kind {
        case "notes":
            (tag, intro) = ("notes_excerpt", "The student selected this passage in the typed notes for this deck "
                + "(text taken from the PDF, so formulas may be garbled):")
        case "section": (tag, intro) = ("walkthrough_excerpt", "The student is reading this section of \(page):")
        case "reply":
            let whose = p != nil && q.provider == p ? "your" : (q.provider?.displayName ?? "an assistant") + "’s"
            (tag, intro) = ("answer_excerpt", "The student selected this part of \(whose) earlier answer in this chat:")
        default: (tag, intro) = ("walkthrough_excerpt", "The student selected this passage on \(page):")
        }
        func attribute(_ s: String) -> String {
            s.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
        }
        var open = "<\(tag) from=\"\(attribute(q.source))\""
        if let s = q.section, !s.isEmpty { open += " where=\"\(attribute(s))\"" }
        let text = q.text.replacingOccurrences(of: "</\(tag)>", with: "</ \(tag)>")
        return "\(intro)\n\(open)>\n\(text)\n</\(tag)>\n"
    }

    /// Slide numbers mentioned in a question: "slide 5", "slides 5-8", "p. 3", "pages 3 and 7", "slides 2, 4, and 9",
    /// "slide #4", "pg 12", "slides 3 through 6".
    static func referencedSlides(in text: String, pageCount: Int) -> [Int] {
        guard let re = try? NSRegularExpression(
            pattern: #"\b(?:slides?|pages?|pgs?\.?|pp?\.)\s*(#?\d+(?:\s*(?:-|–|—|to|through|thru)\s*#?\d+)?(?:\s*(?:,\s*and|,|and|&)\s*#?\d+(?:\s*(?:-|–|—|to|through|thru)\s*#?\d+)?)*)"#,
            options: .caseInsensitive) else { return [] }
        var out: [Int] = []
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let list = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: #"\s*(?:,\s*and|,|and|&)\s*"#, with: ",", options: [.regularExpression, .caseInsensitive])
            for part in list.components(separatedBy: ",") {
                let nums = part.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
                if nums.count == 2, nums[0] <= nums[1], nums[1] - nums[0] <= 8 { out += Array(nums[0]...nums[1]) }
                else if let n = nums.first { out.append(n) }
            }
        }
        var seen = Set<Int>()
        return out.filter { $0 >= 1 && $0 <= pageCount && seen.insert($0).inserted }
    }
}
