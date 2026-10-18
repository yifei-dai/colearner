import SwiftUI
import AppKit

// MARK: - slides | right panel split

/// Where the divider sits: the slides' share of the width. Every launch starts at 3 : 2 (slides : right).
final class SplitState: ObservableObject {
    static let defaultFraction: CGFloat = 0.6
    @Published var fraction: CGFloat = SplitState.defaultFraction
    /// The slides' width when the current drag began.
    var dragStartWidth: CGFloat = 0
}

/// Slides on the left, the right panel on the right, with a draggable divider (double-click: back to 3 : 2).
/// With the right panel hidden (Chat and Walkthrough both popped out), the slides take the whole width.
struct SplitPanes<Left: View, Right: View>: View {
    @ObservedObject var state: SplitState
    let showRight: Bool
    var minLeft: CGFloat = 420
    var minRight: CGFloat = 320
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let leftWidth = showRight ? width(for: state.fraction, total: total) : total
            HStack(spacing: 0) {
                left.frame(width: leftWidth)   // same place in both layouts, so the slide view is kept
                if showRight {
                    Divider()
                    right.frame(maxWidth: .infinity)
                }
            }
            .frame(width: total, height: geo.size.height)
            .overlay(alignment: .topLeading) {
                if showRight {
                    SplitHandle(
                        onBegin: { state.dragStartWidth = width(for: state.fraction, total: total) },
                        onDrag: { offset in
                            // From the width at mouse-down plus the total offset: no drift, no lost small steps.
                            state.fraction = width(for: (state.dragStartWidth + offset) / max(total, 1), total: total) / max(total, 1)
                        },
                        onReset: { state.fraction = SplitState.defaultFraction })
                    .frame(width: 8, height: geo.size.height)
                    .offset(x: leftWidth - 4)
                }
            }
        }
    }

    /// The slides' width for a share of `total`, kept inside both panes' minimum widths.
    private func width(for fraction: CGFloat, total: CGFloat) -> CGFloat {
        let lo = min(minLeft, total * 0.5), hi = max(total - minRight - 1, lo)
        return min(max(total * fraction, lo), hi).rounded()
    }
}

/// The divider's grab area: resize cursor, drag to move, double-click to reset.
private struct SplitHandle: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void   // total horizontal offset since mouse-down
    let onReset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: HandleView, context: Context) {
        v.onBegin = onBegin
        v.onDrag = onDrag
        v.onReset = onReset
    }

    final class HandleView: NSView {
        var onBegin: () -> Void = {}
        var onDrag: (CGFloat) -> Void = { _ in }
        var onReset: () -> Void = {}
        private var startX: CGFloat = 0
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { onReset() }
            startX = e.locationInWindow.x
            onBegin()
        }
        override func mouseDragged(with e: NSEvent) { onDrag(e.locationInWindow.x - startX) }
    }
}

// MARK: - hosting the shared panel views

/// Shows an NSView that lives elsewhere (the chat page, a walkthrough page, the notes PDF), so moving it
/// between the right panel and a pop-out window never reloads it. Whichever host appears last takes the view;
/// a host going away only removes the view if it still holds it.
struct PanelHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {}

    static func dismantleNSView(_ box: NSView, coordinator: ()) {
        for v in box.subviews { v.removeFromSuperview() }
    }
}

// MARK: - pop-out windows

/// Chat and Walkthrough in windows of their own (e.g. on an iPad used as a second screen). Closing one puts the
/// panel back next to the slides. Each window remembers where it was; the first time, it goes to another
/// screen if there is one.
@MainActor
final class PopOutWindows: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var windows: [RightTab: NSWindow] = [:]
    /// The main window is closing (the app quits): close these too, but keep them popped out for next time.
    private var quitting = false

    init(model: AppModel) {
        self.model = model
    }

    func contains(_ w: NSWindow) -> Bool { windows.values.contains { $0 === w } }
    func window(for tab: RightTab) -> NSWindow? { windows[tab] }

    func show(_ tab: RightTab) {
        guard let model else { return }
        if let w = windows[tab] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 780),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = tab == .chat ? "Chat — Co-learner" : "Walkthrough — Co-learner"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 340, height: 360)
        w.tabbingMode = .disallowed   // never merged into one tabbed window (keeps both on the iPad side by side)
        w.delegate = self
        let content: AnyView = tab == .chat
            ? AnyView(PanelHost(view: model.chat.webView))
            : AnyView(WalkthroughPane())
        w.contentView = NSHostingView(rootView: content.environmentObject(model))
        w.addTitlebarAccessoryViewController(putBackAccessory(tab))
        let name = "CoLearner.PopOut.\(tab.rawValue)"
        if !w.setFrameUsingName(name) { w.setFrame(firstFrame(for: tab), display: false) }
        w.setFrameAutosaveName(name)
        windows[tab] = w
        w.makeKeyAndOrderFront(nil)
    }

    /// Put the panel back (the window closes; windowWillClose docks it).
    func close(_ tab: RightTab) { windows[tab]?.close() }

    func closeAllForQuit() {
        quitting = true
        for w in Array(windows.values) { w.close() }   // windowWillClose runs synchronously
        quitting = false   // the app may stay open (Settings or a visual window): later pop-outs dock as usual
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let tab = windows.first(where: { $0.value === w })?.key else { return }
        windows[tab] = nil
        w.contentView = nil   // let go of the panel view so the right panel can show it again
        if !quitting { model?.didClosePopOut(tab) }
    }

    /// "Put back" at the right end of the title bar.
    private func putBackAccessory(_ tab: RightTab) -> NSTitlebarAccessoryViewController {
        let button = Button { [weak self] in self?.close(tab) } label: {
            Label("Put back", systemImage: "arrow.down.left.square").labelStyle(.titleAndIcon).font(.callout)
        }
        .buttonStyle(IconButtonStyle(size: 22))
        .padding(.horizontal, 8)
        .help("Put the \(tab == .chat ? "chat" : "walkthrough") back next to the slides")
        let host = NSHostingView(rootView: button)
        let fit = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: ceil(fit.width) + 12, height: max(ceil(fit.height), 28))
        let vc = NSTitlebarAccessoryViewController()
        vc.view = host
        vc.layoutAttribute = .trailing
        return vc
    }

    /// First placement: the whole of another screen if there is one; if the other panel is already there, the
    /// two share it (Chat on the left). Without a second screen: beside the main window's right edge.
    private func firstFrame(for tab: RightTab) -> NSRect {
        let mainScreen = model?.mainWindow?.screen ?? NSScreen.main
        if let other = NSScreen.screens.first(where: { $0 !== mainScreen }) {
            let f = other.visibleFrame
            let sibling: RightTab = tab == .chat ? .walkthrough : .chat
            if let sw = windows[sibling], sw.screen === other {
                var left = f
                left.size.width = (f.width / 2).rounded()
                let right = NSRect(x: left.maxX, y: f.minY, width: f.width - left.width, height: f.height)
                sw.setFrame(sibling == .chat ? left : right, display: true)
                return tab == .chat ? left : right
            }
            return f
        }
        let screen = (mainScreen ?? NSScreen.screens[0]).visibleFrame
        let size = NSSize(width: min(560, screen.width / 2), height: min(screen.height, 820))
        var origin = NSPoint(x: screen.maxX - size.width, y: screen.maxY - size.height)
        if tab == .walkthrough, windows[.chat] != nil { origin.x = max(screen.minX, origin.x - size.width) }
        return NSRect(origin: origin, size: size)
    }
}
