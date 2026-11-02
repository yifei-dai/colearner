import SwiftUI
import WebKit

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var split = SplitState()

    var body: some View {
        // Slides : right panel = 3 : 2 at every launch. With Chat and Walkthrough both popped out, the slides
        // fill the window.
        let showRight = model.poppedOut.count < RightTab.allCases.count
        SplitPanes(state: split, showRight: showRight) {
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
            .frame(maxHeight: .infinity)
        } right: {
            RightPanel()
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: showRight ? 860 : 480, minHeight: 560)
        .background(WindowReader { [weak model] w in model?.mainWindow = w })
        .onAppear { model.mainWindowAppeared() }
        .navigationTitle(model.deck.map { "\($0.title) — slide \(model.page)/\(model.pageCount)" } ?? "Co-learner")
    }
}

/// Hands the window this view lives in to `onWindow` (AppModel.mainWindow), whatever else is on screen.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onWindow) }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void
        init(_ f: @escaping (NSWindow?) -> Void) { onWindow = f; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

// MARK: - top strip: lecture picker + open tabs

struct DeckBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.library.sections) { s in
                    Menu(s.section.name) { SectionMenu(contents: s) }
                }
                Divider()
                Button("Open a PDF…") { model.openPDFPanel() }
                Button("Reload library") { model.reloadLibrary() }
            } label: {
                Label("Lectures", systemImage: "books.vertical")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .hoverHighlight()
            .help("Pick a lecture deck")

            Divider().frame(height: 18)

            // Like a browser: + sits right after the last tab, and stays in view once the tabs need to scroll.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    tabs
                    plusButton
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) { tabs }
                        }
                        .onAppear { scrollToCurrent(proxy) }
                        .onChange(of: model.deck?.path) { _, _ in scrollToCurrent(proxy) }
                        .onChange(of: model.newTab) { _, _ in scrollToCurrent(proxy) }
                    }
                    plusButton
                }
            }

            if model.document != nil {
                HStack(spacing: 2) {
                    Button { model.go(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(IconButtonStyle())
                        .disabled(model.page <= 1)
                        .help("Previous slide (⌘[)")
                    Text("\(model.page) / \(model.pageCount)")
                        .monospacedDigit()
                        .font(.callout)
                        .frame(minWidth: 54)
                    Button { model.go(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(IconButtonStyle())
                        .disabled(model.page >= model.pageCount)
                        .help("Next slide (⌘])")
                }
            }

            Menu {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppModel.appearances, id: \.id) { a in Label(a.label, systemImage: a.icon).tag(a.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: AppModel.appearances.first { $0.id == model.appearance }?.icon ?? "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .hoverHighlight()
            .help("Appearance: Automatic, Light or Dark")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var tabs: some View {
        ForEach(model.openDecks) { d in
            DeckTab(deck: d, selected: d.path == model.deck?.path).id(d.path)
        }
        if model.newTab { NewTabChip(selected: model.deck == nil).id("newTab") }
    }

    private var plusButton: some View {
        Button { model.openNewTab() } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(IconButtonStyle())
        .fixedSize()
        .help("New tab (⌘T)")
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        let target = model.deck?.path ?? (model.newTab ? "newTab" : nil)
        guard let target else { return }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) } }
    }
}

private struct DeckTab: View {
    @EnvironmentObject var model: AppModel
    let deck: Deck
    let selected: Bool
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 4) {
            Text(courseTag + " " + deck.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.callout.weight(selected ? .semibold : .regular))
                .frame(maxWidth: 200, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.close(deck) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 16, cornerRadius: 8))
            .opacity(selected || hover.on ? 1 : 0.45)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .fixedSize(horizontal: true, vertical: false)   // as wide as the title (up to 200 pt), never stretched
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.16) : Color.gray.opacity(hover.on ? 0.16 : 0.07)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { model.switchTo(deck) }
        .help(deck.title + "\n" + deck.path)
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

/// The "New Tab" tab: shows the lecture list until a lecture is picked.
private struct NewTabChip: View {
    @EnvironmentObject var model: AppModel
    let selected: Bool
    @StateObject private var hover = HoverFlag()

    var body: some View {
        HStack(spacing: 4) {
            Text("New Tab").lineLimit(1).font(.callout.weight(selected ? .semibold : .regular))
            Button { model.closeNewTab() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 16, cornerRadius: 8))
            .opacity(selected || hover.on ? 1 : 0.45)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.16) : Color.gray.opacity(hover.on ? 0.16 : 0.07)))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { model.showNewTab() }
    }
}

/// The lecture page (what a New Tab shows): the sections, with buttons to add one, open a PDF or read the folders
/// again. The list itself is AppKit (LibraryPage.swift).
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Co-learner").font(.largeTitle.bold())
                Text("Pick a lecture. Ask about the slide you're on; the slide goes with your question.")
                    .foregroundStyle(.secondary)
                if model.folderAccessDenied {
                    Text("Co-learner can't read some linked folders. Allow it in System Settings › Privacy & Security › Files & Folders (Co-learner), then press Refresh.")
                        .foregroundStyle(.red)
                }
                HStack(spacing: 8) {
                    Button { model.newSection() } label: { Label("New Section", systemImage: "plus") }
                        .help("Add a section; link folders or PDFs to it now or later")
                    Button { model.openPDFPanel() } label: { Label("Open a PDF…", systemImage: "doc") }
                        .help("Open any PDF (it goes into Other PDFs unless a section lists it)")
                    Button { model.reloadLibrary() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Read the linked folders again (Co-learner also notices changes by itself)")
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)
            PanelHost(view: model.libraryOutline.scroll)
                .padding(.leading, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A section in the Lectures menu: what its linked folders hold (subfolders as submenus) and its linked PDFs.
private struct SectionMenu: View {
    @EnvironmentObject var model: AppModel
    let contents: SectionContents

    var body: some View {
        if contents.links.isEmpty { Text("Nothing linked yet") }
        ForEach(Array(contents.links.enumerated()), id: \.element.id) { i, l in
            if i > 0 { Divider() }
            if let n = l.node {
                if !n.isFolder {
                    NodeMenu(node: n)
                } else if n.children.isEmpty {
                    Text("\(n.name) (no PDFs)")
                } else {
                    ForEach(n.children) { NodeMenu(node: $0) }
                }
            } else {
                Text("\(URL(fileURLWithPath: l.item.path).lastPathComponent) (can't be found)")
            }
        }
    }
}

private struct NodeMenu: View {
    @EnvironmentObject var model: AppModel
    let node: LibraryNode

    var body: some View {
        if node.isFolder {
            Menu(node.name) { ForEach(node.children) { NodeMenu(node: $0) } }
        } else {
            Button(node.name) { model.openDeck(at: node.path) }
        }
    }
}

// MARK: - right panel

struct RightPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let shown = model.shownRightTab
        let docked = RightTab.allCases.filter { !model.poppedOut.contains($0) }
        VStack(spacing: 0) {
            HStack {
                if docked.count > 1 {
                    Picker("", selection: $model.rightTab) {
                        Text("Chat").tag(RightTab.chat)
                        Text(walkthroughTitle).tag(RightTab.walkthrough)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                } else {
                    Text(shown == .chat ? "Chat" : walkthroughTitle).font(.callout.weight(.semibold))
                }
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Button { model.popOut(shown) } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 12))
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .accessibilityLabel("Pop out")
                .padding(.trailing, 8)
                .help("Pop out \(shown == .chat ? "the chat" : "the walkthrough") into its own window (drag it to another screen, like an iPad). Close that window to put it back.")
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if shown == .chat {
                PanelHost(view: model.chat.webView)
            } else {
                WalkthroughPane()
            }
        }
    }

    private var walkthroughTitle: String {
        model.currentStudyPages.isEmpty ? "Walkthrough" : "Walkthrough (\(model.currentStudyPages.count))"
    }
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
        w.tabbingMode = .disallowed
        let wv = WKWebView(frame: .zero)
        wv.loadHTMLString(html, baseURL: nil)
        w.contentView = wv
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        windows.removeAll { !$0.isVisible && $0 !== w }
    }
}
