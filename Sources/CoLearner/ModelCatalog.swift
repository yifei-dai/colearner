import Foundation

/// The models and effort levels offered in the chat's pickers.
enum ModelCatalog {
    struct Model { var id: String; var label: String; var efforts: [String]; var defaultEffort: String }

    /// Claude Code aliases (each resolves to the newest model of that family).
    static let claude: [Model] = {
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        return [
            Model(id: "opus", label: "Opus 5.5", efforts: efforts, defaultEffort: "medium"),
            Model(id: "fable", label: "Fable 5.1", efforts: efforts, defaultEffort: "medium"),
            Model(id: "sonnet", label: "Sonnet 5.5", efforts: efforts, defaultEffort: "medium"),
            Model(id: "haiku", label: "Haiku 5.5", efforts: efforts, defaultEffort: "low"),
        ]
    }()

    /// The models the logged-in ChatGPT plan offers, from Codex's own cache (~/.codex/models_cache.json).
    static let codex: [Model] = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        var out: [Model] = []
        if let data = try? Data(contentsOf: url),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let models = root["models"] as? [[String: Any]] {
            for m in models where (m["visibility"] as? String) == "list" {
                guard let slug = m["slug"] as? String else { continue }
                let efforts = (m["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
                out.append(Model(id: slug, label: (m["display_name"] as? String) ?? slug,
                                 efforts: efforts.isEmpty ? ["low", "medium", "high"] : efforts,
                                 defaultEffort: (m["default_reasoning_level"] as? String) ?? "medium"))
            }
        }
        if out.isEmpty {
            out = [Model(id: CodexBackend.defaultModel, label: "GPT-6-Astra", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium")]
        }
        return out
    }()

    static func list(_ p: Provider) -> [Model] { p == .claude ? claude : codex }

    static func model(_ p: Provider, _ id: String) -> Model? { list(p).first { $0.id == id } }

    static func label(_ p: Provider, _ id: String) -> String { model(p, id)?.label ?? id }
}

/// Plan usage as the CLIs report it ("5h 32%", "week 26%").
struct UsageWindow: Codable {
    var label: String
    var percent: Double
    var resetsAt: Double?

    var js: [String: Any] {
        var d: [String: Any] = ["label": label, "percent": percent]
        if let resetsAt { d["resetsAt"] = resetsAt }
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
        let order = ["five_hour", "seven_day"]
        let keys = windows.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
        return keys.compactMap { k in
            guard let w = windows[k] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(label: names[k] ?? k.replacingOccurrences(of: "_", with: " "), percent: u * 100,
                               resetsAt: (w["resetsAt"] as? NSNumber)?.doubleValue)
        }
    }

    /// Codex's session log: {type: event_msg, payload: {type: token_count, rate_limits: {primary: {used_percent, window_minutes, resets_at}, secondary}}}
    static func fromCodex(_ limits: [String: Any]) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { k in
            guard let w = limits[k] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let mins = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
            return UsageWindow(label: windowLabel(minutes: mins), percent: pct, resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue)
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
