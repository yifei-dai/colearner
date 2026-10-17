import Foundation

/// The models and effort levels offered in the chat's pickers.
enum ModelCatalog {
    struct Effort { var id: String; var label: String; var detail: String }
    struct Model {
        var id: String
        var label: String
        var detail: String
        var effortInfo: [Effort]
        var defaultEffort: String
        var efforts: [String] { effortInfo.map(\.id) }
    }

    /// Shown under the effort buttons (the Claude app's wording).
    static let effortHint = "Higher effort means more thorough responses, but takes longer and uses your limits faster."

    /// Claude Code aliases (each resolves to the newest model of that family). Descriptions are the ones the
    /// Claude app uses in its own model picker.
    static let claude: [Model] = {
        let efforts = [
            Effort(id: "low", label: "Low", detail: ""),
            Effort(id: "medium", label: "Medium", detail: "Recommended"),
            Effort(id: "high", label: "High", detail: ""),
            Effort(id: "xhigh", label: "Extra", detail: ""),
            Effort(id: "max", label: "Max", detail: "May use excessive tokens and take long. Use sparingly for the hardest tasks."),
        ]
        return [
            Model(id: "opus", label: "Opus 5.5", detail: "For complex work and everyday tasks", effortInfo: efforts, defaultEffort: "medium"),
            Model(id: "fable", label: "Fable 5.1", detail: "For your toughest challenges · its own weekly limit", effortInfo: efforts, defaultEffort: "medium"),
            Model(id: "sonnet", label: "Sonnet 5.5", detail: "Most efficient for simpler tasks", effortInfo: efforts, defaultEffort: "medium"),
            Model(id: "haiku", label: "Haiku 5.5", detail: "Fastest for quick answers", effortInfo: efforts, defaultEffort: "low"),
        ]
    }()

    /// The models the logged-in ChatGPT plan offers, from Codex's own cache (~/.codex/models_cache.json).
    static let codex: [Model] = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        let names = ["low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra", "max": "Max", "ultra": "Ultra"]
        var out: [Model] = []
        if let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let models = root["models"] as? [[String: Any]] {
            for m in models where (m["visibility"] as? String) == "list" {
                guard let slug = m["slug"] as? String else { continue }
                var efforts = ((m["supported_reasoning_levels"] as? [[String: Any]]) ?? []).compactMap { l -> Effort? in
                    guard let id = l["effort"] as? String else { return nil }
                    return Effort(id: id, label: names[id] ?? id.capitalized, detail: (l["description"] as? String) ?? "")
                }
                if efforts.isEmpty { efforts = ["low", "medium", "high"].map { Effort(id: $0, label: names[$0]!, detail: "") } }
                out.append(Model(id: slug, label: (m["display_name"] as? String) ?? slug, detail: (m["description"] as? String) ?? "",
                                 effortInfo: efforts, defaultEffort: (m["default_reasoning_level"] as? String) ?? "medium"))
            }
        }
        if out.isEmpty {
            out = [Model(id: CodexBackend.defaultModel, label: "GPT-6-Astra", detail: "",
                         effortInfo: ["low", "medium", "high"].map { Effort(id: $0, label: names[$0]!, detail: "") }, defaultEffort: "medium")]
        }
        return out
    }()

    static func list(_ p: Provider) -> [Model] { p == .claude ? claude : codex }

    static func model(_ p: Provider, _ id: String) -> Model? { list(p).first { $0.id == id } }

    static func label(_ p: Provider, _ id: String) -> String { model(p, id)?.label ?? id }
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
