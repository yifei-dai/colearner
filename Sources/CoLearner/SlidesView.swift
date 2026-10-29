import SwiftUI
import PDFKit

/// The big slide in the middle of the left pane, with an overlay for cutting out an area of it.
struct SlideView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> NSView {
        let v = PDFView()
        v.displayMode = .singlePage
        v.displayDirection = .horizontal
        v.autoScales = true
        v.displaysPageBreaks = false
        v.backgroundColor = NSColor.underPageBackgroundColor
        v.document = model.document
        context.coordinator.view = v
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: v)
        if let p = model.document?.page(at: model.page - 1) { v.go(to: p) }

        let container = NSView()
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        let overlay = AreaSelectView(hint: "Drag over the part of the slide you want · Esc to cancel")
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.isActive = { [weak model] in model?.selectingArea ?? false }
        overlay.onSelect = { [weak model, weak overlay, weak v] r in
            guard let v, let area = overlay?.pdfArea(r, in: v) else { return }
            model?.finishAreaSelection(page: area.page, rect: area.rect)
        }
        container.addSubview(overlay)
        context.coordinator.overlay = overlay
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let v = context.coordinator.view else { return }
        let want = model.page   // read first: swapping documents makes PDFView report its old page index
        if v.document !== model.document {
            context.coordinator.swapping = true
            v.document = model.document
            v.autoScales = true
            context.coordinator.swapping = false
        }
        context.coordinator.overlay?.refresh(selecting: model.selectingArea)
        guard let doc = v.document, let target = doc.page(at: want - 1) else { return }
        if v.currentPage !== target { v.go(to: target) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        let model: AppModel
        weak var view: PDFView?
        weak var overlay: AreaSelectView?
        var swapping = false
        init(model: AppModel) { self.model = model }

        @MainActor @objc func pageChanged(_ n: Notification) {
            guard !swapping, let v = view, let doc = v.document, let p = v.currentPage, doc === model.document else { return }
            let i = doc.index(for: p)
            guard i != NSNotFound else { return }
            let idx = i + 1
            if idx != model.page { model.page = idx }
        }
    }
}

/// Transparent layer over the slide (and over the walkthrough page or notes). It takes the mouse only while an area
/// is being selected (after "Select area" / ⌘⇧A) or while ⌥ is held, so normal clicks, scrolling and arrow keys go
/// to the view below.
final class AreaSelectView: NSView {
    var isActive: () -> Bool = { false }
    /// The box that was dragged out, in this view's coordinates.
    var onSelect: (NSRect) -> Void = { _ in }
    /// Shown while waiting for the drag.
    let hint: String
    /// Its view under the pointer gets the scroll wheel while this layer has the mouse (a long walkthrough page or the
    /// notes still scroll); nil: as before.
    weak var scrollTarget: NSView?
    private var start: NSPoint?
    private var current: NSPoint?
    /// The drag began in selection mode (so Esc, which ends the mode, cancels it).
    private var startedInMode = false

    init(hint: String) {
        self.hint = hint
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A box from `onSelect` on the PDF page under its middle, in page coordinates.
    func pdfArea(_ r: NSRect, in pdf: PDFView) -> (page: PDFPage, rect: CGRect)? {
        let inPDF = convert(r, to: pdf)
        guard let page = pdf.page(for: NSPoint(x: inPDF.midX, y: inPDF.midY), nearest: true) else { return nil }
        return (page, pdf.convert(inPDF, to: page).standardized)
    }

    override func scrollWheel(with e: NSEvent) {
        guard let t = scrollTarget else { super.scrollWheel(with: e); return }
        // To the view AppKit would pick without this layer: a PDFView hands a wheel sent to itself up the responder
        // chain instead of to its own scroll view, so the notes would not move.
        let hit = t.superview.flatMap { t.hitTest($0.convert(e.locationInWindow, from: nil)) }
        (hit ?? t).scrollWheel(with: e)
    }

    override var isFlipped: Bool { true }

    private var selecting: Bool { isActive() || start != nil }

    /// A drag in selection mode works even if the window wasn't key yet (selection started from a pop-out).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isActive() || NSEvent.modifierFlags.contains(.option) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // ⌥-drag works any time; otherwise only in selection mode.
        guard isActive() || NSEvent.modifierFlags.contains(.option) else { return nil }
        return super.hitTest(point)
    }

    func refresh(selecting: Bool) {
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func resetCursorRects() {
        if isActive() { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with e: NSEvent) {
        start = convert(e.locationInWindow, from: nil)
        current = start
        startedInMode = isActive()
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { start = nil; current = nil; needsDisplay = true }
        guard let s = start, !(startedInMode && !isActive()) else { return }
        let r = band(s, convert(e.locationInWindow, from: nil))
        guard r.width > 6, r.height > 6 else { return }
        onSelect(r)
    }

    private func band(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selecting, !(startedInMode && !isActive()) else { return }
        if let s = start, let c = current {
            let r = band(s, c)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            r.fill()
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        } else if isActive() {
            // A hint while waiting for the drag.
            let text = hint as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            let box = NSRect(x: (bounds.width - size.width) / 2 - 10, y: 10, width: size.width + 20, height: size.height + 8)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            text.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 4), withAttributes: attrs)
        }
    }
}

/// Horizontal strip of slide thumbnails under the slide.
struct ThumbnailStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(1...max(model.pageCount, 1), id: \.self) { p in
                        if model.pageCount > 0 {
                            ThumbCell(thumbs: model.thumbs, page: p, selected: p == model.page, hasChat: model.chatPages.contains(p))
                                .id(p)
                                .onTapGesture { model.page = p }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: model.page) { _, p in
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(p, anchor: .center) }
            }
            .onChange(of: model.deckID) { _, _ in
                proxy.scrollTo(model.page, anchor: .center)
            }
            .onAppear { proxy.scrollTo(model.page, anchor: .center) }
        }
        .frame(height: 96)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ThumbCell: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var thumbs: ThumbStore
    let page: Int
    let selected: Bool
    let hasChat: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = model.thumbnail(page) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.15))
                    }
                }
                .frame(width: 104, height: 66)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(selected ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: selected ? 2.5 : 1))
                if hasChat {
                    Circle().fill(Color.orange).frame(width: 8, height: 8).offset(x: -3, y: 3)
                        .help("This slide has a chat")
                }
            }
            Text("\(page)").font(.system(size: 10)).foregroundStyle(selected ? Color.accentColor : .secondary)
        }
    }
}

/// Slide thumbnails, rendered on the main thread in short slices so a big deck never freezes the window.
/// The cells requested last (around the slide being scrolled to) are drawn first.
@MainActor
final class ThumbStore: ObservableObject {
    @Published private(set) var version = 0
    private let cache = NSCache<NSString, NSImage>()
    private var queued = Set<String>()
    private var work: [(String, PDFPage)] = []
    private var scheduled = false

    func image(key: String, page: PDFPage?) -> NSImage? {
        if let img = cache.object(forKey: key as NSString) { return img }
        guard let page, !queued.contains(key) else { return nil }
        queued.insert(key)
        work.append((key, page))
        schedule()
        return nil
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        scheduled = false
        let start = Date()
        while let (key, page) = work.popLast() {
            cache.setObject(page.thumbnail(of: NSSize(width: 208, height: 132), for: .cropBox), forKey: key as NSString)
            queued.remove(key)
            if Date().timeIntervalSince(start) > 0.03 { break }
        }
        version += 1
        if !work.isEmpty { schedule() }
    }
}
