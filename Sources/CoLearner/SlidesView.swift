import SwiftUI
import PDFKit

/// The big slide in the middle of the left pane.
struct SlideView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> PDFView {
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
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        let want = model.page   // read first: swapping documents makes PDFView report its old page index
        if v.document !== model.document {
            context.coordinator.swapping = true
            v.document = model.document
            v.autoScales = true
            context.coordinator.swapping = false
        }
        guard let doc = v.document, let target = doc.page(at: want - 1) else { return }
        if v.currentPage !== target { v.go(to: target) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        let model: AppModel
        weak var view: PDFView?
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
