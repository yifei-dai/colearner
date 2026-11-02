import Foundation

/// Finds study pages for decks by looking in each course's study folders, so a walkthrough or scribe-notes
/// PDF made later shows up on the next launch (or Lectures › Reload library) without editing library.json.
///
/// - Notes PDFs built with pdfTeX are matched exactly: each slide crop carries its deck file name (ScribeMap).
///   A `.tex` with the same name next to it is offered to Claude as readable notes.
/// - HTML pages are matched by what they say about themselves: deck codes ("decks 01a and 01b", "W4L1"),
///   "Lecture 6", or else the title's words compared with the deck titles (rare words count more).
enum StudyDiscovery {
    struct Found {
        var pages: [String: [StudyPage]] = [:]     // deck path -> pages
        var context: [String: [String]] = [:]      // deck path -> readable notes (.tex)
    }

    /// Handwritten scans are never study pages.
    static func isScan(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("inclass") || n.contains("_scribing_")
    }

    static func scan(root: String, dirs: [String], numbering: String?, decks: [Deck]) -> Found {
        var found = Found()
        let fm = FileManager.default
        for dir in dirs {
            let base = URL(fileURLWithPath: root).appendingPathComponent(dir)
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = u.lastPathComponent
                guard !name.hasPrefix("."), !isScan(name) else { continue }
                switch u.pathExtension.lowercased() {
                case "pdf":
                    for d in decks where !ScribeMap.pages(notes: u.path, deckFile: d.knownFile).isEmpty
                        || (d.knownPath != nil && !ScribeMap.pages(notes: u.path, deckFile: d.url.lastPathComponent).isEmpty) {
                        let title = u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                        found.pages[d.path, default: []].append(StudyPage(title: title, path: u.path))
                        let tex = u.deletingPathExtension().appendingPathExtension("tex").path
                        if fm.fileExists(atPath: tex) { found.context[d.path, default: []].append(tex) }
                    }
                case "html", "htm":
                    let head = headText(u)
                    for d in match(title: head.title, header: head.header, decks: decks) {
                        found.pages[d.path, default: []].append(StudyPage(title: head.title.isEmpty ? name : head.title,
                                                                          path: u.path, numbering: numbering))
                    }
                default:
                    break
                }
            }
        }
        return found
    }

    /// Pages already read, by path, until the file changes (the library is read again often: Finder changes, coming
    /// back to the app).
    private static var heads: [String: (revision: FileRevision, title: String, header: String)] = [:]
    private static let headsLock = NSLock()

    /// `<title>` and the first header line ("eyebrow") of a page, from its first 256 KB.
    static func headText(_ u: URL) -> (title: String, header: String) {
        let revision = FileRevision.read(u.path)
        if let revision {
            headsLock.lock()
            let cached = heads[u.path]
            headsLock.unlock()
            if let cached, cached.revision == revision { return (cached.title, cached.header) }
        }
        let read = readHead(u)
        if let revision {
            headsLock.lock()
            heads[u.path] = (revision, read.title, read.header)
            headsLock.unlock()
        }
        return read
    }

    private static func readHead(_ u: URL) -> (title: String, header: String) {
        guard let h = try? FileHandle(forReadingFrom: u) else { return ("", "") }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 262_144)) ?? Data()
        let s = String(decoding: data, as: UTF8.self)
        func first(_ pattern: String) -> String {
            guard let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return "" }
            return String(s[r])
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"^[^>]*>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = first(#"<title>[^<]*</title>"#)
        let header = first(#"class="eyebrow"[^>]*>[\s\S]{0,400}?</p>"#)
        return (title, header)
    }

    // MARK: matching

    /// The short code a deck file starts with: "01a" (01a-...), "7" (7-...), "W4L1" (week and lecture), or nil. A renamed deck
    /// keeps the code of the name it was first listed under.
    static func deckKey(_ d: Deck) -> String? {
        for n in [d.knownFile, d.url.lastPathComponent] {
            for p in [#"^\d{2}[ab](?=-)"#, #"^\d+(?=-)"#, #"^W\d+L\d+"#] {
                if let r = n.range(of: p, options: .regularExpression) { return String(n[r]).lowercased() }
            }
        }
        return nil
    }

    static func match(title: String, header: String, decks: [Deck]) -> [Deck] {
        let text = header + " " + title
        let keyed = decks.compactMap { d in deckKey(d).map { ($0, d) } }

        // 1. Deck codes written on the page: "decks 01a and 01b", "1a–1b", "W4L1".
        var codes = Set<String>()
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,2})([ab])\b"#) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let ns = text as NSString
                let num = Int(ns.substring(with: m.range(at: 1))) ?? 0
                codes.insert(String(format: "%02d", num) + ns.substring(with: m.range(at: 2)).lowercased())
            }
        }
        if let re = try? NSRegularExpression(pattern: #"\bW\d+L\d+\b"#, options: .caseInsensitive) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                codes.insert((text as NSString).substring(with: m.range).lowercased())
            }
        }
        let byCode = keyed.filter { codes.contains($0.0) }.map(\.1)
        if !byCode.isEmpty { return byCode }

        // 2. "Lecture 6" when the decks are numbered that way ("6-local_search.pdf").
        if let r = text.range(of: #"Lecture\s+(\d+)"#, options: .regularExpression) {
            let n = String(text[r].split(separator: " ").last ?? "")
            let byLecture = keyed.filter { $0.0 == n }.map(\.1)
            if byLecture.count == 1 { return byLecture }
        }

        // 3. Title words against deck titles; a word shared by fewer decks counts more.
        let pageWords = words(title.isEmpty ? header : title)
        guard !pageWords.isEmpty else { return [] }
        let deckWords = decks.map { d in
            words([d.knownTitle ?? "", d.title, URL(fileURLWithPath: d.knownFile).deletingPathExtension().lastPathComponent].joined(separator: " "))
        }
        var df: [String: Int] = [:]
        for ws in deckWords { for w in ws { df[w, default: 0] += 1 } }
        let weight = { (w: String) -> Double in 1.0 / Double(max(df[w] ?? 0, 1)) }
        let total = pageWords.reduce(0) { $0 + weight($1) }
        let scores = deckWords.map { ws in pageWords.filter { ws.contains($0) }.reduce(0) { $0 + weight($1) } / total }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= 0.6 else { return [] }
        let runnerUp = scores.indices.filter { $0 != best }.map { scores[$0] }.max() ?? 0
        return scores[best] - runnerUp >= 0.15 ? [decks[best]] : []
    }

    /// Lower-case content words; roman numerals become digits ("Image Processing II" -> image, processing, 2).
    static func words(_ s: String) -> Set<String> {
        let stop: Set<String> = ["and", "the", "for", "using", "with", "review", "walkthrough", "recap", "mind", "map",
                                 "notes", "scribed", "lecture", "slides", "fall", "cs4731", "coms", "computer", "vision", "exam"]
        let roman = ["i": "1", "ii": "2", "iii": "3", "iv": "4"]
        let parts = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return Set(parts.compactMap { p in
            if let r = roman[p] { return r }
            if p.count == 1, Int(p) != nil { return p }
            if p.range(of: #"^w\d+l\d+$"#, options: .regularExpression) != nil { return nil }   // deck codes handled above
            return p.count >= 3 && !stop.contains(p) && Int(p) == nil ? p : nil
        })
    }
}
