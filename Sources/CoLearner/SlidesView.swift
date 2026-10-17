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
        if v.document !== model.document {
            v.document = model.document
            v.autoScales = true
        }
        guard let doc = v.document, let target = doc.page(at: model.page - 1) else { return }
        if v.currentPage !== target { v.go(to: target) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        let model: AppModel
        weak var view: PDFView?
        init(model: AppModel) { self.model = model }

        @MainActor @objc func pageChanged(_ n: Notification) {
            guard let v = view, let doc = v.document, let p = v.currentPage else { return }
            let idx = doc.index(for: p) + 1
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
                            ThumbCell(page: p, selected: p == model.page, hasChat: model.chatPages.contains(p))
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
