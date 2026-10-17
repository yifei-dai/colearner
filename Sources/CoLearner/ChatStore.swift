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

    /// The dictionary handed to chat.js.
    var js: [String: Any] {
        var d: [String: Any] = ["id": id, "role": role.rawValue, "text": text, "status": status.rawValue]
        if let provider { d["provider"] = provider.rawValue }
        if let display { d["display"] = display }
        if let error { d["error"] = error }
        if let activity { d["activity"] = activity }
        if let model { d["model"] = model }
        return d
    }
}

/// One conversation = one slide of one deck. Each provider keeps its own CLI session.
struct ChatThread: Codable {
    var page: Int
    var messages: [ChatMessage] = []
    var claudeSession: String?
    var codexSession: String?

    func session(for p: Provider) -> String? { p == .claude ? claudeSession : codexSession }
    mutating func setSession(_ s: String?, for p: Provider) {
        if p == .claude { claudeSession = s } else { codexSession = s }
    }
}

struct DeckChats: Codable {
    var deckPath: String
    var threads: [String: ChatThread] = [:]   // key: page number as string (JSON-friendly)
}

/// Loads and saves chats, one JSON file per deck in Application Support.
@MainActor
final class ChatStore {
    private var decks: [String: DeckChats] = [:]

    private func fileURL(_ deckPath: String) -> URL {
        let h = SHA256.hash(data: Data(deckPath.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let name = URL(fileURLWithPath: deckPath).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        return AppPaths.chats.appendingPathComponent("\(name)-\(h).json")
    }

    private func load(_ deckPath: String) -> DeckChats {
        if let d = decks[deckPath] { return d }
        var chats = DeckChats(deckPath: deckPath)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL(deckPath)), let c = try? dec.decode(DeckChats.self, from: data) {
            chats = c
            // A crash or quit mid-answer leaves "streaming" messages behind; close them.
            for (k, var t) in chats.threads {
                var changed = false
                for i in t.messages.indices where t.messages[i].status == .streaming {
                    t.messages[i].status = .stopped
                    t.messages[i].activity = nil
                    changed = true
                }
                if changed { chats.threads[k] = t }
            }
        }
        decks[deckPath] = chats
        return chats
    }

    func thread(_ deckPath: String, _ page: Int) -> ChatThread {
        load(deckPath).threads[String(page)] ?? ChatThread(page: page)
    }

    func pagesWithChats(_ deckPath: String) -> [Int] {
        load(deckPath).threads.values.filter { !$0.messages.isEmpty }.map(\.page).sorted()
    }

    func update(_ deckPath: String, _ page: Int, _ body: (inout ChatThread) -> Void) {
        var chats = load(deckPath)
        var t = chats.threads[String(page)] ?? ChatThread(page: page)
        body(&t)
        chats.threads[String(page)] = t
        decks[deckPath] = chats
    }

    func clear(_ deckPath: String, _ page: Int) {
        var chats = load(deckPath)
        chats.threads.removeValue(forKey: String(page))
        decks[deckPath] = chats
        save(deckPath)
    }

    func save(_ deckPath: String) {
        guard let chats = decks[deckPath] else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(chats) { try? d.write(to: fileURL(deckPath), options: .atomic) }
    }
}
