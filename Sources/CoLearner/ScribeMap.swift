import Foundation
import CoreGraphics

/// Maps lecture slides to pages of a LaTeX-built notes PDF (typed lecture notes that include the slides).
///
/// pdfTeX stamps every included PDF page with /PTEX.FileName and /PTEX.PageNumber, so each slide crop
/// in the notes says which deck and slide it came from. No hand-made tables needed.
enum ScribeMap {
    private struct CachedMap {
        var revision: FileRevision
        var decks: [String: [Int: Int]]   // deck file -> slide -> notes page
    }
    private static var cache: [String: CachedMap] = [:]

    /// slide number -> first notes page (1-based) that shows that slide, for the deck with this file name.
    static func pages(notes path: String, deckFile: String) -> [Int: Int] {
        guard let revision = FileRevision.read(path) else {
            cache[path] = nil
            return [:]
        }
        if let c = cache[path], c.revision == revision { return c.decks[deckFile] ?? [:] }
        cache[path] = nil
        // A notes build may briefly leave no readable PDF. Retry next time instead of caching that failure.
        guard let all = scan(path) else { return [:] }
        if FileRevision.read(path) == revision {
            cache[path] = CachedMap(revision: revision, decks: all)
        }
        return all[deckFile] ?? [:]
    }

    /// The notes page for a slide: the exact page if the slide is shown in the notes, else the page of the
    /// nearest earlier slide that is (else the first page of this deck's part). Nil if the deck isn't in the notes.
    static func page(for slide: Int, in map: [Int: Int]) -> (page: Int, exact: Bool)? {
        guard !map.isEmpty else { return nil }
        if let p = map[slide] { return (p, true) }
        if let prev = map.keys.filter({ $0 < slide }).max() { return (map[prev]!, false) }
        let first = map.keys.min()!
        return (map[first]!, false)
    }

    private static func scan(_ path: String) -> [String: [Int: Int]]? {
        guard let doc = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { return nil }
        var out: [String: [Int: Int]] = [:]
        for i in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: i), let dict = page.dictionary else { continue }
            var found: [(String, Int)] = []
            collect(from: dict, depth: 0, into: &found)
            for (file, slide) in found {
                let name = (file as NSString).lastPathComponent
                if out[name, default: [:]][slide] == nil { out[name, default: [:]][slide] = i }
            }
        }
        return out
    }

    /// Walks Resources -> XObject (and nested form XObjects) looking for pdfTeX's PTEX keys.
    private static func collect(from dict: CGPDFDictionaryRef, depth: Int, into found: inout [(String, Int)]) {
        guard depth < 4 else { return }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let res = resources else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xo = xobjects else { return }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xo, { _, value, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)
        for s in streams {
            guard let sd = CGPDFStreamGetDictionary(s) else { continue }
            var nameRef: CGPDFStringRef?
            var pageNum: CGPDFInteger = 0
            if CGPDFDictionaryGetString(sd, "PTEX.FileName", &nameRef), let nameRef,
               let name = CGPDFStringCopyTextString(nameRef) as String?,
               CGPDFDictionaryGetInteger(sd, "PTEX.PageNumber", &pageNum) {
                found.append((name, Int(pageNum)))
            }
            collect(from: sd, depth: depth + 1, into: &found)
        }
    }
}
