import Foundation
import CryptoKit
import Darwin

/// A file version, including atomic replacements and same-size edits with a preserved modification date.
struct FileRevision: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    static func read(_ path: String) -> FileRevision? {
        var info = stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return nil }
        return FileRevision(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}

enum SourceRevision {
    private struct File: Encodable {
        var path: String
        var revision: FileRevision?
    }
    private struct Context: Encodable {
        var path: String
        var title: String
        var course: String
        var layout: SlideLayout
        var pages: [StudyPage]
        var files: [File]
    }

    /// Sessions are valid only for this deck version and this exact set of linked sources. The title is the one
    /// library.json gives (as before decks showed their file names), so that change alone keeps sessions.
    static func context(for deck: Deck, course: String? = nil) -> String {
        let paths = Set([deck.path] + deck.contextFiles + deck.walkthroughs.map(\.path)).sorted()
        let context = Context(path: deck.path, title: deck.knownTitle ?? deck.title, course: course ?? deck.courseName,
                              layout: deck.layout,
                              pages: deck.walkthroughs.sorted { $0.path < $1.path },
                              files: paths.map { File(path: $0, revision: FileRevision.read($0)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // All fields above are finite file metadata and library values.
        let data = (try? encoder.encode(context)) ?? Data(UUID().uuidString.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Revisions an earlier version stored for this same deck and sources: a PDF opened by hand used to be in course
    /// "Other PDFs" and now takes its course folder's name. A session stamped with one of these is kept.
    static func equivalents(for deck: Deck) -> Set<String> {
        deck.courseName == "Other PDFs" ? [] : [context(for: deck, course: "Other PDFs")]
    }
}
