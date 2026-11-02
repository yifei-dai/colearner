import Foundation

enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex
    var displayName: String { self == .claude ? "Claude" : "ChatGPT" }
}

struct ChatMessage: Codable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Status: String, Codable, Sendable { case streaming, done, error, stopped }

    var id: String = UUID().uuidString
    var role: Role
    var provider: Provider?
    var text: String
    /// Short label shown instead of `text` for quick actions ("Explain this slide").
    var display: String?
    var status: Status = .done
    var error: String?
    var activity: String?
    var model: String?
    var createdAt: Date = Date()
    /// The slide the user was on when this was asked (answers carry their question's slide).
    var page: Int?
    /// Small preview (data URL) of an area of the slide the question was about.
    var areaThumb: String?
    /// An answer stopped or cut off before it reached its assistant's session: quoted back to it once.
    var notInSession: Bool?
    /// Screenshots and other pictures that went with the question.
    var images: [MessageImage]?
    /// Text quoted from the deck's walkthrough page or notes that went with the question.
    var quote: ChatQuote?
    /// The answer failed because the assistant's login expired (the chat offers "Sign in").
    var needsSignIn: Bool?

    /// The dictionary handed to chat.js.
    var js: [String: Any] {
        var d: [String: Any] = ["id": id, "role": role.rawValue, "text": text, "status": status.rawValue]
        if let provider { d["provider"] = provider.rawValue }
        if let display { d["display"] = display }
        if let error { d["error"] = error }
        if let activity { d["activity"] = activity }
        if let model { d["model"] = model }
        if let page { d["page"] = page }
        if let areaThumb { d["areaThumb"] = areaThumb }
        if let images, !images.isEmpty { d["images"] = images.map { ["label": $0.label, "thumb": $0.thumb] } }
        if let quote { d["quote"] = quote.js }
        if needsSignIn == true { d["needsSignIn"] = true }
        return d
    }
}

/// A picture that went with a question: its label and a small preview (data URL).
struct MessageImage: Codable, Equatable, Sendable {
    var label: String
    var thumb: String
}

/// Text the student quoted: from the deck's walkthrough page or notes PDF ("Ask" in the Walkthrough tab), or part of an
/// earlier answer ("Reply" in the chat).
struct ChatQuote: Codable, Equatable, Sendable {
    static let maxText = 8_000

    var id: String = UUID().uuidString
    /// The study page ("Lecture 3 Walkthrough", "L03_notes"), or whose answer ("Claude’s answer").
    var source: String
    /// Where on it: "Topic 2 › Rotation matrices", "page 7", "slide 5".
    var section: String?
    var text: String
    /// "selection" (text selected on a walkthrough page), "section" (the section being read), "notes" (text
    /// selected in a notes PDF) or "reply" (part of an answer in the chat).
    var kind: String = "selection"
    /// For "reply": the assistant whose answer it is.
    var provider: Provider?

    var js: [String: Any] {
        var d: [String: Any] = ["id": id, "source": source, "text": text, "kind": kind]
        if let section { d["section"] = section }
        return d
    }
}

/// One conversation about a whole lecture deck. Each message records the slide it was asked on;
/// each assistant keeps one CLI session for the whole conversation.
struct Conversation: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var created: Date = Date()
    var messages: [ChatMessage] = []
    var claudeSession: String?
    var codexSession: String?
    /// provider -> ids of the messages that provider has been shown (its own session, or quoted to it).
    var seenBy: [String: [String]]?
    /// provider -> slides whose image that provider's session has been shown.
    var seenSlides: [String: [Int]]?
    /// The source version used to start each provider's session. Missing in older chat files.
    var contextRevisions: [String: String]?
    /// Migrated from the per-slide chats of v0.1–v0.1.4 (no sessions to resume).
    var legacy: Bool?

    func session(for p: Provider) -> String? { p == .claude ? claudeSession : codexSession }
    mutating func setSession(_ s: String?, for p: Provider) {
        if p == .claude { claudeSession = s } else { codexSession = s }
        if s == nil {   // a fresh session has seen nothing
            seenBy?[p.rawValue] = nil
            seenSlides?[p.rawValue] = nil
        }
    }
    /// The same sources under a new stamp: keep the session, take the stamp.
    mutating func restamp(_ revision: String, for provider: Provider) {
        var revisions = contextRevisions ?? [:]
        revisions[provider.rawValue] = revision
        contextRevisions = revisions
    }
    /// Preserve the visible conversation, but rebuild a provider's context when its sources change.
    @discardableResult
    mutating func prepareContext(_ revision: String, for provider: Provider) -> Bool {
        guard contextRevisions?[provider.rawValue] != revision else { return false }
        setSession(nil, for: provider)
        var revisions = contextRevisions ?? [:]
        revisions[provider.rawValue] = revision
        contextRevisions = revisions
        return true
    }
    var pages: [Int] { Array(Set(messages.compactMap(\.page))).sorted() }
    var isEmpty: Bool { messages.isEmpty }
}

/// v0.1–v0.1.4: one conversation per slide.
struct ChatThread: Codable, Sendable {
    var page: Int
    var messages: [ChatMessage] = []
    var claudeSession: String?
    var codexSession: String?
    var seenBy: [String: [String]]?
}

struct DeckChats: Codable, Sendable {
    var deckPath: String
    var conversations: [Conversation]?
    var current: String?
    /// v1 per-slide threads, read once and migrated.
    var threads: [String: ChatThread]?
    /// Ids of the v1 per-slide messages already brought in (so ones an older build adds later are brought in
    /// too, once, and deleted chats don't come back).
    var importedV1: [String]?
}

/// Loads and saves chats, one JSON file per deck in Application Support.
@MainActor
final class ChatStore {
    private let directory: URL
    private var decks: [String: DeckChats] = [:]
    /// Decks whose chat file could not be read or set aside: never written this session (nothing is overwritten).
    private var readOnly: Set<String> = []

    init(directory: URL = AppPaths.chats) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func base(_ deckPath: String) -> String {
        ChatArchiveFile.base(deckPath)
    }
    /// v0.1.5+ chats live in their own file, so an older build (which reads `<base>.json`) never sees them.
    private func fileURL(_ deckPath: String) -> URL { directory.appendingPathComponent(base(deckPath) + ".chat2.json") }
    /// The per-slide chats file of v0.1–v0.1.4 (left as it is, for those versions).
    private func legacyURL(_ deckPath: String) -> URL { directory.appendingPathComponent(base(deckPath) + ".json") }

    private func decode(_ url: URL) -> DeckChats? {
        ChatArchiveFile.decode(url)
    }

    private func load(_ deckPath: String) -> DeckChats {
        if let d = decks[deckPath] { return d }
        let fm = FileManager.default
        let url = fileURL(deckPath), legacy = legacyURL(deckPath)
        var chats = DeckChats(deckPath: deckPath)
        var writeNow = false   // new-format chats found under an old name: write them to the new file at once
        var haveNew = false
        if fm.fileExists(atPath: url.path) {
            if let c = decode(url) {
                chats = c
                haveNew = true
            } else {
                // Never overwrite a chat file we can't read (e.g. written by a newer version): set it aside,
                // then fall back to the older chats below. If it can't be moved, this deck is not saved this session.
                let stamp = Int(Date().timeIntervalSince1970)
                var moved = false
                for suffix in ["", "-" + UUID().uuidString.prefix(8).lowercased()] where !moved {
                    let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp)\(suffix).json")
                    moved = (try? fm.moveItem(at: url, to: aside)) != nil
                    if moved { NSLog("Co-learner: could not read \(url.path); moved it to \(aside.lastPathComponent)") }
                }
                if !moved {
                    readOnly.insert(deckPath)
                    NSLog("Co-learner: could not read or move \(url.path); chats for this deck won't be saved this session")
                }
            }
        }
        // Conversations an older build set aside as unreadable (or set aside above) that this build can read.
        var recovered: [Conversation] = []
        var recoveredCurrent: String?
        var consumed: [URL] = []
        if !haveNew {
            if let c = decode(legacy) {
                chats = c
                if c.conversations != nil { writeNow = true }
            }
            if chats.conversations == nil {
                // Newest first; merged with whatever the per-slide file holds (nothing is left behind).
                let prefixes = [base(deckPath) + ".unreadable-", base(deckPath) + ".chat2.unreadable-"]
                func stamp(_ n: String) -> Int {
                    guard let r = n.range(of: "unreadable-") else { return 0 }
                    return Int(n[r.upperBound...].prefix { $0.isNumber }) ?? 0
                }
                let candidates = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
                    .filter { n in prefixes.contains { n.hasPrefix($0) } }
                    .sorted { a, b in stamp(a) == stamp(b) ? a < b : stamp(a) > stamp(b) }
                for name in candidates {
                    let u = directory.appendingPathComponent(name)
                    guard let c = decode(u), let convs = c.conversations else { continue }
                    for cv in convs where !recovered.contains(where: { $0.id == cv.id }) { recovered.append(cv) }
                    if recoveredCurrent == nil { recoveredCurrent = c.current }
                    consumed.append(u)
                }
            }
        }
        if !haveNew {
            chats.importedV1 = (chats.threads ?? [:]).values.flatMap { $0.messages.map(\.id) }
        }
        var needSave = false
        if haveNew, let v1 = decode(legacy), v1.conversations == nil, let threads = v1.threads {
            // An older build may have added per-slide chats to <base>.json since: bring in the new ones.
            let imported = ChatSearch.legacyImport(threads, into: chats)
            let fresh = imported.messages
            if let first = fresh.first {
                var old = Conversation(legacy: true)
                old.messages = fresh
                old.created = first.createdAt
                chats.conversations = (chats.conversations ?? []) + [old]
            }
            let ids = imported.ids
            if chats.importedV1.map(Set.init) != ids {
                chats.importedV1 = Array(ids)
                needSave = true
            }
        }
        if chats.conversations == nil, let threads = chats.threads, threads.values.contains(where: { !$0.messages.isEmpty }) {
            // v1 -> v2: gather the per-slide chats into one conversation (the v1 file stays untouched).
            var old = Conversation(legacy: true)
            old.messages = threads.values
                .flatMap { t in t.messages.map { m -> ChatMessage in var m = m; m.page = t.page; return m } }
                .sorted { $0.createdAt < $1.createdAt }
            old.created = old.messages.first?.createdAt ?? Date()
            chats.conversations = [old]
            chats.current = old.id
        }
        if !recovered.isEmpty {
            // Messages already in a recovered conversation are not repeated in the migrated per-slide one.
            let seen = Set(recovered.flatMap { $0.messages.map(\.id) })
            let rest = (chats.conversations ?? []).compactMap { c -> Conversation? in
                var c = c
                c.messages.removeAll { seen.contains($0.id) }
                return c.messages.isEmpty ? nil : c
            }
            chats.conversations = recovered + rest
            if chats.current == nil || !(chats.conversations ?? []).contains(where: { $0.id == chats.current }) {
                chats.current = recoveredCurrent
            }
            writeNow = true
        }
        chats.threads = nil
        if Self.repairInterrupted(&chats) { needSave = true }
        if (chats.conversations ?? []).isEmpty {
            let c = Conversation()
            chats.conversations = [c]
            chats.current = c.id
        }
        if chats.current == nil || !(chats.conversations ?? []).contains(where: { $0.id == chats.current }) {
            chats.current = chats.conversations?.last?.id
        }
        decks[deckPath] = chats
        if writeNow, save(deckPath) {
            // A v0.1.5 test build wrote the new format under the old name: once it is safe in the new file,
            // give the old name back its old content (kept as .v1.json) so an older build keeps working.
            let backup = legacy.deletingPathExtension().appendingPathExtension("v1.json")
            if fm.fileExists(atPath: backup.path),
               !fm.fileExists(atPath: legacy.path) || decode(legacy)?.conversations != nil {
                try? fm.removeItem(at: legacy)
                try? fm.copyItem(at: backup, to: legacy)
                // Those per-slide chats were part of what the test build migrated: don't bring them in again.
                if let v1 = decode(backup)?.threads {
                    var c = decks[deckPath] ?? chats
                    c.importedV1 = Array(Set(c.importedV1 ?? []).union(v1.values.flatMap { $0.messages.map(\.id) }))
                    decks[deckPath] = c
                    chats = c
                    save(deckPath)
                }
            }
            // Recovered files are now in the chat file: rename them so they are merged only once (and chats
            // deleted later don't come back).
            for u in consumed {
                let done = u.lastPathComponent.replacingOccurrences(of: "unreadable-", with: "recovered-")
                try? fm.moveItem(at: u, to: u.deletingLastPathComponent().appendingPathComponent(done))
            }
        } else if needSave {
            save(deckPath)
        }
        return chats
    }

    /// A crash can leave optimistic seen markers for a turn the CLI never received. Its session cannot safely
    /// resume: rebuild only the affected provider, keeping the visible transcript. True if anything changed.
    private static func repairInterrupted(_ chats: inout DeckChats) -> Bool {
        var changed = false
        for ci in (chats.conversations ?? []).indices {
            for mi in chats.conversations![ci].messages.indices where chats.conversations![ci].messages[mi].status == .streaming {
                let provider = chats.conversations![ci].messages[mi].provider
                chats.conversations![ci].messages[mi].status = .stopped
                chats.conversations![ci].messages[mi].activity = nil
                if !chats.conversations![ci].messages[mi].text.isEmpty {
                    chats.conversations![ci].messages[mi].notInSession = true
                }
                for p in provider.map({ [$0] }) ?? Provider.allCases {
                    chats.conversations![ci].setSession(nil, for: p)
                }
                changed = true
            }
        }
        return changed
    }

    /// The conversation shown for this deck.
    func current(_ deckPath: String) -> Conversation {
        let c = load(deckPath)
        return c.conversations?.first { $0.id == c.current } ?? Conversation()
    }

    func conversation(_ deckPath: String, _ id: String) -> Conversation? {
        return load(deckPath).conversations?.first { $0.id == id }
    }

    /// All conversations of a deck, newest first.
    func conversations(_ deckPath: String) -> [Conversation] {
        return (load(deckPath).conversations ?? []).sorted { $0.created > $1.created }
    }

    /// Search does not load/migrate histories. Active in-memory histories override their disk snapshots.
    func search(query: String) async -> [ChatSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let directory = directory, cached = decks
        let task = Task.detached(priority: .utility) {
            ChatSearch.find(directory: directory, cached: cached, query: query)
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Resolve by message ID after opening a search result. Unmigrated legacy chats do not yet have a
    /// persistent conversation ID; loading them here is intentional, after the user chose a result.
    func locateMessage(deckPath: String, messageID: String) -> Conversation? {
        return load(deckPath).conversations?.first { $0.messages.contains { $0.id == messageID } }
    }

    /// Slides that have messages in the current conversation (thumbnail dots, "other slides" chips).
    func pagesWithChats(_ deckPath: String) -> [Int] { current(deckPath).pages }

    func update(_ deckPath: String, _ convID: String, _ body: (inout Conversation) -> Void) {
        var chats = load(deckPath)
        guard let i = chats.conversations?.firstIndex(where: { $0.id == convID }) else { return }
        body(&chats.conversations![i])
        decks[deckPath] = chats
    }

    /// Start a fresh conversation for the deck (the old one stays in History). Reuses an empty current one.
    @discardableResult
    func startNew(_ deckPath: String) -> Conversation {
        var chats = load(deckPath)
        if let cur = chats.conversations?.first(where: { $0.id == chats.current }), cur.isEmpty, cur.legacy != true { return cur }
        let c = Conversation()
        chats.conversations = (chats.conversations ?? []).filter { !$0.isEmpty || $0.legacy == true } + [c]
        chats.current = c.id
        decks[deckPath] = chats
        save(deckPath)
        return c
    }

    func setCurrent(_ deckPath: String, _ id: String) {
        var chats = load(deckPath)
        guard chats.conversations?.contains(where: { $0.id == id }) == true else { return }
        chats.current = id
        decks[deckPath] = chats
        save(deckPath)
    }

    func delete(_ deckPath: String, _ id: String) {
        var chats = load(deckPath)
        chats.conversations?.removeAll { $0.id == id }
        if (chats.conversations ?? []).isEmpty { chats.conversations = [Conversation()] }
        if chats.current == id || chats.current == nil {
            chats.current = chats.conversations?.max { $0.created < $1.created }?.id
        }
        decks[deckPath] = chats
        save(deckPath)
    }

    /// Writes the deck's chats; false if nothing was written (read-only this session, or the write failed).
    @discardableResult
    func save(_ deckPath: String) -> Bool {
        guard !readOnly.contains(deckPath), var chats = decks[deckPath] else { return false }
        chats.threads = nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(chats) else { return false }
        return (try? d.write(to: fileURL(deckPath), options: .atomic)) != nil
    }
    // MARK: renamed or moved PDFs

    /// A deck's PDF was renamed or moved (or a folder above it): its chats go to the new path. Every file of the deck
    /// takes the new name and the deck path inside is patched. If the new path already had chats (a PDF put where
    /// another one was), both lists of conversations end up in one file and nothing is dropped; the moving deck's
    /// old files are kept aside.
    func move(_ m: PathMove) {
        var pairs: [(old: String, new: String)] = []
        for p in decks.keys.sorted() { if let n = m.apply(p), n != p { pairs.append((p, n)) } }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() {
            guard let p = mainFileDeck(name), let n = m.apply(p), n != p, !pairs.contains(where: { $0.old == p }) else { continue }
            pairs.append((p, n))
        }
        for (p, n) in pairs { moveDeck(p, to: n) }
    }

    /// The deck a deck's own chat file (`<base>.chat2.json`, or the v1 `<base>.json`) belongs to; nil for any other file.
    private func mainFileDeck(_ name: String) -> String? {
        guard name.hasSuffix(".json"), let p = Self.deckPath(in: directory.appendingPathComponent(name)) else { return nil }
        return name == base(p) + ".chat2.json" || name == base(p) + ".json" ? p : nil
    }

    private func moveDeck(_ p: String, to n: String) {
        let fm = FileManager.default
        let source = decks.removeValue(forKey: p), target = decks[n]
        let wasReadOnly = readOnly.remove(p) != nil
        let from = base(p), to = base(n)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let mine = names.filter { $0.hasPrefix(from + ".") }
        let theirs = names.filter { $0.hasPrefix(to + ".") }
        if theirs.isEmpty && target == nil {
            // The usual case, nothing at the new path yet: the deck's files take the new name.
            for f in mine {
                let dst = directory.appendingPathComponent(to + f.dropFirst(from.count))
                guard (try? fm.moveItem(at: directory.appendingPathComponent(f), to: dst)) != nil else { continue }
                Self.setDeckPath(n, in: dst)
            }
            if wasReadOnly { readOnly.insert(n) }
            if var c = source {
                // In memory it may be newer than on disk (an answer still streaming): it stays, under the new path.
                c.deckPath = n
                decks[n] = c
                save(n)
            }
            return
        }
        // Chats at both paths: one list of conversations under the new path.
        var a = source ?? decode(fileURL(p))
        var b = target ?? decode(fileURL(n))
        let targetUnreadable = target == nil && fm.fileExists(atPath: fileURL(n).path) && b == nil
        let stamp = Int(Date().timeIntervalSince1970)
        func setAside(_ files: [String]) {
            for f in files {
                try? fm.moveItem(at: directory.appendingPathComponent(f), to: directory.appendingPathComponent(f + ".moved-\(stamp)"))
            }
        }
        guard !wasReadOnly, !targetUnreadable, a != nil else {
            // One side can't be read: nothing is merged or overwritten; the moving deck's files are kept aside.
            setAside(mine)
            return
        }
        if source == nil, a != nil { _ = Self.repairInterrupted(&a!) }
        if target == nil, b != nil { _ = Self.repairInterrupted(&b!) }
        let merged = b.map { Self.merged(a!, onto: $0, at: n) } ?? { var c = a!; c.deckPath = n; return c }()
        guard let data = try? Self.encoder.encode(merged), (try? data.write(to: fileURL(n), options: .atomic)) != nil else {
            if let source { decks[p] = source }   // nothing changed on disk: keep it where it was
            if wasReadOnly { readOnly.insert(p) }
            return
        }
        setAside(mine)
        if source != nil || target != nil { decks[n] = merged }
    }

    /// `s`'s chats moved onto `t`'s path `n`: every conversation with messages from both, `s`'s current one if it
    /// has messages (else `t`'s).
    private static func merged(_ s: DeckChats, onto t: DeckChats, at n: String) -> DeckChats {
        var out = s
        out.deckPath = n
        let mine = (s.conversations ?? []).filter { !$0.isEmpty }
        let ids = Set(mine.map(\.id))
        let all = mine + (t.conversations ?? []).filter { !$0.isEmpty && !ids.contains($0.id) }
        out.conversations = all.isEmpty ? s.conversations : all
        let list = out.conversations ?? []
        if !list.contains(where: { $0.id == out.current }) {
            out.current = list.contains(where: { $0.id == t.current }) ? t.current : list.last?.id
        }
        if s.importedV1 != nil || t.importedV1 != nil {
            out.importedV1 = Array(Set(s.importedV1 ?? []).union(t.importedV1 ?? [])).sorted()
        }
        return out
    }

    private static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    /// The deck path a chat file (either format) was written for.
    private static func deckPath(in url: URL) -> String? {
        guard let d = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o["deckPath"] as? String
    }

    /// Changes only the deck path in a chat file, leaving everything else as it was written.
    private static func setDeckPath(_ path: String, in url: URL) {
        guard let d = try? Data(contentsOf: url),
              var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["deckPath"] is String else { return }
        o["deckPath"] = path
        if let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
    }
}

