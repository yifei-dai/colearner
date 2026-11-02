import Foundation

// MARK: - the sections the user made (sections.json)

/// A heading on the lecture page (the New Tab and the Lectures menu): folders and single PDFs the user linked to it.
/// A section only points at things; nothing on disk moves when sections change.
struct LibrarySection: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var items: [LinkedItem] = []
    /// Files and folders inside this section's linked folders that it doesn't list (dragged to another section, or
    /// hidden by hand). The page shows them under "Hidden", where they can come back.
    var hidden: [String]?
    var collapsed: Bool?
}

/// A folder, PDF or web page linked to a section.
struct LinkedItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case folder, file, web }
    var id: String
    var kind: Kind
    /// Where it was last seen; for a web page, its address.
    var path: String
    /// Finds it again after it is renamed or moved in Finder.
    var bookmark: Data?
    /// Linked folders start open on the page.
    var collapsed: Bool?
    /// A web page's name on the page (its title once it has been open, or what it was renamed to).
    var title: String?

    init(id: String = UUID().uuidString, kind: Kind, path: String, bookmark: Data? = nil, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.bookmark = bookmark
        self.title = title
    }

    /// A new link, with a bookmark to find it again after a rename or move.
    static func make(path: String, kind: Kind) -> LinkedItem {
        LinkedItem(kind: kind, path: path, bookmark: FileTracker.bookmark(for: path))
    }

    private enum CodingKeys: String, CodingKey { case id, kind, path, bookmark, collapsed, title }

    /// A web page is written as a "file" with its address: 0.2, which knows only folders and PDFs, then still reads
    /// sections.json (the link shows there as a file it can't find) instead of setting the file aside.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        let raw = try c.decode(String.self, forKey: .kind)
        guard let k = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(raw)")
        }
        kind = k == .file && WebAddress.isWeb(path) ? .web : k
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind == .web ? Kind.file.rawValue : kind.rawValue, forKey: .kind)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encodeIfPresent(collapsed, forKey: .collapsed)
        try c.encodeIfPresent(title, forKey: .title)
    }
}

/// sections.json: the sections in page order, and which folders inside linked folders are open.
struct SectionsFile: Codable, Equatable {
    var version = 1
    var sections: [LibrarySection] = []
    /// Folders inside linked folders that are open on the page, as "<section id>|<folder path>" (they start closed).
    var expanded: [String]?
}

/// Reads and writes sections.json.
enum SectionsStore {
    /// nil before the first launch with sections (they are then made from library.json). A file that can't be read
    /// (written by a newer version, say) is set aside, never overwritten.
    static func load(from url: URL = AppPaths.sections) -> SectionsFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        if let f = try? JSONDecoder().decode(SectionsFile.self, from: d) { return f }
        let aside = url.deletingLastPathComponent().appendingPathComponent("sections.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        NSLog("Co-learner: could not read sections.json; moved it to \(aside.lastPathComponent)")
        return nil
    }

    static func save(_ f: SectionsFile, to url: URL = AppPaths.sections) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(f) { try? d.write(to: url, options: .atomic) }
    }
}

/// What is dragged on the lecture page: a section, an item linked to one, or a file or folder inside a linked folder.
struct LibraryDrag: Codable, Hashable {
    enum What: String, Codable { case section, item, inside }
    var what: What
    /// The section it comes from (the section itself when dragging a section).
    var section: String
    /// The linked item (`item`).
    var item: String?
    /// The file or folder (`inside`).
    var path: String?
    var kind: LinkedItem.Kind?
}

extension SectionsFile {
    func index(of section: String) -> Int? { sections.firstIndex { $0.id == section } }

    func section(_ id: String) -> LibrarySection? { sections.first { $0.id == id } }

    @discardableResult
    mutating func addSection(named name: String, id: String = UUID().uuidString) -> String {
        sections.append(LibrarySection(id: id, name: name))
        return id
    }

    mutating func rename(section id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = index(of: id) else { return }
        sections[i].name = n
    }

    mutating func remove(section id: String) {
        sections.removeAll { $0.id == id }
        expanded?.removeAll { $0.hasPrefix(id + "|") }
    }

    /// Puts a section at `index`, counted among the sections before the move (a drop between two headings).
    mutating func move(section id: String, to index: Int) {
        guard let from = self.index(of: id) else { return }
        let s = sections.remove(at: from)
        sections.insert(s, at: min(max(from < index ? index - 1 : index, 0), sections.count))
    }

    /// Links folders or PDFs to a section, at `index` among its linked items (the end if nil). A path the section
    /// already lists stays where it is: one hidden inside its folders comes back, one linked already just moves to
    /// `index` when one was given.
    mutating func link(_ items: [LinkedItem], to id: String, at index: Int? = nil) {
        guard let s = self.index(of: id) else { return }
        var at = index.map { min(max($0, 0), sections[s].items.count) }
        for new in items {
            if let i = sections[s].items.firstIndex(where: { $0.path == new.path && $0.kind == new.kind }) {
                if let to = at {
                    let it = sections[s].items.remove(at: i)
                    let dest = i < to ? to - 1 : to
                    sections[s].items.insert(it, at: dest)
                    at = dest + 1
                }
                continue
            }
            if contains(new.path, in: sections[s]) {
                unhide(new.path, in: id)
                continue
            }
            if let to = at {
                sections[s].items.insert(new, at: to)
                at = to + 1
            } else {
                sections[s].items.append(new)
            }
        }
    }

    mutating func unlink(item: String, from section: String) {
        guard let s = index(of: section) else { return }
        sections[s].items.removeAll { $0.id == item }
    }

    /// Renames a web page linked to a section (on the page only; "" goes back to its address).
    mutating func rename(webItem item: String, in section: String, to name: String) {
        guard let s = index(of: section), let i = sections[s].items.firstIndex(where: { $0.id == item && $0.kind == .web }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sections[s].items[i].title = n.isEmpty ? nil : n
    }

    /// Web links to `url` that have no name yet take the page's title.
    mutating func name(webLink url: String, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        for s in sections.indices {
            for i in sections[s].items.indices where sections[s].items[i].kind == .web && sections[s].items[i].path == url
                && sections[s].items[i].title == nil {
                sections[s].items[i].title = String(t.prefix(160))
            }
        }
    }

    /// True if `path` lies inside one of the section's linked folders (listed there or hidden).
    func contains(_ path: String, in section: LibrarySection) -> Bool {
        section.items.contains { $0.kind == .folder && path.hasPrefix($0.path + "/") }
    }

    /// True if `path`, or a folder above it, is hidden in the section.
    func isHidden(_ path: String, in section: LibrarySection) -> Bool {
        (section.hidden ?? []).contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    mutating func hide(_ path: String, in section: String) {
        guard let s = index(of: section), !(sections[s].hidden ?? []).contains(path) else { return }
        sections[s].hidden = (sections[s].hidden ?? []) + [path]
    }

    /// Shows a hidden file or folder again (and anything hidden inside it, so the whole folder comes back).
    mutating func unhide(_ path: String, in section: String) {
        guard let s = index(of: section), var h = sections[s].hidden else { return }
        h.removeAll { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
        sections[s].hidden = h.isEmpty ? nil : h
    }

    /// A drop on section `target`, at `index` among its linked items (nil: at the end). It moves unless `copy`:
    /// a linked item leaves the section it came from, and a file or folder from a linked folder is hidden there.
    /// `make` builds the link for a file or folder that comes from inside a linked folder.
    mutating func drop(_ drag: LibraryDrag, on target: String, at index: Int?, copy: Bool,
                       make: (String, LinkedItem.Kind) -> LinkedItem) {
        guard self.index(of: target) != nil, let source = self.section(drag.section) else { return }
        switch drag.what {
        case .section:
            if let index { move(section: drag.section, to: index) }
        case .item:
            guard let id = drag.item, let item = source.items.first(where: { $0.id == id }) else { return }
            if drag.section == target {
                if let index { link([item], to: target, at: index) }   // reorder
                return
            }
            var linked = item
            linked.id = UUID().uuidString
            link([linked], to: target, at: index)
            if !copy { unlink(item: id, from: drag.section) }
        case .inside:
            guard let path = drag.path, let kind = drag.kind else { return }
            if drag.section == target {
                // Within its own section a hidden file comes back; a listed one already shows.
                unhide(path, in: target)
                return
            }
            link([make(path, kind)], to: target, at: index)
            if !copy { hide(path, in: drag.section) }
        }
    }

    /// Paths follow a rename or move (from Finder or Rename in the app): linked items, hidden entries and open
    /// folders under `old` now live under `new`.
    mutating func move(path old: String, to new: String) {
        func moved(_ p: String) -> String? {
            if p == old { return new }
            if p.hasPrefix(old + "/") { return new + p.dropFirst(old.count) }
            return nil
        }
        for s in sections.indices {
            for i in sections[s].items.indices {
                if let p = moved(sections[s].items[i].path) { sections[s].items[i].path = p }
            }
            if let h = sections[s].hidden { sections[s].hidden = h.map { moved($0) ?? $0 } }
        }
        expanded = expanded?.map { key in
            guard let bar = key.firstIndex(of: "|") else { return key }
            let p = String(key[key.index(after: bar)...])
            return moved(p).map { String(key[...bar]) + $0 } ?? key
        }
    }
}

// MARK: - what the sections show (read from disk)

/// A folder, PDF or web page on the lecture page.
struct LibraryNode: Hashable, Identifiable {
    var path: String
    var isFolder: Bool
    /// A folder's PDFs and the folders below it that hold PDFs: folders first, then files, in Finder's name order.
    var children: [LibraryNode] = []
    /// A web page (`path` is its address).
    var isWeb = false
    /// A web page's name, when it has one.
    var title: String?
    var id: String { path }

    /// The real name: a folder's name, a PDF's file name without ".pdf"; a web page's title, else its address.
    var name: String {
        if isWeb { return title ?? WebAddress.label(path) }
        let u = URL(fileURLWithPath: path)
        return isFolder ? u.lastPathComponent : u.deletingPathExtension().lastPathComponent
    }

    /// Every PDF at or below this node.
    var files: [String] { isWeb ? [] : isFolder ? children.flatMap(\.files) : [path] }
}

/// A linked item as the page shows it; `node` is nil while the folder or PDF can't be found.
struct LinkContents: Hashable, Identifiable {
    var item: LinkedItem
    var node: LibraryNode?
    var id: String { item.id }
}

/// A section as the page shows it.
struct SectionContents: Hashable, Identifiable {
    var section: LibrarySection
    var links: [LinkContents]
    /// Its hidden files and folders that are still there.
    var hidden: [LibraryNode]
    /// A linked folder held more than LibraryScanner.maxEntries entries: only part of it is listed.
    var truncated = false
    var id: String { section.id }

    /// Every PDF the section lists, hidden ones too (they can still be opened).
    var files: [String] { links.compactMap(\.node).flatMap(\.files) + hidden.flatMap(\.files) }
}

enum LibraryScanner {
    /// Folders never listed besides hidden ones and packages: tool folders full of other people's files.
    static let skippedFolders: Set<String> = ["node_modules", "__pycache__", "site-packages"]
    /// The most folder entries one section reads, so linking a huge folder by mistake can't stall the app.
    static let maxEntries = 20_000

    /// What each section lists, and whether macOS refused to read a linked folder.
    static func read(_ file: SectionsFile) -> (sections: [SectionContents], denied: Bool) {
        var denied = false
        let sections = file.sections.map { s in
            var budget = maxEntries
            let isHidden = { (p: String) in file.isHidden(p, in: s) }
            let links = s.items.map { item -> LinkContents in
                switch item.kind {
                case .folder:
                    return LinkContents(item: item, node: folder(URL(fileURLWithPath: item.path), skip: isHidden,
                                                                 budget: &budget, keepEmpty: true, denied: &denied))
                case .file:
                    return LinkContents(item: item, node: isPDF(item.path) ? LibraryNode(path: item.path, isFolder: false) : nil)
                case .web:
                    return LinkContents(item: item, node: LibraryNode(path: item.path, isFolder: false, isWeb: true, title: item.title))
                }
            }
            // Hidden entries that are still inside one of the section's linked folders.
            let hidden = (s.hidden ?? []).filter { file.contains($0, in: s) }.compactMap { p -> LibraryNode? in
                if isPDF(p) { return LibraryNode(path: p, isFolder: false) }
                return folder(URL(fileURLWithPath: p), skip: { _ in false }, budget: &budget, keepEmpty: false, denied: &denied)
            }
            return SectionContents(section: s, links: links, hidden: hidden, truncated: budget <= 0)
        }
        return (sections, denied)
    }

    static func isPDF(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return path.lowercased().hasSuffix(".pdf") && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
    }

    /// A folder with the PDFs and PDF-holding folders below it; nil if it isn't a folder (or, unless `keepEmpty`,
    /// holds no PDF). `skip` leaves out hidden paths; `denied` is set when macOS refuses to read a folder.
    static func folder(_ url: URL, skip: (String) -> Bool, budget: inout Int, keepEmpty: Bool, denied: inout Bool,
                       depth: Int = 0) -> LibraryNode? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory == true, v.isPackage != true else { return nil }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        } catch {
            let e = error as NSError
            if e.code == CocoaError.fileReadNoPermission.rawValue || (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM) {
                denied = true
            }
            return keepEmpty ? LibraryNode(path: url.standardizedFileURL.path, isFolder: true) : nil
        }
        var folders: [LibraryNode] = [], files: [LibraryNode] = []
        for u in items {
            guard budget > 0 else { break }
            budget -= 1
            let path = u.standardizedFileURL.path
            guard !skip(path) else { continue }
            let r = try? u.resourceValues(forKeys: Set(keys))
            if r?.isDirectory == true {
                // No symlinked folders (they can loop) and no app or document packages.
                guard r?.isSymbolicLink != true, r?.isPackage != true, depth < 12,
                      !skippedFolders.contains(u.lastPathComponent) else { continue }
                if let f = folder(u, skip: skip, budget: &budget, keepEmpty: false, denied: &denied, depth: depth + 1) {
                    folders.append(f)
                }
            } else if u.pathExtension.lowercased() == "pdf" {
                files.append(LibraryNode(path: path, isFolder: false))
            }
        }
        if folders.isEmpty && files.isEmpty && !keepEmpty { return nil }
        let byName = { (a: LibraryNode, b: LibraryNode) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return LibraryNode(path: url.standardizedFileURL.path, isFolder: true,
                           children: folders.sorted(by: byName) + files.sorted(by: byName))
    }
}
