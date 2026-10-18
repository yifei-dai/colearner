import Foundation
import CryptoKit

enum Provider: String, Codable, CaseIterable {
    case claude, codex
    var displayName: String { self == .claude ? "Claude" : "ChatGPT" }
}

struct ChatMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    enum Status: String, Codable { case streaming, done, error, stopped }

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
        return d
    }
}

/// One conversation about a whole lecture deck. Each message records the slide it was asked on;
/// each assistant keeps one CLI session for the whole conversation.
struct Conversation: Codable, Identifiable {
    var id: String = UUID().uuidString
    var created: Date = Date()
    var messages: [ChatMessage] = []
    var claudeSession: String?
    var codexSession: String?
    /// provider -> ids of the messages that provider has been shown (its own session, or quoted to it).
    var seenBy: [String: [String]]?
    /// provider -> slides whose image that provider's session has been shown.
    var seenSlides: [String: [Int]]?
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
    var pages: [Int] { Array(Set(messages.compactMap(\.page))).sorted() }
    var isEmpty: Bool { messages.isEmpty }
}

/// v0.1–v0.1.4: one conversation per slide.
struct ChatThread: Codable {
    var page: Int
    var messages: [ChatMessage] = []
    var claudeSession: String?
    var codexSession: String?
    var seenBy: [String: [String]]?
}

struct DeckChats: Codable {
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
    private var decks: [String: DeckChats] = [:]
    /// Decks whose chat file could not be read or set aside: never written this session (nothing is overwritten).
    private var readOnly: Set<String> = []

    private func base(_ deckPath: String) -> String {
        let h = SHA256.hash(data: Data(deckPath.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let name = URL(fileURLWithPath: deckPath).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        return "\(name)-\(h)"
    }
    /// v0.1.5+ chats live in their own file, so an older build (which reads `<base>.json`) never sees them.
    private func fileURL(_ deckPath: String) -> URL { AppPaths.chats.appendingPathComponent(base(deckPath) + ".chat2.json") }
    /// The per-slide chats file of v0.1–v0.1.4 (left as it is, for those versions).
    private func legacyURL(_ deckPath: String) -> URL { AppPaths.chats.appendingPathComponent(base(deckPath) + ".json") }

    private func decode(_ url: URL) -> DeckChats? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(DeckChats.self, from: data)
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
                let candidates = ((try? fm.contentsOfDirectory(atPath: AppPaths.chats.path)) ?? [])
                    .filter { n in prefixes.contains { n.hasPrefix($0) } }
                    .sorted { stamp($0) > stamp($1) }
                for name in candidates {
                    let u = AppPaths.chats.appendingPathComponent(name)
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
            let all = threads.values.flatMap { t in t.messages.map { m -> ChatMessage in var m = m; m.page = t.page; return m } }
            var done = Set(chats.importedV1 ?? []).union((chats.conversations ?? []).flatMap { $0.messages.map(\.id) })
            if chats.importedV1 == nil {   // chat2 written before this was tracked
                let convs = chats.conversations ?? []
                // While the per-slide conversation exists it holds every migrated message, so membership alone is
                // exact. Without it (deleted, or there never were per-slide chats): messages older than every
                // conversation were there at migration; later ones were added by an older build.
                if !convs.contains(where: { $0.legacy == true }) {
                    if let since = convs.map(\.created).min() {
                        done.formUnion(all.filter { $0.createdAt < since }.map(\.id))
                    } else {
                        done.formUnion(all.map(\.id))
                    }
                }
            }
            let fresh = all.filter { !done.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
            if let first = fresh.first {
                var old = Conversation(legacy: true)
                old.messages = fresh
                old.created = first.createdAt
                chats.conversations = (chats.conversations ?? []) + [old]
            }
            let ids = done.union(fresh.map(\.id))
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
        // A crash or quit mid-answer leaves "streaming" messages behind; close them.
        for ci in (chats.conversations ?? []).indices {
            for mi in chats.conversations![ci].messages.indices where chats.conversations![ci].messages[mi].status == .streaming {
                chats.conversations![ci].messages[mi].status = .stopped
                chats.conversations![ci].messages[mi].activity = nil
            }
        }
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

    /// The conversation shown for this deck.
    func current(_ deckPath: String) -> Conversation {
        let c = load(deckPath)
        return c.conversations?.first { $0.id == c.current } ?? Conversation()
    }

    func conversation(_ deckPath: String, _ id: String) -> Conversation? {
        load(deckPath).conversations?.first { $0.id == id }
    }

    /// All conversations of a deck, newest first.
    func conversations(_ deckPath: String) -> [Conversation] {
        (load(deckPath).conversations ?? []).sorted { $0.created > $1.created }
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
}
