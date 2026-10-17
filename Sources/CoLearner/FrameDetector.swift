import PDFKit
import CoreGraphics

/// Finds the slide frames on 2-up handout pages (two slides stacked on one page), so a new deck with a
/// slightly different layout is still cut exactly at the slide borders.
enum FrameDetector {
    /// Frames in PDF points (origin bottom-left), top slide first. Each frame is the rectangle found most often
    /// across a sample of pages (it must be seen on at least two), so odd pages don't matter.
    static func frames(for doc: PDFDocument) -> [[Double]]? {
        var votes: [(rect: CGRect, count: Int)] = []
        for i in 0..<min(doc.pageCount, 12) {
            guard let pg = doc.page(at: i) else { continue }
            for r in slideRects(on: pg) {
                if let k = votes.firstIndex(where: { close($0.rect, r) }) { votes[k].count += 1 } else { votes.append((r, 1)) }
            }
        }
        // The two best-supported rectangles that don't overlap vertically.
        let ranked = votes.filter { $0.count >= 2 }.sorted { $0.count > $1.count }.map(\.rect)
        guard let first = ranked.first else { return nil }
        func separate(_ r: CGRect) -> Bool {
            let below = r.maxY <= first.minY + 2
            let above = r.minY >= first.maxY - 2
            return below || above
        }
        guard let second = ranked.dropFirst().first(where: separate) else { return nil }
        let pair = [first, second].sorted { $0.minY > $1.minY }   // top slide first
        return pair.map { r -> [Double] in [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        let pos = abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3
        let size = abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
        return pos && size
    }

    /// The framed slides on one page (0, 1 or 2). A slide shows up as a block of columns that all have one
    /// long vertical run of dark pixels with the same top and bottom: the whole slide when its background is
    /// dark, its left and right border lines when it is light.
    static func slideRects(on page: PDFPage) -> [CGRect] {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width), h = Int(box.height)
        guard w > 50, h > 50,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let data = ctx.data else { return [] }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)   // row 0 = top of the page
        let minRun = h / 5

        struct Group { var r0: Int; var r1: Int; var minX: Int; var maxX: Int; var cols: Int }
        var groups: [Group] = []
        for x in 0..<w {
            var r = 0
            while r < h {
                guard px[r * w + x] < 170 else { r += 1; continue }
                var e = r
                while e + 1 < h, px[(e + 1) * w + x] < 170 { e += 1 }
                if e - r + 1 >= minRun {
                    if let i = groups.firstIndex(where: { abs($0.r0 - r) <= 3 && abs($0.r1 - e) <= 3 }) {
                        groups[i].minX = min(groups[i].minX, x); groups[i].maxX = max(groups[i].maxX, x); groups[i].cols += 1
                    } else {
                        groups.append(Group(r0: r, r1: e, minX: x, maxX: x, cols: 1))
                    }
                }
                r = e + 1
            }
        }
        var slides = groups.filter { g in
            let gw = Double(g.maxX - g.minX + 1), gh = Double(g.r1 - g.r0 + 1)
            return gw >= 0.3 * Double(w) && gw / gh > 1.15 && gw / gh < 1.95
        }
        // A dark block inside a slide (a region that ends partway down) also qualifies; keep only the outermost.
        slides = slides.filter { g in
            !slides.contains { o in
                (o.r0 != g.r0 || o.r1 != g.r1) && o.r0 <= g.r0 + 3 && o.r1 >= g.r1 - 3 && (o.r1 - o.r0) > (g.r1 - g.r0)
                    && o.minX <= g.maxX && g.minX <= o.maxX
            }
        }
        return slides.sorted { $0.r0 < $1.r0 }.map { g in
            CGRect(x: box.minX + CGFloat(g.minX) - 1, y: box.minY + CGFloat(h - 1 - g.r1) - 1,
                   width: CGFloat(g.maxX - g.minX + 1) + 2, height: CGFloat(g.r1 - g.r0 + 1) + 2)
        }
    }
}
