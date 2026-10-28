import Foundation
import CryptoKit

struct ChatSearchResult: Identifiable, Sendable {
    var deckPath: String
    /// Nil until a legacy per-slide chat is migrated. Resolve all hits by messageID when opening them.
    var conversationID: String?
    var messageID: String
    var page: Int?
    var role: ChatMessage.Role
    var provider: Provider?
    var createdAt: Date
    var snippet: String

    var id: String { deckPath + "\u{0}" + messageID }
}

/// Shared file naming and decoding keep search read-only while using the same formats as ChatStore.
enum ChatArchiveFile {
    static func base(_ deckPath: String) -> String {
        let h = SHA256.hash(data: Data(deckPath.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let name = URL(fileURLWithPath: deckPath).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        return "\(name)-\(h)"
    }

    static func decode(_ url: URL) -> DeckChats? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DeckChats.self, from: data)
    }
}

enum ChatSearch {
    private struct Entry {
        var conversationID: String?
        var message: ChatMessage
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func find(directory: URL, cached: [String: DeckChats], query: String, limit: Int = 100) -> [ChatSearchResult] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty, limit > 0 else { return [] }
        var files: [String: [String: DeckChats]] = [:]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        for name in names where name.hasSuffix(".json") {
            if Task.isCancelled { return [] }
            guard let chats = ChatArchiveFile.decode(directory.appendingPathComponent(name)), cached[chats.deckPath] == nil else { continue }
            let base = ChatArchiveFile.base(chats.deckPath)
            // Only canonical files and pending unreadable-* recovery archives qualify. Consumed
            // recovered-* and .v1 backups stay excluded so deleted chats cannot reappear.
            guard name == base + ".json" || name == base + ".chat2.json"
                    || name.hasPrefix(base + ".unreadable-") || name.hasPrefix(base + ".chat2.unreadable-") else { continue }
            files[chats.deckPath, default: [:]][name] = chats
        }

        var results: [ChatSearchResult] = []
        for path in Set(files.keys).union(cached.keys).sorted() {
            if Task.isCancelled { return [] }
            let candidates = cached[path].map { entries(in: $0) } ?? entries(onDisk: files[path] ?? [:], deckPath: path)
            var seen = Set<String>()
            for entry in candidates where seen.insert(entry.message.id).inserted {
                if Task.isCancelled { return [] }
                let message = entry.message
                // A quoted walkthrough passage is part of what was asked.
                let text = [message.display, message.text, message.quote?.text].compactMap { $0 }.joined(separator: "\n")
                guard terms.allSatisfy({ text.range(of: $0, options: options, locale: locale) != nil }) else { continue }
                results.append(ChatSearchResult(deckPath: path, conversationID: entry.conversationID,
                                                messageID: message.id, page: message.page, role: message.role,
                                                provider: message.provider, createdAt: message.createdAt,
                                                snippet: snippet(text, terms: terms)))
            }
        }
        results.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
        return Array(results.prefix(limit))
    }

    private static func entries(in chats: DeckChats) -> [Entry] {
        if let conversations = chats.conversations {
            return conversations.flatMap { c in c.messages.map { Entry(conversationID: c.id, message: $0) } }
        }
        return legacyMessages(chats.threads ?? [:]).map { Entry(conversationID: nil, message: $0) }
    }

    private static func entries(onDisk files: [String: DeckChats], deckPath: String) -> [Entry] {
        let base = ChatArchiveFile.base(deckPath)
        let legacy = files[base + ".json"]
        if let current = files[base + ".chat2.json"] {
            var result = entries(in: current)
            if let legacy, legacy.conversations == nil, let threads = legacy.threads {
                result += legacyImport(threads, into: current).messages.map { Entry(conversationID: nil, message: $0) }
            }
            return result
        }
        if let legacy, legacy.conversations != nil { return entries(in: legacy) }

        // ChatStore recovers readable archives only when no current conversation file exists.
        let recoverable = files.keys.filter { $0.contains(".unreadable-") }
            .sorted { a, b in stamp(a) == stamp(b) ? a < b : stamp(a) > stamp(b) }
        var result: [Entry] = []
        var conversations = Set<String>()
        for name in recoverable {
            for conversation in files[name]?.conversations ?? [] where conversations.insert(conversation.id).inserted {
                result += conversation.messages.map { Entry(conversationID: conversation.id, message: $0) }
            }
        }
        let recoveredIDs = Set(result.map { $0.message.id })
        result += legacyMessages(legacy?.threads ?? [:]).filter { !recoveredIDs.contains($0.id) }
            .map { Entry(conversationID: nil, message: $0) }
        return result
    }

    private static func stamp(_ name: String) -> Int {
        guard let range = name.range(of: "unreadable-") else { return 0 }
        return Int(name[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    private static func legacyMessages(_ threads: [String: ChatThread]) -> [ChatMessage] {
        threads.keys.sorted().flatMap { key in
            let thread = threads[key]!
            return thread.messages.map { message in var message = message; message.page = thread.page; return message }
        }
    }

    /// Shared with actual migration, including the old files that predate importedV1 tombstones.
    static func legacyImport(_ threads: [String: ChatThread], into chats: DeckChats) -> (messages: [ChatMessage], ids: Set<String>) {
        let all = legacyMessages(threads)
        let conversations = chats.conversations ?? []
        var done = Set(chats.importedV1 ?? []).union(conversations.flatMap { $0.messages.map(\.id) })
        if chats.importedV1 == nil, !conversations.contains(where: { $0.legacy == true }) {
            if let since = conversations.map(\.created).min() {
                done.formUnion(all.filter { $0.createdAt < since }.map(\.id))
            } else {
                done.formUnion(all.map(\.id))
            }
        }
        let fresh = all.filter { !done.contains($0.id) }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        return (fresh, done.union(fresh.map(\.id)))
    }

    private static func snippet(_ text: String, terms: [String]) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let matches = terms.compactMap { flat.range(of: $0, options: options, locale: locale)?.lowerBound }
        let match = matches.min() ?? flat.startIndex
        let start = flat.index(match, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: 220, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start == flat.startIndex ? "" : "…") + String(flat[start..<end]) + (end == flat.endIndex ? "" : "…")
    }
}
