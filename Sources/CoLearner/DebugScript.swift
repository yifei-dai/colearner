#if DEBUG
import AppKit
import WebKit

/// Debug builds only: COLEARNER_SCRIPT drives the app for an end-to-end check without anyone at the keyboard, one
/// step per ";" — open <address>, pdf <path>, newtab, wait <seconds>, shot <png path>, thumbs, scroll <y>,
/// goto <heading text>, readtext <txt path>, click <link text>, menus <txt path>, menushot <menu> <png path>, back,
/// next, slide <n>, size <w> <h>, tab <chat|walkthrough>, appearance <light|dark|system>, area <x0 y0 x1 y1>,
/// chrome <on|off>, float <on|off>, chatjs <javascript>, ask <claude|codex|both> <question>, idle <most seconds>,
/// film <png prefix> <seconds> <frames>, stop, close, quit. `shot` draws the window itself
/// (web views by their own snapshots), so no screen-recording permission is involved.
@MainActor
enum DebugScript {
    static func start(_ model: AppModel) {
        guard let script = ProcessInfo.processInfo.environment["COLEARNER_SCRIPT"], !script.isEmpty else { return }
        let steps = script.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(steps[...], model) }
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("[script] \(s)\n".utf8)) }
    /// `chrome on`: pictures include the window's title bar and buttons (the frame view), not only its content.
    private static var withChrome = false

    private static func run(_ steps: ArraySlice<String>, _ model: AppModel) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        let next = { DispatchQueue.main.async { run(rest, model) } }
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        log(step)
        switch parts[0] {
        case "open":
            if let u = WebAddress.parse(arg) { model.openWeb(u) } else { log("not an address: \(arg)") }
            next()
        case "pdf":
            model.openDeck(at: arg)
            next()
        case "newtab":
            model.openNewTab()
            next()
        case "wait":
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(arg) ?? 1)) { run(rest, model) }
        case "shot":
            guard let w = model.mainWindow else { log("no window"); next(); return }
            log("window visible: \(w.occlusionState.contains(.visible)), key: \(w.isKeyWindow), app active: \(NSApp.isActive)")
            shot(w, to: arg, next)
        case "chrome":
            withChrome = arg == "on"
            next()
        case "float":
            // "float on": the window stays above other apps' windows, so WebKit keeps drawing it while pictures are
            // taken even if someone clicks another app.
            model.mainWindow?.level = arg == "on" ? .floating : .normal
            next()
        case "thumbs":
            model.toggleThumbnails()
            next()
        case "scroll":
            model.web?.webView.evaluateJavaScript("window.scrollTo(0, \(Double(arg) ?? 0)); 0", completionHandler: nil)
            next()
        case "click":
            let text = arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            model.web?.webView.evaluateJavaScript("""
                (function () { var a = Array.from(document.querySelectorAll('main a[href], a[href]')).find(function (x) {
                  return x.textContent.replace(/\\s+/g, ' ').trim().indexOf('\(text)') >= 0; });
                  if (a) { a.click(); return a.href; } return 'not found'; })()
                """) { r, _ in MainActor.assumeIsolated { log("click -> \(String(describing: r))"); next() } }
        case "goto":
            let text = arg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            model.web?.webView.evaluateJavaScript("""
                (function () { var h = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6')).find(function (x) {
                  return x.textContent.indexOf('\(text)') >= 0; }); if (h) { h.scrollIntoView(); return true; } return false; })()
                """) { r, _ in MainActor.assumeIsolated { log("goto -> \(String(describing: r))"); next() } }
        case "readtext":
            guard let tab = model.web, let d = model.deck else { next(); return }
            tab.snapshot(root: d.path) { snap in
                let out = "title: \(snap.page?.title ?? "-")\nsite: \(snap.page?.site ?? "-")\nsection: \(snap.screen?.section ?? [])\n"
                    + "visible:\n\(snap.screen?.visible ?? "-")\n----- text -----\n\(snap.page?.text ?? "-")\n"
                try? out.write(toFile: arg, atomically: true, encoding: .utf8)
                log("read \(snap.page?.text.count ?? 0) characters")
                next()
            }
        case "menus":
            var lines: [String] = []
            func walk(_ m: NSMenu, _ depth: Int) {
                // As when the menu opens: SwiftUI fills its items in then (until then they can be from launch).
                m.delegate?.menuNeedsUpdate?(m)
                m.update()
                for i in m.items {
                    let keys = i.keyEquivalent.isEmpty ? "" : " [\(i.keyEquivalentModifierMask.rawValue >> 17):\(i.keyEquivalent)]"
                    lines.append(String(repeating: "  ", count: depth) + (i.isSeparatorItem ? "-" : i.title) + keys + (i.isEnabled ? "" : " (off)")
                                 + (i.isSectionHeader ? " (header)" : "") + (i.isHidden ? " (hidden)" : ""))
                    if let sub = i.submenu { walk(sub, depth + 1) }
                }
            }
            if let main = NSApp.mainMenu { walk(main, 0) }
            try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
            next()
        case "menushot":
            // "menushot Usage <png>": that menu of the menu bar, opened as a pop-up for a moment and drawn from its own
            // window (no screen recording involved).
            let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard p.count == 2, let bar = NSApp.mainMenu?.items.first(where: { $0.title == p[0] })?.submenu,
                  let view = model.mainWindow?.contentView else { log("no menu \(arg)"); next(); return }
            bar.delegate?.menuNeedsUpdate?(bar)   // filled in as when it opens
            let menu = bar.copy() as! NSMenu      // a menu in the menu bar can't also pop up
            let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let names = NSApp.windows.filter(\.isVisible).map { NSStringFromClass(type(of: $0)) }
                    if let mw = NSApp.windows.first(where: { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Menu") }),
                       let cv = mw.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                        cv.cacheDisplay(in: cv.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
                        log("menu window \(NSStringFromClass(type(of: mw))) \(mw.frame)")
                    } else { log("no menu window among \(names)") }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            let shown = menu.popUp(positioning: nil, at: NSPoint(x: 60, y: view.isFlipped ? 60 : view.bounds.height - 60), in: view)
            log("menu popped up: \(shown)")
            next()
        case "back":
            model.turn(-1)
            next()
        case "next":
            model.turn(1)
            next()
        case "slide":
            model.goToPage(Int(arg) ?? 1)
            next()
        case "size":
            // "size 1440 860": the window's content size in points, centered on its screen.
            let wh = arg.split(separator: " ").compactMap { Double($0) }
            if wh.count == 2, let w = model.mainWindow { w.setContentSize(NSSize(width: wh[0], height: wh[1])); w.center() }
            next()
        case "tab":
            model.showPanel(arg == "walkthrough" ? .walkthrough : .chat)
            next()
        case "appearance":
            model.appearance = arg   // light, dark or system
            next()
        case "area":
            // "area x0 y0 x1 y1": the part of the slide on screen to ask about, as fractions of the page (origin top
            // left), as if dragged out with ✂︎ Select area.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            if f.count == 4, let doc = model.document, let p = doc.page(at: model.page - 1) {
                let b = p.bounds(for: .cropBox)
                let r = CGRect(x: b.minX + f[0] * b.width, y: b.minY + (1 - f[3]) * b.height,
                               width: (f[2] - f[0]) * b.width, height: (f[3] - f[1]) * b.height)
                model.finishAreaSelection(page: p, rect: r)
            } else { log("area needs four fractions and an open deck") }
            next()
        case "idle":
            // "idle <most seconds>": wait for an answer to start (up to 10 s), then until no assistant is writing,
            // then one more second for the page to settle.
            let start = Date(), until = start.addingTimeInterval(Double(arg) ?? 180)
            var started = false
            func check() {
                let answering = model.chat.debugAnswering
                started = started || answering
                if (started && !answering) || Date() > until || (!started && Date() > start.addingTimeInterval(10)) {
                    log("idle after \(Int(Date().timeIntervalSince(start))) s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(rest, model) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { check() }
        case "film":
            // "film <png prefix> <seconds between frames> <most frames>": pictures while an answer is being written
            // (frames for a GIF): from the send until it is done (waiting up to 10 s for it to start), then one more.
            let p = arg.split(separator: " ").map(String.init)
            guard p.count == 3, let dt = Double(p[1]), let most = Int(p[2]), let w = model.mainWindow else {
                log("film needs a prefix, an interval and a frame count"); next(); return
            }
            let start = Date()
            var n = 0
            var started = false
            func frame() {
                let answering = model.chat.debugAnswering
                started = started || answering
                let waiting = !started && Date().timeIntervalSince(start) < 10
                n += 1
                if !w.occlusionState.contains(.visible) { log("frame \(n): window not visible, WebKit may not redraw") }
                shot(w, to: "\(p[0])-\(String(format: "%03d", n)).png") {
                    if n < most && (answering || waiting) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + dt) { frame() }
                    } else if n < most && started {
                        // the last picture, once the answer has settled on the page
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            n += 1
                            shot(w, to: "\(p[0])-\(String(format: "%03d", n)).png") { log("film: \(n) frames"); next() }
                        }
                    } else { log("film: \(n) frames"); next() }
                }
            }
            frame()
        case "chatjs":
            // Runs a line of JavaScript in the chat page, e.g. a click on one of its buttons.
            model.chat.webView.evaluateJavaScript(arg) { r, e in
                MainActor.assumeIsolated { log("chatjs -> \(String(describing: r))\(e.map { " error: \($0)" } ?? "")"); next() }
            }
        case "ask":
            let q = arg.split(separator: " ", maxSplits: 1).map(String.init)
            model.chat.send(text: q.count > 1 ? q[1] : "Explain what's on screen", display: nil, choice: q.first ?? "claude", useArea: true)
            next()
        case "stop":
            model.chat.stopVisible()
            next()
        case "close":
            model.closeCurrentTab()
            next()
        case "quit":
            NSApp.terminate(nil)
        default:
            log("unknown step: \(step)")
            next()
        }
    }

    /// A picture of the window's content (with `chrome on`, the whole window with its title bar): the views drawn as
    /// AppKit draws them, with each web view's own snapshot on top.
    private static func shot(_ window: NSWindow, to path: String, _ done: @escaping () -> Void) {
        guard let content = withChrome ? window.contentView?.superview : window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { done(); return }
        content.cacheDisplay(in: content.bounds, to: rep)
        var webs: [WKWebView] = []
        var layered: [NSView] = []
        func collect(_ v: NSView) {
            if let w = v as? WKWebView, !w.isHiddenOrHasHiddenAncestor, w.bounds.width > 1 { webs.append(w); return }
            // PDFKit draws pages in tiles of its own layers, which cacheDisplay can miss: their layer tree instead.
            if NSStringFromClass(type(of: v)).hasPrefix("PDFView"), !v.isHiddenOrHasHiddenAncestor, v.layer != nil { layered.append(v); return }
            v.subviews.forEach(collect)
        }
        collect(content)
        var pictures: [(NSRect, NSImage)] = []
        for v in layered {
            guard let layer = v.layer else { continue }
            let scale = window.backingScaleFactor
            let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            if !layer.isGeometryFlipped && v.isFlipped { ctx.translateBy(x: 0, y: v.bounds.height); ctx.scaleBy(x: 1, y: -1) }
            layer.render(in: ctx)
            guard let cg = ctx.makeImage() else { continue }
            var r = content.convert(v.bounds, from: v)
            if content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
            pictures.append((r, NSImage(cgImage: cg, size: v.bounds.size)))
        }
        var left = webs.count
        let finish = {
            // A bar without a background of its own is see-through in the cache: lay the window's background color
            // under everything, as on screen, then the cached views, then the web views' and PDF pages' pictures.
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { done(); return }
            out.size = rep.size
            let all = NSRect(origin: .zero, size: rep.size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                (window.backgroundColor ?? .windowBackgroundColor).setFill()
                all.fill()
            }
            rep.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            for (r, image) in pictures { image.draw(in: r) }
            NSGraphicsContext.restoreGraphicsState()
            try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            log("wrote \(path)")
            done()
        }
        if webs.isEmpty { finish(); return }
        for w in webs {
            var r = content.convert(w.bounds, from: w)
            if content.isFlipped { r.origin.y = content.bounds.height - r.maxY }
            w.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated {
                    if let image { pictures.append((r, image)) }
                    left -= 1
                    if left == 0 { finish() }
                }
            }
        }
    }

    /// COLEARNER_LOG_PROMPTS=<folder>: each request to an assistant is written there (prompt, pictures, tools).
    static func logRequest(_ req: BackendRequest, provider: Provider) {
        guard let dir = ProcessInfo.processInfo.environment["COLEARNER_LOG_PROMPTS"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var s = "provider: \(provider.rawValue)\nmodel: \(req.model ?? "") · \(req.effort ?? "")\ntools off: \(req.toolsOff)\n"
        s += "readable: \(req.readableDirs.map(\.path))\nimages: \(req.imageURLs.map(\.path))\nresume: \(req.resume ?? "-")\n"
        s += "instructions starts: \(req.instructions.prefix(80))\n----- prompt -----\n\(req.prompt)\n"
        try? s.write(toFile: dir + "/\(stamp)-\(provider.rawValue).txt", atomically: true, encoding: .utf8)
    }
}
#endif
