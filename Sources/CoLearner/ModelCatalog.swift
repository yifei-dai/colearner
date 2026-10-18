import Foundation

/// The models and effort levels offered in the chat's model menu. The lists come from the tools themselves
/// (Claude Code's model aliases, Codex's model list), are cached, and refresh at every launch, so new models
/// show up without an app update. Which models appear in the menu is the user's choice.
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()

    struct Effort: Codable, Equatable { var id: String; var label: String }
    struct Model: Codable, Equatable {
        var id: String
        var label: String
        var effortInfo: [Effort]
        var defaultEffort: String
        var efforts: [String] { effortInfo.map(\.id) }
    }

    static let effortHint = "Higher effort means more thorough responses, but takes longer and uses your limits faster."

    private(set) var lists: [Provider: [Model]] = [:]
    private var hidden: [Provider: Set<String>] = [:]
    private var firstSeen: [Provider: [String: Double]] = [:]   // model id -> when this app first saw it (0 = from the start)
    private(set) var updated: [Provider: Double] = [:]
    private(set) var refreshing = false
    /// Called when a refresh starts and when it ends (the app re-checks the chosen models and redraws the menu).
    var onChange: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        for p in Provider.allCases {
            if let data = d.data(forKey: "models.\(p.rawValue)"), let m = try? JSONDecoder().decode([Model].self, from: data), !m.isEmpty {
                lists[p] = m
            }
            hidden[p] = Set(d.stringArray(forKey: "models.\(p.rawValue).hidden") ?? [])
            firstSeen[p] = (d.dictionary(forKey: "models.\(p.rawValue).firstSeen") as? [String: Double]) ?? [:]
            updated[p] = d.double(forKey: "models.\(p.rawValue).at")
        }
        if lists[.claude] == nil { lists[.claude] = Self.fallbackClaude }
        if lists[.codex] == nil { lists[.codex] = Self.codexFromCache() }
    }

    // MARK: lookups

    static func list(_ p: Provider) -> [Model] { shared.lists[p] ?? [] }
    static func model(_ p: Provider, _ id: String) -> Model? { list(p).first { $0.id == id } }
    static func label(_ p: Provider, _ id: String) -> String { model(p, id)?.label ?? id }

    func isHidden(_ p: Provider, _ id: String) -> Bool { hidden[p]?.contains(id) ?? false }
    func visible(_ p: Provider) -> [Model] { (lists[p] ?? []).filter { !isHidden(p, $0.id) } }

    /// "New" for a week after a model first appears (not for the models that were there on first launch).
    func isNew(_ p: Provider, _ id: String) -> Bool {
        guard let t = firstSeen[p]?[id], t > 0 else { return false }
        return Date().timeIntervalSince1970 - t < 7 * 86_400
    }

    /// Show or hide a model in the menu. At least one model always stays visible.
    @discardableResult
    func setHidden(_ p: Provider, _ id: String, _ hide: Bool) -> Bool {
        var h = hidden[p] ?? []
        if hide {
            guard visible(p).contains(where: { $0.id != id }) else { return false }
            h.insert(id)
        } else {
            h.remove(id)
        }
        hidden[p] = h
        UserDefaults.standard.set(Array(h).sorted(), forKey: "models.\(p.rawValue).hidden")
        return true
    }

    // MARK: refresh

    /// Asks both tools for their current models in the background (no model is called; about 2 seconds).
    func refresh(claudeBin: (URL, [Int])??, codexBin: URL??) {
        guard !refreshing else { return }
        refreshing = true
        onChange?()
        let group = DispatchGroup()
        var claude: [Model] = [], codex: [Model] = []
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let loc: (URL, [Int])? = claudeBin ?? ClaudeBackend.candidates().max { $0.1.lexicographicallyPrecedes($1.1) }
            if let bin = loc?.0 { claude = Self.fetchClaude(bin) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            if let bin = codexBin ?? CodexBackend.locate() { codex = Self.fetchCodex(bin) }
            group.leave()
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                self.refreshing = false
                _ = self.apply(.claude, claude)
                _ = self.apply(.codex, codex)
                self.onChange?()
            }
        }
    }

    private func apply(_ p: Provider, _ models: [Model]) -> Bool {
        guard !models.isEmpty else { return false }
        let now = Date().timeIntervalSince1970
        let firstRun = (updated[p] ?? 0) == 0
        var seen = firstSeen[p] ?? [:]
        let oldLabels = Dictionary((lists[p] ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        for m in models {
            if seen[m.id] == nil { seen[m.id] = firstRun ? 0 : now }
            // "opus" stays "opus" when Opus 5.5 becomes Opus 6: the new name is what's new.
            else if !firstRun, let old = oldLabels[m.id], old != m.label { seen[m.id] = now }
        }
        firstSeen[p] = seen
        updated[p] = now
        let changed = lists[p] != models
        lists[p] = models
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(models) { d.set(data, forKey: "models.\(p.rawValue)") }
        d.set(seen, forKey: "models.\(p.rawValue).firstSeen")
        d.set(now, forKey: "models.\(p.rawValue).at")
        return changed
    }

    // MARK: sources

    nonisolated static func effortLabel(_ id: String) -> String {
        ["minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra", "max": "Max", "ultra": "Ultra"][id]
            ?? id.capitalized
    }

    /// Used until the first refresh finishes (or if Claude Code can't be asked).
    static let fallbackClaude: [Model] = {
        let e = ["low", "medium", "high", "xhigh", "max"].map { Effort(id: $0, label: effortLabel($0)) }
        return [("opus", "Opus 5.5"), ("fable", "Fable 5.1"), ("sonnet", "Sonnet 5.5"), ("haiku", "Haiku 5.5")]
            .map { Model(id: $0.0, label: $0.1, effortInfo: e, defaultEffort: "medium") }
    }()

    /// Claude Code: `/model` lists the aliases (each always means the newest model of its family), and
    /// `/model <alias>` names it ("Set model to `Sonnet 5.5`"); `--help` lists the effort levels. All local.
    nonisolated static func fetchClaude(_ bin: URL) -> [Model] {
        let env = ClaudeBackend.environment(bin)
        let base = ["--output-format", "json", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", ""]
        func ask(_ cmd: String) -> String {
            let out = UsageFetcher.run(bin, ["-p", cmd] + base, env: env, cwd: nil, timeout: 20)
            return ((try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any])?["result"] as? String ?? ""
        }
        // "Available: sonnet, opus, haiku, fable, best, sonnet[1m], …, opusplan, default, or a full model ID."
        let listing = ask("/model")
        guard let r = listing.range(of: #"Available:\s*(.+)"#, options: .regularExpression) else { return [] }
        let skip: Set<String> = ["best", "default", "opusplan"]
        let listed = String(listing[r]).replacingOccurrences(of: "Available:", with: "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "or a full model ID.", with: "") }
            .filter { !$0.isEmpty && !$0.contains("[") && !$0.contains(" ") && !skip.contains($0) }
        // Strongest first; families the app doesn't know yet go at the end in Claude Code's order.
        let preferred = ["opus", "fable", "sonnet", "haiku"]
        let aliases = listed.sorted {
            (preferred.firstIndex(of: $0) ?? 99, listed.firstIndex(of: $0) ?? 0) < (preferred.firstIndex(of: $1) ?? 99, listed.firstIndex(of: $1) ?? 0)
        }
        var labels = [String?](repeating: nil, count: aliases.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: aliases.count) { i in
            let reply = ask("/model \(aliases[i])")
            let name = reply.range(of: "`[^`]+`", options: .regularExpression).map { String(reply[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            lock.lock(); labels[i] = name; lock.unlock()
        }
        let help = UsageFetcher.run(bin, ["--help"], env: env, cwd: nil, timeout: 10)
        var efforts = ["low", "medium", "high", "xhigh", "max"]
        if let er = help.range(of: #"--effort <level>[^(]*\(([a-z, ]+)\)"#, options: .regularExpression) {
            let inside = help[er].split(separator: "(").last.map { $0.replacingOccurrences(of: ")", with: "") } ?? ""
            let parsed = inside.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !parsed.isEmpty { efforts = parsed }
        }
        // If any alias didn't resolve (timeout, odd output), keep the old list rather than apply a partial one.
        guard labels.allSatisfy({ $0 != nil }) else { return [] }
        let e = efforts.map { Effort(id: $0, label: effortLabel($0)) }
        return aliases.enumerated().map { i, a in
            Model(id: a, label: labels[i]!, effortInfo: e, defaultEffort: efforts.contains("medium") ? "medium" : efforts[0])
        }
    }

    /// Codex app-server `model/list`: the models the logged-in ChatGPT plan offers, with their effort levels.
    nonisolated static func fetchCodex(_ bin: URL) -> [Model] {
        let lines = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"colearner","title":"Co-learner","version":"0.1.7"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"model/list","params":{}}"#,
        ].joined(separator: "\n") + "\n"
        var data: [[String: Any]] = []
        _ = UsageFetcher.run(bin, ["app-server"], env: ToolLocator.environment(addingDirsOf: [bin]), cwd: nil,
                             stdin: Data(lines.utf8), keepStdinOpen: true, timeout: 12) { line in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (o["id"] as? NSNumber)?.intValue == 2 else { return false }
            data = ((o["result"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            return true
        }
        // model/list also refreshes Codex's cache when online. Offline (or logged out) it answers with the CLI's
        // built-in presets instead of the plan's list, so the cache (the server's list for this plan) comes first.
        let cached = codexFromCache(fallback: false)
        if !cached.isEmpty { return cached }
        return data.compactMap { m -> Model? in
            guard (m["hidden"] as? Bool) != true, let id = (m["model"] as? String) ?? (m["id"] as? String) else { return nil }
            let efforts = ((m["supportedReasoningEfforts"] as? [[String: Any]]) ?? []).compactMap { $0["reasoningEffort"] as? String }
            let e = (efforts.isEmpty ? ["low", "medium", "high"] : efforts).map { Effort(id: $0, label: effortLabel($0)) }
            return Model(id: id, label: (m["displayName"] as? String) ?? id, effortInfo: e,
                         defaultEffort: (m["defaultReasoningEffort"] as? String) ?? "medium")
        }
    }

    /// Codex's own model cache (~/.codex/models_cache.json). `fallback` adds a one-model list when there is no
    /// cache (only for the very first launch; a refresh never applies it).
    nonisolated static func codexFromCache(fallback: Bool = true) -> [Model] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        var out: [Model] = []
        if let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let models = root["models"] as? [[String: Any]] {
            for m in models where (m["visibility"] as? String) == "list" {
                guard let slug = m["slug"] as? String else { continue }
                let efforts = ((m["supported_reasoning_levels"] as? [[String: Any]]) ?? []).compactMap { $0["effort"] as? String }
                out.append(Model(id: slug, label: (m["display_name"] as? String) ?? slug,
                                 effortInfo: (efforts.isEmpty ? ["low", "medium", "high"] : efforts).map { Effort(id: $0, label: effortLabel($0)) },
                                 defaultEffort: (m["default_reasoning_level"] as? String) ?? "medium"))
            }
        }
        if out.isEmpty && fallback {
            out = [Model(id: "gpt-6-astra", label: "GPT-6-Astra",
                         effortInfo: ["low", "medium", "high"].map { Effort(id: $0, label: effortLabel($0)) }, defaultEffort: "medium")]
        }
        return out
    }
}

/// Plan usage as the CLIs report it ("5h 32%", "week 26%").
struct UsageWindow: Codable {
    var label: String           // short: "5h", "week", "Fable wk"
    var percent: Double
    var resetsAt: Double?
    var title: String? = nil    // long: "Current session", "Current week (all models)"
    var resetsText: String? = nil

    var js: [String: Any] {
        var d: [String: Any] = ["label": label, "percent": percent]
        if let resetsAt { d["resetsAt"] = resetsAt }
        if let title { d["title"] = title }
        if let resetsText { d["resetsText"] = resetsText }
        return d
    }

    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: return "5h"
        case 10080: return "week"
        default: return minutes % 1440 == 0 ? "\(minutes / 1440)d" : "\(minutes / 60)h"
        }
    }

    /// Claude Code's stream: rate_limit_event.rate_limit_info.unifiedWindows {five_hour: {utilization 0…1, resetsAt}, seven_day: …}
    static func fromClaude(_ info: [String: Any]) -> [UsageWindow] {
        guard let windows = info["unifiedWindows"] as? [String: Any] else { return [] }
        let names = ["five_hour": "5h", "seven_day": "week"]
        let titles = ["five_hour": "Current session", "seven_day": "Current week (all models)"]
        let order = ["five_hour", "seven_day"]
        let keys = windows.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
        return keys.compactMap { k in
            guard let w = windows[k] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(label: names[k] ?? k.replacingOccurrences(of: "_", with: " "), percent: u * 100,
                               resetsAt: (w["resetsAt"] as? NSNumber)?.doubleValue, title: titles[k])
        }
    }

    /// Codex's session log: {type: event_msg, payload: {type: token_count, rate_limits: {primary: {used_percent, window_minutes, resets_at}, secondary}}}
    static func fromCodex(_ limits: [String: Any]) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { k in
            guard let w = limits[k] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let mins = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
            return UsageWindow(label: windowLabel(minutes: mins), percent: pct, resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue,
                               title: mins == 300 ? "5-hour limit" : mins == 10080 ? "Weekly limit" : nil)
        }
    }

    /// The newest rate limits Codex wrote, from the session log of `thread` (or the newest log of all).
    static func latestCodex(thread: String?) -> [UsageWindow] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        // Logs live in sessions/YYYY/MM/DD/; look at the newest few days only.
        var files: [URL] = []
        let years = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted().suffix(2)
        for y in years {
            let yd = root.appendingPathComponent(y)
            for m in ((try? fm.contentsOfDirectory(atPath: yd.path)) ?? []).sorted().suffix(2) {
                let md = yd.appendingPathComponent(m)
                for d in ((try? fm.contentsOfDirectory(atPath: md.path)) ?? []).sorted().suffix(3) {
                    let dd = md.appendingPathComponent(d)
                    for f in (try? fm.contentsOfDirectory(atPath: dd.path)) ?? [] where f.hasSuffix(".jsonl") {
                        files.append(dd.appendingPathComponent(f))
                    }
                }
            }
        }
        let pick: URL?
        if let thread, let hit = files.first(where: { $0.lastPathComponent.contains(thread) }) {
            pick = hit
        } else {
            pick = files.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        }
        guard let pick, let text = try? String(contentsOf: pick, encoding: .utf8) else { return [] }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let payload = o["payload"] as? [String: Any], let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let w = fromCodex(limits)
            if !w.isEmpty { return w }
        }
        return []
    }
}
