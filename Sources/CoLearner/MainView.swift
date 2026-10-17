import SwiftUI
import WebKit

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                DeckBar()
                Divider()
                if model.document != nil {
                    SlideView()
                    Divider()
                    ThumbnailStrip()
                } else {
                    WelcomeView()
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            RightPanel()
                .frame(minWidth: 340, idealWidth: 440, maxWidth: 1000, maxHeight: .infinity)
        }
        .navigationTitle(model.deck.map { "\($0.title) — slide \(model.page)/\(model.pageCount)" } ?? "Co-learner")
    }
}

// MARK: - top strip: lecture picker + open tabs

struct DeckBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.courses) { c in
                    Menu(c.name) {
                        ForEach(c.decks) { d in
                            Button {
                                model.open(d)
                            } label: {
                                Text(d.title + (d.walkthroughs.isEmpty ? "" : "  ·  walkthrough"))
                            }
                        }
                    }
                }
                Divider()
                Button("Open a PDF…") { model.openPDFPanel() }
                Button("Reload library") { model.reloadLibrary() }
            } label: {
                Label("Lectures", systemImage: "books.vertical")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick a lecture deck")

            Divider().frame(height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.openDecks) { d in
                        DeckTab(deck: d, selected: d.path == model.deck?.path)
                    }
                }
            }

            if model.document != nil {
                HStack(spacing: 2) {
                    Button { model.go(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.page <= 1)
                        .help("Previous slide (⌘[)")
                    Text("\(model.page) / \(model.pageCount)")
                        .monospacedDigit()
                        .font(.callout)
                        .frame(minWidth: 54)
                    Button { model.go(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.page >= model.pageCount)
                        .help("Next slide (⌘])")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DeckTab: View {
    @EnvironmentObject var model: AppModel
    let deck: Deck
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(courseTag + " " + deck.title)
                .lineLimit(1)
                .font(.callout.weight(selected ? .semibold : .regular))
            Button { model.close(deck) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(selected ? 1 : 0.45)
            .help("Close")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.16) : Color.gray.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture { model.open(deck) }
        .help(deck.path)
    }

    private var courseTag: String {
        switch deck.courseID {
        case "w4733": return "Robotics ·"
        case "w4731": return "CV ·"
        case "w4701": return "AI ·"
        case "e4720": return "ML ·"
        default: return ""
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Co-learner").font(.largeTitle.bold())
                Text("Pick a lecture. Ask about the slide you're on; the slide goes with your question.")
                    .foregroundStyle(.secondary)
                if model.folderAccessDenied {
                    Text("Co-learner can't read your course folders on the Desktop. Allow it in System Settings › Privacy & Security › Files & Folders (Co-learner › Desktop Folder), then choose Lectures › Reload library.")
                        .foregroundStyle(.red)
                }
                ForEach(model.courses) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.name).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(c.decks) { d in
                                Button {
                                    model.open(d)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(d.title).lineLimit(1)
                                        if !d.walkthroughs.isEmpty {
                                            Image(systemName: "book.pages").foregroundStyle(.secondary).help("Has a walkthrough")
                                        }
                                    }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
                Button("Open another PDF…") { model.openPDFPanel() }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - right panel

struct RightPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.rightTab) {
                    Text("Chat").tag(RightTab.chat)
                    Text(model.currentStudyPages.isEmpty ? "Walkthrough" : "Walkthrough (\(model.currentStudyPages.count))")
                        .tag(RightTab.walkthrough)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if model.rightTab == .chat {
                WebViewHost(view: model.chat.webView)
            } else {
                WalkthroughPane()
            }
        }
    }
}

/// Shows a WKWebView that lives elsewhere (so switching tabs never reloads it).
struct WebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - pop-out window for visuals

@MainActor
enum VisualWindow {
    private static var windows: [NSWindow] = []

    static func show(html: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Visual"
        w.isReleasedWhenClosed = false
        let wv = WKWebView(frame: .zero)
        wv.loadHTMLString(html, baseURL: nil)
        w.contentView = wv
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        windows.removeAll { !$0.isVisible && $0 !== w }
    }
}
