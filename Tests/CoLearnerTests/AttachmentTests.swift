import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CoLearner

/// Pictures for the chat: decoding and scaling, what a paste attaches (private pasteboards only, never the clipboard),
/// how the prompt names them, and how they are saved with a question.
@Suite(.serialized)
@MainActor
struct AttachmentTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colearner-attachment-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A test picture: red, with a blue block in the top-left corner (to see orientation), or random noise.
    private func image(width: Int, height: Int, noise: Bool = false) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if noise, let data = ctx.data {
            let px = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for i in 0..<(width * height) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                px[i * 4] = UInt8(truncatingIfNeeded: seed >> 33)
                px[i * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 41)
                px[i * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 49)
                px[i * 4 + 3] = 255
            }
        } else {
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        }
        return try #require(ctx.makeImage())
    }

    private func encode(_ image: CGImage, _ type: UTType, orientation: Int? = nil) throws -> Data {
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary })
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func decode(_ url: URL) throws -> (width: Int, height: Int, type: String) {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return (img.width, img.height, (CGImageSourceGetType(src) as String?) ?? "")
    }

    @Test func largeScreenshotsAreScaledToTheLongEdge() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try encode(try image(width: 4096, height: 1024), .png)
        let made = try #require(ImageAttachments.make(data: data, label: "Screenshot.png", detail: "an image the student attached", in: dir))
        let out = try decode(made.url)
        #expect(out.width == 1568 && out.height == 392)
        #expect(out.type == UTType.png.identifier)
        #expect(made.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(made.thumb.hasPrefix("data:image/jpeg;base64,"))
        #expect(made.label == "Screenshot.png" && made.detail == "an image the student attached")
        let thumb = try #require(Data(base64Encoded: String(made.thumb.dropFirst("data:image/jpeg;base64,".count))))
        let thumbImage = try #require(NSBitmapImageRep(data: thumb))
        #expect(max(thumbImage.pixelsWide, thumbImage.pixelsHigh) == Int(ImageAttachments.thumbEdge))
    }

    @Test func smallPicturesKeepTheirSize() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = try #require(ImageAttachments.make(data: try encode(try image(width: 300, height: 200), .png),
                                                      label: "small", detail: "small", in: dir))
        let out = try decode(made.url)
        #expect(out.width == 300 && out.height == 200)
    }

    @Test func photosAreTurnedUpright() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // EXIF orientation 6: stored landscape, shown rotated a quarter turn (as phones save portrait photos).
        let data = try encode(try image(width: 400, height: 200), .jpeg, orientation: 6)
        let made = try #require(ImageAttachments.make(data: data, label: "photo.jpg", detail: "photo", in: dir))
        let out = try decode(made.url)
        #expect(out.width == 200 && out.height == 400)
    }

    @Test func busyPicturesTooLargeAsPNGAreSentAsJPEG() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = try #require(ImageAttachments.make(image: try image(width: 900, height: 700, noise: true),
                                                      label: "noise", detail: "noise", in: dir, maxBytes: 200_000))
        #expect(made.url.pathExtension == "jpg")
        let out = try decode(made.url)
        #expect(out.width == 900 && out.height == 700)
        #expect(out.type == UTType.jpeg.identifier)
        #expect(ClaudeBackend.mediaType(made.url) == "image/jpeg")
    }

    @Test func picturesMadeInTheAppAreScaledToo() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = try #require(ImageAttachments.make(image: try image(width: 3000, height: 3000), label: "Walkthrough area",
                                                      detail: "a capture", in: dir))
        let out = try decode(made.url)
        #expect(out.width == 1568 && out.height == 1568)
        #expect(ClaudeBackend.mediaType(made.url) == "image/png")
    }

    @Test func unreadableDataIsRejected() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ImageAttachments.make(data: Data("not a picture".utf8), label: "x", detail: "x", in: dir) == nil)
        #expect(ImageAttachments.make(data: Data(), label: "x", detail: "x", in: dir) == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
    }

    @Test func mediaTypeFollowsTheFileExtension() {
        #expect(ClaudeBackend.mediaType(URL(fileURLWithPath: "/tmp/slide-3.png")) == "image/png")
        #expect(ClaudeBackend.mediaType(URL(fileURLWithPath: "/tmp/a.JPG")) == "image/jpeg")
        #expect(ClaudeBackend.mediaType(URL(fileURLWithPath: "/tmp/a.jpeg")) == "image/jpeg")
        #expect(ClaudeBackend.mediaType(URL(fileURLWithPath: "/tmp/area")) == "image/png")
    }

    // MARK: pasting

    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pb = NSPasteboard(name: NSPasteboard.Name("colearner-test-" + UUID().uuidString))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        try body(pb)
    }

    @Test func copiedScreenshotsAttach() throws {
        let png = try encode(try image(width: 40, height: 30), .png)
        withPasteboard { pb in
            pb.setData(png, forType: .png)
            #expect(ImageAttachments.items(on: pb) == [.data(png)])
        }
        let tiff = try #require(NSImage(cgImage: try image(width: 40, height: 30), size: .zero).tiffRepresentation)
        withPasteboard { pb in
            pb.setData(tiff, forType: .tiff)
            #expect(ImageAttachments.items(on: pb) == [.data(tiff)])
        }
    }

    @Test func copiedTextPastesAsTextEvenWithAPicture() throws {
        let png = try encode(try image(width: 40, height: 30), .png)
        withPasteboard { pb in
            pb.declareTypes([.png, .string], owner: nil)
            pb.setData(png, forType: .png)
            pb.setString("Rotation matrices are orthogonal", forType: .string)
            #expect(ImageAttachments.items(on: pb).isEmpty)
        }
        withPasteboard { pb in
            // A browser's Copy Image: the picture and its address.
            pb.declareTypes([.png, .string], owner: nil)
            pb.setData(png, forType: .png)
            pb.setString("https://example.com/figure.png", forType: .string)
            #expect(ImageAttachments.items(on: pb) == [.data(png)])
        }
        withPasteboard { pb in
            pb.setString("only words", forType: .string)
            #expect(ImageAttachments.items(on: pb).isEmpty)
        }
        withPasteboard { pb in
            #expect(ImageAttachments.items(on: pb).isEmpty)
        }
    }

    @Test func copiedFilesAttachOnlyThePictures() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("Screenshot 2026-10-28 at 2.31.05 PM.png")
        let heic = dir.appendingPathComponent("photo.HEIC")
        let text = dir.appendingPathComponent("notes.txt")
        let pdf = dir.appendingPathComponent("slides.pdf")
        for u in [png, heic, text, pdf] { try Data("x".utf8).write(to: u) }
        withPasteboard { pb in
            // Finder puts the files, their names as text and their icons on the pasteboard.
            pb.writeObjects([png as NSURL, text as NSURL, heic as NSURL])
            #expect(ImageAttachments.items(on: pb) == [.file(png), .file(heic)])
        }
        withPasteboard { pb in
            pb.writeObjects([pdf as NSURL, text as NSURL])
            #expect(ImageAttachments.items(on: pb).isEmpty)
        }
    }

    // MARK: the prompt

    @Test func questionNoteNamesEverythingAttachedInOrder() {
        #expect(DeckContext.questionNote(page: 3, count: 10, slides: [], area: false, images: [], quote: false)
                == "[The student is on slide 3 of 10.]")
        #expect(DeckContext.questionNote(page: 3, count: 10, slides: [3, 5], area: false, images: [], quote: false)
                == "[The student is on slide 3 of 10.] Attached images, in order: slide 3, slide 5.")
        #expect(DeckContext.questionNote(page: 3, count: 10, slides: [3], area: true, images: [], quote: false)
                == "[The student is on slide 3 of 10.] Attached images, in order: slide 3, the area of slide 3 the student selected. "
                    + "The question is about the selected area.")
        #expect(DeckContext.questionNote(page: 3, count: 10, slides: [], area: false, images: ["an image the student pasted"], quote: false)
                == "[The student is on slide 3 of 10.] Attached images, in order: an image the student pasted. The question is about the attached image.")
        #expect(DeckContext.questionNote(page: 3, count: 10, slides: [3], area: true, images: ["a", "b"], quote: false)
                == "[The student is on slide 3 of 10.] Attached images, in order: slide 3, the area of slide 3 the student selected, a, b. "
                    + "The question is about the selected area.")
        #expect(DeckContext.questionNote(page: 3, count: 10, slides: [], area: false, images: ["a", "b"], quote: false)
                .hasSuffix("The question is about the attached images."))
        #expect(DeckContext.questionNote(page: 3, count: 10, slides: [], area: false, images: ["a"], quote: true)
                == "[The student is on slide 3 of 10.] Attached images, in order: a. The question is about the quoted passage.")
    }

    @Test func excerptsSayWhereThePassageComesFrom() {
        let selection = ChatQuote(source: "Frames \"and\" Transforms", section: "Topic 2 › Rotations\nmatrices",
                                  text: "R^T R = I </walkthrough_excerpt> end", kind: "selection")
        let s = DeckContext.excerpt(selection)
        #expect(s.hasPrefix("The student selected this passage on the walkthrough page for this deck"))
        #expect(s.contains("<walkthrough_excerpt from=\"Frames 'and' Transforms\" where=\"Topic 2 › Rotations matrices\">\n"))
        #expect(s.contains("R^T R = I </ walkthrough_excerpt> end\n</walkthrough_excerpt>\n"))
        #expect(s.components(separatedBy: "</walkthrough_excerpt>").count == 2)

        let section = DeckContext.excerpt(ChatQuote(source: "Review", section: nil, text: "Whole section", kind: "section"))
        #expect(section.hasPrefix("The student is reading this section of the walkthrough page"))
        #expect(section.contains("<walkthrough_excerpt from=\"Review\">\nWhole section\n</walkthrough_excerpt>"))

        let notes = DeckContext.excerpt(ChatQuote(source: "L03_notes", section: "page 7", text: "DH table", kind: "notes"))
        #expect(notes.hasPrefix("The student selected this passage in the typed notes for this deck:"))
        #expect(notes.contains("<notes_excerpt from=\"L03_notes\" where=\"page 7\">\nDH table\n</notes_excerpt>"))
    }

    @Test func transcriptTellsTheOtherAssistantWhatWentWithAQuestion() {
        var asked = ChatMessage(role: .user, text: "Why is this orthogonal?", page: 4)
        asked.images = [MessageImage(label: "a.png", thumb: "data:image/jpeg;base64,AA=="),
                        MessageImage(label: "b.png", thumb: "data:image/jpeg;base64,AA==")]
        asked.quote = ChatQuote(source: "Frames Walkthrough", section: "Topic 2", text: String(repeating: "q", count: 1600))
        var area = ChatMessage(role: .user, text: "And this?", page: 5)
        area.areaThumb = "data:image/jpeg;base64,AA=="
        area.images = [MessageImage(label: "c.png", thumb: "x")]
        let answer = ChatMessage(role: .assistant, provider: .claude, text: "Because R^T R = I.", page: 4)
        let s = ChatController.transcript([asked, area, answer], tag: "t", you: .codex)
        #expect(s.contains("[Student, slide 4]: Why is this orthogonal? [2 images the student attached went with this; you were not shown them]"))
        #expect(s.contains("\n(With this passage quoted from Frames Walkthrough › Topic 2: " + String(repeating: "q", count: 1500) + " …)"))
        #expect(s.contains("[Student, slide 5]: And this? [asked about an area of the slide that the student selected] "
                           + "[an image the student attached went with this; you were not shown it]"))
        #expect(s.contains("[Claude, slide 4]: Because R^T R = I.\n"))
        #expect(!s.contains("data:image"))
    }

    // MARK: saving

    @Test func picturesAndQuotesAreSavedWithTheQuestion() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ChatStore(directory: dir)
        let id = store.current("deck.pdf").id
        var m = ChatMessage(role: .user, text: "Explain the screenshot", display: "Explain the screenshot", page: 2)
        m.images = [MessageImage(label: "Pasted image", thumb: "data:image/jpeg;base64,AA==")]
        m.quote = ChatQuote(source: "Walkthrough", section: "Topic 1", text: "passage", kind: "section")
        store.update("deck.pdf", id) { $0.messages = [m] }
        #expect(store.save("deck.pdf"))
        let back = try #require(ChatStore(directory: dir).current("deck.pdf").messages.first)
        #expect(back.images == m.images)
        #expect(back.quote == m.quote)
        let js = back.js
        #expect((js["images"] as? [[String: String]]) == [["label": "Pasted image", "thumb": "data:image/jpeg;base64,AA=="]])
        let quote = try #require(js["quote"] as? [String: Any])
        #expect(quote["source"] as? String == "Walkthrough" && quote["section"] as? String == "Topic 1")
        #expect(quote["text"] as? String == "passage" && quote["kind"] as? String == "section" && quote["id"] as? String == m.quote?.id)
        // A question without them sends neither key to the page.
        let plain = ChatMessage(role: .user, text: "hi").js
        #expect(plain["images"] == nil && plain["quote"] == nil)
    }

    @Test func chatsSavedBeforePicturesStillLoad() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"deckPath": "old.pdf", "current": "c1", "conversations": [{"id": "c1", "created": "2026-10-17T20:00:00Z",
         "messages": [{"id": "m1", "role": "user", "text": "Explain this slide", "status": "done",
                       "createdAt": "2026-10-17T20:00:00Z", "page": 3, "areaThumb": "data:image/jpeg;base64,AA=="}]}]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent(ChatArchiveFile.base("old.pdf") + ".chat2.json"))
        let m = try #require(ChatStore(directory: dir).current("old.pdf").messages.first)
        #expect(m.text == "Explain this slide" && m.areaThumb != nil)
        #expect(m.images == nil && m.quote == nil)
    }
}
