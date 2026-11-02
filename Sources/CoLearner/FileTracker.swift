import Foundation
import CoreServices

/// One rename or move: something Co-learner keeps by path now lives at `new` (a PDF, or a folder with everything
/// under it).
struct PathMove: Codable, Hashable {
    var old: String
    var new: String

    /// `p` after this move (nil if the move doesn't touch it).
    func apply(_ p: String) -> String? {
        if p == old { return new }
        if p.hasPrefix(old + "/") { return new + p.dropFirst(old.count) }
        return nil
    }

    /// The slide each deck was on, the open tabs and the deck on screen follow their PDFs (`follow` gives a deck's
    /// new path). A slide already saved under the new path is kept.
    static func moveDefaults(in defaults: UserDefaults, _ follow: (String) -> String) {
        // In two steps, so a swap or a chain (a -> b while b -> c) doesn't lose a slide.
        var moving: [(to: String, page: Int)] = []
        var vacated = Set<String>()
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("lastPage.") {
            let p = String(key.dropFirst("lastPage.".count))
            let n = follow(p)
            guard n != p else { continue }
            moving.append(("lastPage." + n, defaults.integer(forKey: key)))
            vacated.insert(key)
        }
        vacated.forEach(defaults.removeObject(forKey:))
        for m in moving where defaults.object(forKey: m.to) == nil || vacated.contains(m.to) { defaults.set(m.page, forKey: m.to) }
        if let open = defaults.stringArray(forKey: "openDecks") {
            var seen = Set<String>()
            defaults.set(open.map(follow).filter { seen.insert($0).inserted }, forKey: "openDecks")
        }
        if let cur = defaults.string(forKey: "currentDeck") { defaults.set(follow(cur), forKey: "currentDeck") }
    }
}

/// The PDFs the lecture page has listed, so one renamed or moved in Finder (or inside a linked folder that was
/// renamed or moved) is found again and keeps its chats, links, slide and tab (files.json). A PDF is the same file
/// when its inode and size are: that survives renames and moves on the same disk, also when only the capitals
/// change. A PDF that left the linked folders is found by its bookmark.
@MainActor
final class FileTracker {
    private struct Entry: Codable {
        var bookmark: Data?
        var inode: UInt64?
        var size: Int64?
        /// When it was last looked for and not found (forgotten after 60 days).
        var missingSince: Date?
    }

    private struct Saved: Codable {
        var files: [String: Entry] = [:]
        /// A PDF's path -> the path library.json knows it by (where it was when first listed).
        var aliases: [String: String]?
    }

    private var saved: Saved
    private let url: URL

    init(url: URL = AppPaths.trackedFiles) {
        self.url = url
        saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    var aliases: [String: String] { saved.aliases ?? [:] }

    /// Linked folders and PDFs renamed or moved since they were last seen (by their bookmarks, or a change of capitals
    /// only): their new paths and fresh bookmarks go into `sections`, and the moves are returned so that what the
    /// sections keep under them (hidden files, open folders) follows. The PDFs' own state follows file by file
    /// (followFiles), once the folders are read at their new place.
    func followLinks(_ sections: inout SectionsFile) -> [PathMove] {
        var moves: [PathMove] = []
        for s in sections.sections.indices {
            for i in sections.sections[s].items.indices {
                let item = sections.sections[s].items[i]
                let found: (path: String, bookmark: Data)?
                if FileRevision.read(item.path) != nil {
                    if let spelled = Self.spelledOnDisk(item.path), spelled != item.path {
                        found = (spelled, Self.bookmark(for: spelled) ?? item.bookmark ?? Data())
                    } else {
                        if item.bookmark == nil { sections.sections[s].items[i].bookmark = Self.bookmark(for: item.path) }
                        continue
                    }
                } else {
                    found = Self.resolve(item.bookmark)
                }
                guard let found, found.path != item.path else { continue }
                moves.append(PathMove(old: item.path, new: found.path))
                sections.sections[s].items[i].path = found.path
                sections.sections[s].items[i].bookmark = found.bookmark.isEmpty ? nil : found.bookmark
            }
        }
        return Self.unique(moves)
    }

    /// `path` with its last part spelled as on disk, when that differs only in capitals (on a disk that ignores
    /// them, the old spelling still opens).
    nonisolated static func spelledOnDisk(_ path: String) -> String? {
        let u = URL(fileURLWithPath: path)
        let name = u.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: u.deletingLastPathComponent().path),
              !names.contains(name),
              let real = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return u.deletingLastPathComponent().appendingPathComponent(real).path
    }

    /// Listed PDFs that were renamed or moved: the same file (inode and size) listed under another path, or, for one
    /// that left the linked folders, wherever its bookmark leads. These `files` moves carry each deck's state.
    /// A folder whose tracked PDFs all moved into one new folder under the same names counts as moved too: those
    /// `folders` moves are only for what the sections keep inside it (hidden files, open subfolders).
    func followFiles(listed: [String]) -> (files: [PathMove], folders: [PathMove]) {
        let here = Set(listed)
        var byInode: [UInt64: [(path: String, size: Int64)]]?
        func listedFile(_ inode: UInt64) -> [(path: String, size: Int64)] {
            if byInode == nil {
                var m: [UInt64: [(path: String, size: Int64)]] = [:]
                for p in listed { if let r = FileRevision.read(p) { m[r.inode, default: []].append((p, r.size)) } }
                byInode = m
            }
            return byInode?[inode] ?? []
        }
        var moves: [PathMove] = []
        var changed = false
        for (path, e) in saved.files.sorted(by: { $0.key < $1.key }) {
            let now = FileRevision.read(path)
            let same = now.map { r in e.inode == nil || (r.inode == e.inode && (e.size == nil || r.size == e.size)) } ?? false
            if same && here.contains(path) { continue }
            if let inode = e.inode,
               let to = listedFile(inode).first(where: { $0.path != path && (e.size == nil || $0.size == e.size) }) {
                moves.append(PathMove(old: path, new: to.path))
                continue
            }
            if now == nil, let found = Self.resolve(e.bookmark), found.path != path, found.path.lowercased().hasSuffix(".pdf"),
               e.inode == nil || FileRevision.read(found.path)?.inode == e.inode {
                moves.append(PathMove(old: path, new: found.path))
                continue
            }
            if now == nil {
                if let since = e.missingSince {
                    if Date().timeIntervalSince(since) > 60 * 24 * 3600 { saved.files[path] = nil; changed = true }
                } else {
                    saved.files[path]?.missingSince = Date()
                    changed = true
                }
            } else if !same {
                // Rewritten in place (a new download, a safe save): still this deck, now this file.
                saved.files[path]?.inode = now?.inode
                saved.files[path]?.size = now?.size
                changed = true
            }
        }
        if changed { save() }
        moves = Self.unique(moves)
        // A folder renamed or moved with its PDFs: every tracked PDF that was in it went to one new folder, same names.
        var folders: [PathMove] = []
        let fm = FileManager.default
        let byOld = Dictionary(moves.map { ($0.old, $0.new) }, uniquingKeysWith: { a, _ in a })
        var candidates: [String: String] = [:]
        for m in moves {
            let a = URL(fileURLWithPath: m.old), b = URL(fileURLWithPath: m.new)
            let (from, to) = (a.deletingLastPathComponent().path, b.deletingLastPathComponent().path)
            guard a.lastPathComponent == b.lastPathComponent, from != to, candidates[from] == nil,
                  !fm.fileExists(atPath: from), fm.fileExists(atPath: to) else { continue }
            candidates[from] = to
        }
        for (from, to) in candidates {
            let inside = saved.files.keys.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == from }
            let all = inside.allSatisfy { p in byOld[p] == to + "/" + URL(fileURLWithPath: p).lastPathComponent }
            if all { folders.append(PathMove(old: from, new: to)) }
        }
        return (moves, folders.sorted { $0.old.count > $1.old.count })
    }

    /// Starts tracking PDFs listed for the first time.
    func register(_ paths: [String]) {
        var changed = false
        for p in paths {
            if saved.files[p] == nil {
                let r = FileRevision.read(p)
                saved.files[p] = Entry(bookmark: Self.bookmark(for: p), inode: r?.inode, size: r?.size)
                changed = true
            } else if saved.files[p]?.missingSince != nil {
                saved.files[p]?.missingSince = nil
                changed = true
            }
        }
        if changed { save() }
    }

    /// Records moves (found above, or a rename in the app): tracked PDFs, and the names library.json knows them by,
    /// go along.
    func moved(_ moves: [PathMove]) {
        for m in moves {
            var files = saved.files
            var aliases = saved.aliases ?? [:]
            for (p, e) in saved.files {
                guard let n = m.apply(p) else { continue }
                files[p] = nil
                let r = FileRevision.read(n)
                files[n] = Entry(bookmark: Self.bookmark(for: n) ?? e.bookmark, inode: r?.inode ?? e.inode, size: r?.size ?? e.size)
                aliases[n] = aliases.removeValue(forKey: p) ?? p
            }
            saved.files = files
            saved.aliases = aliases.isEmpty ? nil : aliases
        }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(saved) { try? d.write(to: url, options: .atomic) }
    }

    private static func unique(_ moves: [PathMove]) -> [PathMove] {
        var seen = Set<PathMove>()
        return moves.filter { $0.old != $0.new && seen.insert($0).inserted }
    }

    // MARK: bookmarks

    nonisolated static func bookmark(for path: String) -> Data? {
        try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where a bookmark leads now (with a fresh bookmark when it was stale); nil if nowhere, or only to the Trash.
    nonisolated static func resolve(_ bookmark: Data?) -> (path: String, bookmark: Data)? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let p = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: p), !p.contains("/.Trash/"), !p.contains("/.Trashes/") else { return nil }
        return (p, stale ? (Self.bookmark(for: p) ?? bookmark) : bookmark)
    }
}

/// Watches the linked folders, and the folders that hold linked PDFs, and calls `changed` (on the main thread, at
/// most a few times a second) when a PDF or folder in them is added, removed or renamed.
@MainActor
final class LibraryWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private var pending = false
    private let changed: () -> Void

    init(_ changed: @escaping () -> Void) { self.changed = changed }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    func watch(_ sections: SectionsFile) {
        let want = Set(sections.sections.flatMap { s in
            s.items.map { $0.kind == .folder ? $0.path : URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
        }).sorted()
        guard want != paths else { return }
        stop()
        paths = want
        guard !want.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            var relevant = false
            for i in 0..<min(count, paths.count) {
                if LibraryWatcher.matters(paths[i], flags: eventFlags[i]) { relevant = true; break }
            }
            guard relevant else { return }
            let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.fire() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, want as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// A PDF or folder came, went or was renamed (not Finder's .DS_Store and other hidden files).
    nonisolated static func matters(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        let f = Int(flags)
        if f & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs) != 0 { return true }
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return f & kFSEventStreamEventFlagItemIsDir != 0 || name.lowercased().hasSuffix(".pdf")
    }

    private func fire() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.changed()
            }
        }
    }
}
