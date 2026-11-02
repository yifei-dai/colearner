import AppKit
import SwiftUI

/// What the lecture page asks of the app (AppModel; a fake in tests).
@MainActor
protocol LibraryActions: AnyObject {
    var sectionsFile: SectionsFile { get }
    func openDeck(at path: String)
    /// Changes the sections, saves them and reads the folders again.
    func editSections(_ change: (inout SectionsFile) -> Void)
    /// Saves a change that doesn't alter what is listed (a section or folder opened or closed).
    func noteSections(_ change: (inout SectionsFile) -> Void)
    /// Links folders or PDFs (chosen in a panel or dropped from Finder) to a section.
    func link(_ urls: [URL], to section: String, at index: Int?)
    func linkPanel(_ kind: LinkedItem.Kind, to section: String)
    func newSection()
    func removeSection(_ id: String)
    /// Renames the PDF on disk; returns what went wrong, or nil.
    func renameFile(_ path: String, to name: String) -> String?
}

/// One row of the lecture page: a section heading, an item linked to it, something inside a linked folder, the
/// section's hidden files, or the hint in an empty section.
final class LibraryRow: NSObject {
    enum Kind { case section, link, node, hiddenGroup, hiddenNode, empty }
    let key: String
    let kind: Kind
    let section: String
    var title = ""
    var item: LinkedItem?
    var node: LibraryNode?
    var children: [LibraryRow] = []

    init(key: String, kind: Kind, section: String) {
        self.key = key
        self.kind = kind
        self.section = section
    }

    var path: String? { node?.path ?? item?.path }
    var isFolder: Bool { node?.isFolder ?? (item?.kind == .folder) }
    var isFile: Bool { node.map { !$0.isFolder } ?? false }
    /// A linked folder or PDF that can't be found.
    var missing: Bool { kind == .link && node == nil }

    /// What dragging this row carries.
    var drag: LibraryDrag? {
        switch kind {
        case .section: return LibraryDrag(what: .section, section: section)
        case .link: return item.map { LibraryDrag(what: .item, section: section, item: $0.id) }
        case .node, .hiddenNode:
            guard let n = node else { return nil }
            return LibraryDrag(what: .inside, section: section, path: n.path, kind: n.isFolder ? .folder : .file)
        case .hiddenGroup, .empty: return nil
        }
    }
}

/// The lecture page under a New Tab: every section with its linked folders and PDFs, as one outline. Click a PDF
/// to open it, a heading or folder to open or close it; drag rows between sections (Option keeps a copy) or up
/// and down; drop PDFs and folders from Finder on a section; right-click for the rest.
@MainActor
final class LibraryOutline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    static let dragType = NSPasteboard.PasteboardType("com.yifeidai.colearner.library-row")
    /// The "Hidden (n)" row's entry in SectionsFile.expanded (not a path).
    static let hiddenKey = "#hidden"

    let scroll = NSScrollView()
    let outline = LibraryOutlineView()
    weak var actions: LibraryActions?
    /// The sections, top level of the outline.
    private(set) var rows: [LibraryRow] = []
    private var byKey: [String: LibraryRow] = [:]
    private var file = SectionsFile()
    /// Expanding and collapsing rows to match the saved state (not the user's doing).
    private var restoring = false
    private var editing: (row: LibraryRow, field: NSTextField)?
    private var editCancelled = false
    /// A reload that came in while a name was being edited.
    private var pending: ([SectionContents], SectionsFile)?
    private var renameWhenShown: String?
    /// Sections with a linked folder too big to list in full.
    private var truncated = Set<String>()

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = 16
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([Self.dragType, .fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)   // nothing leaves the app (Finder would move the file)
        outline.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.setAccessibilityLabel("Lectures")
        outline.onWindow = { [weak self] in
            guard let self, let id = self.renameWhenShown else { return }
            DispatchQueue.main.async { self.beginRename(section: id) }
        }

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // Scrolling moves rows under a pointer that stays put: the highlight goes with the pointer, not the rows.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rowsMoved), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    @objc private func rowsMoved() { outline.hoverUnderPointer() }

    // MARK: showing the sections

    /// Shows what the sections list now; rows that stay keep their place, and folders open as saved.
    func show(_ sections: [SectionContents], file: SectionsFile) {
        if editing != nil { pending = (sections, file); return }
        pending = nil
        self.file = file
        truncated = Set(sections.filter(\.truncated).map(\.id))
        var seen: [String: LibraryRow] = [:]
        func row(_ key: String, _ kind: LibraryRow.Kind, _ section: String) -> LibraryRow {
            let r = byKey[key] ?? LibraryRow(key: key, kind: kind, section: section)
            seen[key] = r
            return r
        }
        // Keyed by section and link too: a subfolder linked by itself and inside its linked parent shows twice.
        func nodeRow(_ n: LibraryNode, _ section: String, link: String, hidden: Bool) -> LibraryRow {
            let r = row((hidden ? "hn|" : "n|") + section + "|" + link + "|" + n.path, hidden ? .hiddenNode : .node, section)
            r.node = n
            r.title = n.name
            r.children = hidden ? [] : n.children.map { nodeRow($0, section, link: link, hidden: false) }
            return r
        }
        rows = sections.map { s in
            let sr = row("s|" + s.id, .section, s.id)
            sr.title = s.section.name
            var kids: [LibraryRow] = s.links.map { l in
                let r = row("l|\(s.id)|\(l.item.id)", .link, s.id)
                r.item = l.item
                r.node = l.node
                let u = URL(fileURLWithPath: l.item.path)
                r.title = l.node?.name ?? (l.item.kind == .folder ? u.lastPathComponent : u.deletingPathExtension().lastPathComponent)
                r.children = l.node?.isFolder == true ? l.node!.children.map { nodeRow($0, s.id, link: l.item.id, hidden: false) } : []
                return r
            }
            if s.links.isEmpty {
                let e = row("e|" + s.id, .empty, s.id)
                e.title = "Nothing linked yet. Use + to link a folder or PDFs, or drop them here from Finder."
                kids.append(e)
            }
            if !s.hidden.isEmpty {
                let h = row("h|" + s.id, .hiddenGroup, s.id)
                h.title = "Hidden (\(s.hidden.count))"
                h.children = s.hidden.map { nodeRow($0, s.id, link: "", hidden: true) }
                kids.append(h)
            }
            sr.children = kids
            return sr
        }
        byKey = seen
        // Reloading collapses rows on its own; that isn't the user closing them.
        restoring = true
        outline.reloadData()
        restoring = false
        restoreExpansion()
        outline.hoverUnderPointer()
        if let id = renameWhenShown, file.section(id) != nil, outline.window != nil { beginRename(section: id) }
    }

    private func restoreExpansion() {
        restoring = true
        defer { restoring = false }
        rows.forEach(applySaved)
    }

    /// Opens or closes a row as saved, and its children too when it is open.
    private func applySaved(_ r: LibraryRow) {
        let expand: Bool
        switch r.kind {
        case .section: expand = file.section(r.section)?.collapsed != true
        case .link: expand = r.isFolder && r.item?.collapsed != true
        case .node: expand = r.isFolder && (file.expanded ?? []).contains(r.section + "|" + (r.path ?? ""))
        case .hiddenGroup: expand = (file.expanded ?? []).contains(r.section + "|" + Self.hiddenKey)
        case .hiddenNode, .empty: expand = false
        }
        if expand {
            outline.expandItem(r)
            r.children.forEach(applySaved)
        } else if outline.isItemExpanded(r) {
            outline.collapseItem(r)
        }
    }

    /// Starts editing a section's name (a new section starts this way), once the page is on screen.
    func beginRename(section id: String) {
        guard let r = byKey["s|" + id], outline.window != nil else { renameWhenShown = id; return }
        renameWhenShown = nil
        beginEditing(r)
    }

    // MARK: data source

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let r = item as? LibraryRow else { return rows.count }
        return r.children.count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let r = item as? LibraryRow else { return rows[index] }
        return r.children[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let r = item as? LibraryRow else { return false }
        switch r.kind {
        case .section, .hiddenGroup: return true
        case .link, .node: return r.isFolder && !r.children.isEmpty
        case .hiddenNode, .empty: return false
        }
    }

    // MARK: rows

    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let r = item as? LibraryRow else { return 24 }
        switch r.kind {
        case .section: return r === rows.first ? 32 : 44
        case .empty: return 26
        default: return 24
        }
    }

    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let v = LibraryRowView()
        if let r = item as? LibraryRow { v.hoverable = r.kind != .empty; v.isSection = r.kind == .section }
        return v
    }

    func outlineView(_ ov: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? LibraryRowView)?.hovering = row == outline.hoveredRow
    }

    func outlineView(_ ov: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        (rowView as? LibraryRowView)?.hovering = false
    }

    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let r = item as? LibraryRow else { return nil }
        if r.kind == .section {
            let cell = (ov.makeView(withIdentifier: SectionCell.id, owner: self) as? SectionCell) ?? SectionCell()
            let s = file.section(r.section)
            let count = (s?.items.count ?? 0) == 0 ? "" : countText(r)
            cell.show(name: r.title, count: truncated.contains(r.section) ? count + " · partial list (a linked folder is too big)" : count)
            cell.onPlus = { [weak self] b in self?.showLinkMenu(for: r.section, from: b) }
            cell.onMore = { [weak self] b in self?.showSectionMenu(for: r.section, from: b) }
            return cell
        }
        let cell = (ov.makeView(withIdentifier: ItemCell.id, owner: self) as? ItemCell) ?? ItemCell()
        cell.show(r)
        return cell
    }

    private func countText(_ r: LibraryRow) -> String {
        let n = r.children.reduce(0) { $0 + ($1.kind == .hiddenGroup ? 0 : pdfCount($1)) }
        return n == 1 ? "1 PDF" : "\(n) PDFs"
    }

    private func pdfCount(_ r: LibraryRow) -> Int {
        r.isFile ? 1 : r.children.reduce(0) { $0 + pdfCount($1) }
    }

    func outlineViewItemDidExpand(_ n: Notification) {
        remember(n, open: true)
        // What is inside opens as it was left (a section closed at launch had never been laid out).
        guard !restoring, let r = n.userInfo?["NSObject"] as? LibraryRow else { return }
        restoring = true
        r.children.forEach(applySaved)
        restoring = false
        outline.hoverUnderPointer()
    }
    func outlineViewItemDidCollapse(_ n: Notification) {
        remember(n, open: false)
        if !restoring { outline.hoverUnderPointer() }
    }

    /// Keeps a heading or folder opened or closed by the user that way next time.
    private func remember(_ n: Notification, open: Bool) {
        guard !restoring, let r = n.userInfo?["NSObject"] as? LibraryRow else { return }
        // Closing a row closes the open rows inside it first (deepest first, their parent already closed): those
        // stay open as saved, for when it opens again.
        if !open, let parent = outline.parent(forItem: r), !outline.isItemExpanded(parent) { return }
        switch r.kind {
        case .section:
            actions?.noteSections { f in
                if let i = f.index(of: r.section) { f.sections[i].collapsed = open ? nil : true }
            }
        case .link:
            guard let id = r.item?.id else { return }
            actions?.noteSections { f in
                guard let s = f.index(of: r.section), let i = f.sections[s].items.firstIndex(where: { $0.id == id }) else { return }
                f.sections[s].items[i].collapsed = open ? nil : true
            }
        case .node, .hiddenGroup:
            guard let p = r.kind == .hiddenGroup ? Self.hiddenKey : r.path else { return }
            let key = r.section + "|" + p
            actions?.noteSections { f in
                var e = f.expanded ?? []
                e.removeAll { $0 == key }
                if open { e.append(key) }
                f.expanded = e.isEmpty ? nil : e
            }
        case .hiddenNode, .empty:
            break
        }
        if let current = actions?.sectionsFile { file = current }
    }

    // MARK: clicks

    @objc private func clicked() {
        // The row that was pressed: a click that ends a rename reloads the page first, and rows may have moved.
        let pressed = outline.pressedItem as? LibraryRow
        outline.pressedItem = nil
        guard let r = pressed ?? (outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? LibraryRow : nil),
              editing == nil else { return }
        let i = outline.row(forItem: r)
        guard i >= 0 else { return }
        if let e = NSApp.currentEvent, e.type == .leftMouseUp || e.type == .leftMouseDown {
            // The second click of a double-click: the first one already acted.
            if e.clickCount > 1 { return }
            // The disclosure triangle and the heading's buttons handle their own clicks.
            let p = outline.convert(e.locationInWindow, from: nil)
            if outline.frameOfOutlineCell(atRow: i).insetBy(dx: -2, dy: -2).contains(p) { return }
            if outline.hitTest(outline.superview?.convert(p, from: outline) ?? p) is NSButton { return }
        }
        activate(r)
    }

    /// What a click on a row does: open a PDF, open or close a heading or folder.
    func activate(_ r: LibraryRow) {
        switch r.kind {
        case .section, .hiddenGroup:
            toggle(r)
        case .link, .node:
            if r.isFolder { toggle(r) } else if let p = r.path, !r.missing { actions?.openDeck(at: p) }
        case .hiddenNode:
            if r.isFile, let p = r.path { actions?.openDeck(at: p) }
        case .empty:
            break
        }
    }

    private func toggle(_ r: LibraryRow) {
        guard outline.isExpandable(r) else { return }
        if outline.isItemExpanded(r) { outline.collapseItem(r) } else { outline.expandItem(r) }
    }

    // MARK: menus

    private func showLinkMenu(for section: String, from button: NSView) {
        let m = NSMenu()
        m.addItem(item("Link Folder…") { [weak self] in self?.actions?.linkPanel(.folder, to: section) })
        m.addItem(item("Link PDFs…") { [weak self] in self?.actions?.linkPanel(.file, to: section) })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func showSectionMenu(for section: String, from button: NSView) {
        let m = NSMenu()
        sectionItems(section).forEach(m.addItem)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func sectionItems(_ section: String) -> [NSMenuItem] {
        [
            item("Link Folder…") { [weak self] in self?.actions?.linkPanel(.folder, to: section) },
            item("Link PDFs…") { [weak self] in self?.actions?.linkPanel(.file, to: section) },
            .separator(),
            item("Rename Section") { [weak self] in self?.beginRename(section: section) },
            item("Remove Section…") { [weak self] in self?.actions?.removeSection(section) },
        ]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let i = outline.clickedRow
        guard i >= 0, let r = outline.item(atRow: i) as? LibraryRow else {
            menu.addItem(item("New Section") { [weak self] in self?.actions?.newSection() })
            return
        }
        menuItems(for: r).forEach(menu.addItem)
    }

    /// The right-click menu of a row.
    func menuItems(for r: LibraryRow) -> [NSMenuItem] {
        let path = r.path
        let finder = path.map { p in item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
        let open = r.isFile ? path.map { p in item("Open") { [weak self] in self?.actions?.openDeck(at: p) } } : nil
        let rename = r.isFile ? item("Rename File…") { [weak self] in self?.beginEditing(r) } : nil
        switch r.kind {
        case .section:
            return sectionItems(r.section) + [.separator(), item("New Section") { [weak self] in self?.actions?.newSection() }]
        case .link:
            guard let id = r.item?.id else { return [] }
            let unlink = item(r.isFolder ? "Unlink Folder" : "Remove from Section") { [weak self] in
                self?.actions?.editSections { $0.unlink(item: id, from: r.section) }
            }
            if r.missing { return [unlink] }
            return [open, finder, rename, .separator(), unlink].compactMap { $0 }
        case .node:
            guard let p = path else { return [] }
            let hide = item("Hide from Section") { [weak self] in self?.actions?.editSections { $0.hide(p, in: r.section) } }
            return [open, finder, rename, .separator(), hide].compactMap { $0 }
        case .hiddenNode:
            guard let p = path else { return [] }
            let again = item("Show in Section Again") { [weak self] in self?.actions?.editSections { $0.unhide(p, in: r.section) } }
            return [again, .separator(), open, finder].compactMap { $0 }
        case .hiddenGroup:
            let paths = r.children.compactMap(\.path)
            return [item("Show All Again") { [weak self] in
                self?.actions?.editSections { f in paths.forEach { f.unhide($0, in: r.section) } }
            }]
        case .empty:
            return sectionItems(r.section)
        }
    }

    private func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, run: run)
    }

    // MARK: renaming in place

    private func beginEditing(_ r: LibraryRow) {
        let i = outline.row(forItem: r)
        guard i >= 0, editing == nil else { return }
        outline.scrollRowToVisible(i)
        guard let cell = outline.view(atColumn: 0, row: i, makeIfNecessary: true) as? EditableCell else { return }
        let field = cell.nameField
        editing = (r, field)
        editCancelled = false
        field.stringValue = r.title
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        outline.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)), let e = editing else { return false }
        editCancelled = true
        e.field.stringValue = e.row.title
        outline.window?.makeFirstResponder(outline)
        return true
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let e = editing, (n.object as? NSTextField) === e.field else { return }
        editing = nil
        e.field.isEditable = false
        e.field.isSelectable = false
        let text = e.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if let p = pending { pending = nil; show(p.0, file: p.1) }
        }
        guard !editCancelled, !text.isEmpty, text != e.row.title else { e.field.stringValue = e.row.title; return }
        if e.row.kind == .section {
            actions?.editSections { $0.rename(section: e.row.section, to: text) }
        } else if let p = e.row.path, let problem = actions?.renameFile(p, to: text) {
            e.field.stringValue = e.row.title
            let a = NSAlert()
            a.messageText = "Couldn't rename “\(e.row.title)”"
            a.informativeText = problem
            a.runModal()
        }
    }

    // MARK: dragging

    func outlineView(_ ov: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard editing == nil, let r = item as? LibraryRow, let drag = r.drag,
              let data = try? JSONEncoder().encode(drag) else { return nil }
        let pb = NSPasteboardItem()
        pb.setData(data, forType: Self.dragType)
        return pb
    }

    /// Where a drop lands: the row the outline should highlight, and the section and place among its linked items
    /// (nil: at the end) - or, for a section, its new place among the sections.
    struct DropTarget: Equatable {
        var dropRow: LibraryRow?
        var childIndex: Int
        var section: String?
        var insertAt: Int?
    }

    func dropTarget(for drag: LibraryDrag?, proposed item: LibraryRow?, index: Int) -> DropTarget? {
        let sectionIndex = { (id: String) in self.rows.firstIndex { $0.section == id } }
        // Dropped in the empty space under the last row: after the last section (or into it).
        let index = item == nil && index == NSOutlineViewDropOnItemIndex ? rows.count : index
        if drag?.what == .section {
            // Between two headings only.
            if item == nil { return DropTarget(dropRow: nil, childIndex: index, section: nil, insertAt: index) }
            guard let r = item, let i = sectionIndex(r.section) else { return nil }
            let at = r.kind == .section && index == NSOutlineViewDropOnItemIndex ? i : i + 1
            return DropTarget(dropRow: nil, childIndex: at, section: nil, insertAt: at)
        }
        guard let r = item else {
            // Between two sections: into the one above (the first one at the very top).
            guard !rows.isEmpty else { return nil }
            let s = rows[max(min(index, rows.count) - 1, 0)]
            return DropTarget(dropRow: s, childIndex: NSOutlineViewDropOnItemIndex, section: s.section, insertAt: nil)
        }
        guard let s = byKey["s|" + r.section] else { return nil }
        if r.kind == .section && index != NSOutlineViewDropOnItemIndex {
            let links = s.children.filter { $0.kind == .link }.count
            return DropTarget(dropRow: s, childIndex: min(index, links), section: s.section, insertAt: min(index, links))
        }
        return DropTarget(dropRow: s, childIndex: NSOutlineViewDropOnItemIndex, section: s.section, insertAt: nil)
    }

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let drag = Self.drag(from: info.draggingPasteboard)
        if drag == nil && Self.fileURLs(from: info.draggingPasteboard).isEmpty { return [] }
        guard let t = dropTarget(for: drag, proposed: item as? LibraryRow, index: index) else { return [] }
        if t.dropRow !== (item as? LibraryRow) || t.childIndex != index { ov.setDropItem(t.dropRow, dropChildIndex: t.childIndex) }
        guard let drag else {
            let mask = info.draggingSourceOperationMask
            return mask.contains(.link) ? .link : mask.contains(.copy) ? .copy : .generic
        }
        if drag.what != .section, let section = t.section, isNoOp(drag, to: section, at: t.insertAt) { return [] }
        return info.draggingSourceOperationMask == .copy && drag.what != .section ? .copy : .move
    }

    /// A drop that would change nothing: a row dropped back on its own section.
    private func isNoOp(_ drag: LibraryDrag, to section: String, at index: Int?) -> Bool {
        guard drag.section == section else { return false }
        switch drag.what {
        case .item: return index == nil
        case .inside: return !(file.section(section).map { file.isHidden(drag.path ?? "", in: $0) } ?? false)
        case .section: return false
        }
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let drag = Self.drag(from: info.draggingPasteboard)
        guard let t = dropTarget(for: drag, proposed: item as? LibraryRow, index: index) else { return false }
        if let drag {
            if drag.what == .section {
                guard let at = t.insertAt else { return false }
                actions?.editSections { $0.move(section: drag.section, to: at) }
                return true
            }
            guard let section = t.section else { return false }
            let copy = info.draggingSourceOperationMask == .copy
            actions?.editSections { $0.drop(drag, on: section, at: t.insertAt, copy: copy, make: LinkedItem.make) }
            return true
        }
        let urls = Self.fileURLs(from: info.draggingPasteboard)
        guard let section = t.section, !urls.isEmpty else { return false }
        actions?.link(urls, to: section, at: t.insertAt)
        return true
    }

    static func drag(from pb: NSPasteboard) -> LibraryDrag? {
        pb.data(forType: dragType).flatMap { try? JSONDecoder().decode(LibraryDrag.self, from: $0) }
    }

    /// PDFs and folders in a drag from Finder.
    static func fileURLs(from pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { u in
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { return false }
            return dir.boolValue ? !(NSWorkspace.shared.isFilePackage(atPath: u.path)) : u.pathExtension.lowercased() == "pdf"
        }
    }
}

/// The outline itself. Its rows' names are labels until one is renamed.
final class LibraryOutlineView: NSOutlineView {
    /// Called when the page comes on screen (a section waiting to be named starts then).
    var onWindow: () -> Void = {}
    /// The row under the last mouse press.
    var pressedItem: Any?
    /// The one row highlighted under the pointer (-1: none).
    private(set) var hoveredRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self && a.userInfo?["hover"] != nil { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["hover": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea?.userInfo?["hover"] != nil { hover(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea?.userInfo?["hover"] != nil { setHovered(-1) }
    }

    /// Lights the row at `point` (in the outline's coordinates), and only that one.
    func hover(at point: NSPoint) {
        setHovered(visibleRect.contains(point) ? row(at: point) : -1, point: point)
    }

    /// The rows moved under a pointer that stayed put (scrolling, a folder opened or closed, the page redrawn):
    /// light the row now under it.
    func hoverUnderPointer() {
        guard let w = window, w.isVisible, NSApp.isActive else { setHovered(-1); return }
        hover(at: convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func setHovered(_ r: Int, point: NSPoint? = nil) {
        let old = hoveredRow
        hoveredRow = r
        for i in Set([old, r]) where i >= 0 && i < numberOfRows {
            (rowView(atRow: i, makeIfNecessary: false) as? LibraryRowView)?.hovering = i == r
            // A heading's + and ⋯ light up when the pointer is on them.
            if let cell = view(atColumn: 0, row: i, makeIfNecessary: false) as? SectionCell {
                cell.hoverButtons(at: i == r ? point.map { cell.convert($0, from: self) } : nil)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let i = row(at: convert(event.locationInWindow, from: nil))
        pressedItem = i >= 0 ? item(atRow: i) : nil
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setHovered(-1)   // the pointer left while the page was away
        if window != nil { onWindow() }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        // Text fields in the rows only take clicks while a name is being edited.
        if let f = responder as? NSTextField, !f.isEditable { return false }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

// MARK: - rows on screen

/// A row's background: a soft highlight under the pointer, as on the tab bar. The outline decides which row that is
/// (LibraryOutlineView.hoveredRow), so scrolling under a still pointer leaves exactly one row lit.
final class LibraryRowView: NSTableRowView {
    var hoverable = true
    var isSection = false
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, hoverable else { return }
        var r = bounds.insetBy(dx: 4, dy: 0)
        if isSection { r = NSRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 30) }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
    }
}

/// A cell whose name can be edited in place.
protocol EditableCell: NSView {
    var nameField: NSTextField { get }
}

/// A section heading: its name, how many PDFs it lists, + (link) and ⋯ (more).
final class SectionCell: NSTableCellView, EditableCell {
    static let id = NSUserInterfaceItemIdentifier("section")
    let nameField = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    let plus = HoverIconButton()
    let more = HoverIconButton()
    var onPlus: (NSView) -> Void = { _ in }
    var onMore: (NSView) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        nameField.font = .systemFont(ofSize: 15, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.focusRingType = .none
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .tertiaryLabelColor
        for (b, symbol, tip) in [(plus, "plus", "Link a folder or PDFs to this section"), (more, "ellipsis", "Rename or remove this section")] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.toolTip = tip
            b.target = self
        }
        plus.action = #selector(plusClicked)
        more.action = #selector(moreClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [nameField, count, spacer, plus, more])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(4, after: plus)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.heightAnchor.constraint(equalToConstant: 24),
        ])
        textField = nameField
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(name: String, count text: String) {
        nameField.stringValue = name
        nameField.toolTip = name
        count.stringValue = text
        count.isHidden = text.isEmpty
        hoverButtons(at: nil)   // a reused cell keeps nothing lit from the row it showed before
    }

    /// Lights + or ⋯ when `point` (in this cell's coordinates) is over it; nil: neither.
    func hoverButtons(at point: NSPoint?) {
        for b in [plus, more] { b.hovered = point.map { b.frame(in: self).contains($0) } ?? false }
    }

    @objc private func plusClicked() { onPlus(plus) }
    @objc private func moreClicked() { onMore(more) }
}

/// A small icon button with the tab bar's hover look: a soft rounded highlight while the pointer is over it (set by
/// the outline, which tracks the pointer for the whole list) and a darker one while pressed.
final class HoverIconButton: NSButton {
    var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            contentTintColor = hovered ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .secondaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 22), heightAnchor.constraint(equalToConstant: 22)])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isHighlighted ? 0.2 : hovered ? 0.11 : 0
        if fill > 0 {
            NSColor.labelColor.withAlphaComponent(fill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

private extension NSView {
    /// This view's frame in `ancestor`'s coordinates.
    func frame(in ancestor: NSView) -> NSRect { superview.map { ancestor.convert(frame, from: $0) } ?? frame }
}

/// A linked folder or PDF, something inside a linked folder, a hidden file, or the hint in an empty section.
final class ItemCell: NSTableCellView, EditableCell {
    static let id = NSUserInterfaceItemIdentifier("item")
    let nameField = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let note = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        nameField.font = .systemFont(ofSize: 13)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.focusRingType = .none
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, nameField, note, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        textField = nameField
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ r: LibraryRow) {
        nameField.stringValue = r.title
        nameField.textColor = r.missing || r.kind == .hiddenNode ? .tertiaryLabelColor
            : r.kind == .empty || r.kind == .hiddenGroup ? .secondaryLabelColor : .labelColor
        nameField.font = r.kind == .empty ? .systemFont(ofSize: 12) : .systemFont(ofSize: 13)
        nameField.toolTip = r.path ?? r.title
        let symbol: String?
        switch r.kind {
        case .hiddenGroup: symbol = "eye.slash"
        case .empty: symbol = nil
        default: symbol = r.isFolder ? "folder" : "doc.text"
        }
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.contentTintColor = r.isFolder && r.kind != .hiddenNode && !r.missing ? .controlAccentColor : .secondaryLabelColor
        icon.isHidden = symbol == nil
        switch r.kind {
        case .link where r.missing: note.stringValue = "can't be found (moved to another disk or deleted)"
        case .link: note.stringValue = r.isFolder ? "linked folder" : "linked PDF"
        case .hiddenNode: note.stringValue = "hidden"
        default: note.stringValue = ""
        }
        note.isHidden = note.stringValue.isEmpty
    }
}
