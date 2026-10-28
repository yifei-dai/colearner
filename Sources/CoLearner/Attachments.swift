import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A picture waiting in the chat box (a screenshot, an image file, part of the walkthrough). It goes with the next
/// question: an image file the assistants get, plus a small preview for the chat.
struct PendingImage: Equatable, Sendable {
    var id: String = UUID().uuidString
    var url: URL
    /// Small JPEG data URL for the chat box and the question bubble.
    var thumb: String
    /// On the chip in the chat box: the file name, "Pasted image", "Walkthrough area", …
    var label: String
    /// How the prompt names it: "an image the student pasted", "a capture of part of the walkthrough page “…”".
    var detail: String
}

/// Screenshots and other pictures for the chat: decoded, turned upright, scaled down and written to the cache.
enum ImageAttachments {
    /// Long edge in pixels, as for slides: both assistants scale larger pictures down anyway, and once a chat holds
    /// more than 20 images Claude refuses any over 2000 px.
    static let longEdge: CGFloat = SlideImages.longEdge
    /// A PNG bigger than this is sent as JPEG instead (Claude takes at most 5 MB per image, as base64).
    static let maxBytes = 3_500_000
    /// Pictures per question.
    static let maxPending = 8
    /// Files larger than this are not read at all.
    static let maxFileBytes = 60_000_000
    static let thumbEdge: CGFloat = 320

    static var folder: URL {
        let dir = AppPaths.cache.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Any format macOS reads (PNG, JPEG, HEIC, TIFF, GIF, PDF…), upright (EXIF orientation applied), at most `longEdge`.
    static func make(data: Data, label: String, detail: String, in dir: URL = folder,
                     maxBytes: Int = maxBytes) -> PendingImage? {
        guard data.count <= maxFileBytes, let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longEdge),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return make(image: image, label: label, detail: detail, in: dir, maxBytes: maxBytes)
    }

    /// A picture already in memory (a snapshot of the walkthrough, a rendered notes page).
    static func make(image: CGImage, label: String, detail: String, in dir: URL = folder,
                     maxBytes: Int = maxBytes) -> PendingImage? {
        guard image.width > 0, image.height > 0, let scaled = scale(image, toFit: longEdge, opaque: false) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        var url = dir.appendingPathComponent(id + ".png")
        var data = encode(scaled, type: .png)
        if (data?.count ?? 0) > maxBytes, let flat = scale(scaled, toFit: longEdge, opaque: true) {
            // Photos and busy screenshots compress badly as PNG.
            url = dir.appendingPathComponent(id + ".jpg")
            data = encode(flat, type: .jpeg, quality: 0.85)
        }
        guard let data, (try? data.write(to: url, options: .atomic)) != nil,
              let small = scale(scaled, toFit: thumbEdge, opaque: true),
              let jpg = encode(small, type: .jpeg, quality: 0.75) else { return nil }
        return PendingImage(id: id, url: url, thumb: "data:image/jpeg;base64," + jpg.base64EncodedString(),
                            label: label, detail: detail)
    }

    /// Fits `image` into `edge` pixels (never enlarges). `opaque` flattens transparency onto white (for JPEG).
    static func scale(_ image: CGImage, toFit edge: CGFloat, opaque: Bool) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(1, edge / max(w, h))
        if s == 1 && !opaque { return image }
        let pw = max(1, Int((w * s).rounded())), ph = max(1, Int((h * s).rounded()))
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        if opaque {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        return ctx.makeImage()
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: the pasteboard (paste, and drops the chat page could not read)

    enum Item: Equatable {
        case file(URL)
        case data(Data)
    }

    /// What a paste attaches: image files (copied in Finder) or image data (a screenshot copied with ⌃⇧⌘4, Copy in
    /// Preview, Copy Image in a browser). Text on the pasteboard wins over image data, so copied text that also
    /// carries a picture pastes as text; a lone web address next to the picture (a browser's Copy Image) does not count.
    static func items(on pb: NSPasteboard) -> [Item] {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return files.filter(isImageFile).prefix(maxPending).map(Item.file) }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           !isLoneURL(text) { return [] }
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]
        if let type = pb.availableType(from: types), let data = pb.data(forType: type) { return [.data(data)] }
        // Anything else NSImage reads (e.g. a PDF selection copied in Preview).
        if NSImage.canInit(with: pb), let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation {
            return [.data(tiff)]
        }
        return []
    }

    /// By the name alone: looking inside a file in Documents or Downloads would make macOS ask for that folder.
    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func isLoneURL(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace), let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }

    /// Where macOS saves screenshots (Screenshot app › Options › Save to); the Desktop by default.
    static var screenshotFolder: URL {
        if let s = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Attachments and slide areas are only read when their question is sent; clear out old ones (in the background).
    static func removeOld(maxAge: TimeInterval = 7 * 86_400) {
        let dirs = [folder, AppPaths.cache.appendingPathComponent("areas", isDirectory: true)]
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-maxAge)
            for dir in dirs {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for f in files {
                    let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
                    if date < cutoff { try? fm.removeItem(at: f) }
                }
            }
        }
    }
}
