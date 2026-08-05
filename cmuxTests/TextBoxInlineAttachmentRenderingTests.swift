import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct TextBoxInlineAttachmentRenderingTests {
    @Test func largeAttachmentBatchUsesOneInlineCellWithoutDroppingFiles() throws {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 30)
        )
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "existing text"
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        let attachments = (0..<1_000).map { index in
            TextBoxAttachment(
                displayName: "file-\(index).txt",
                submissionText: "/tmp/file-\(index).txt",
                submissionPath: "/tmp/file-\(index).txt",
                localURL: nil
            )
        }

        #expect(textView.insertAttachments(attachments))

        #expect(textView.inlineAttachments().map(\.submissionPath) == attachments.map(\.submissionPath))
        #expect(inlineAttachmentCellCount(in: textView) == 1)
        let submissionParts = textView.submissionParts()
        #expect(submissionParts.count == 1_001)
        guard submissionParts.count == 1_001 else { return }
        guard case .text(let prefix) = submissionParts[0],
              case .attachment(let firstAttachment) = submissionParts[1],
              case .attachment(let lastAttachment) = submissionParts[1_000] else {
            Issue.record("Large attachment groups must expand into ordered submission parts.")
            return
        }
        #expect(prefix == "existing text ")
        #expect(firstAttachment.submissionPath == "/tmp/file-0.txt")
        #expect(lastAttachment.submissionPath == "/tmp/file-999.txt")

        let firstDraft = try #require(textView.sessionDraftSnapshot(isActive: true))
        let secondDraft = try #require(textView.sessionDraftSnapshot(isActive: true))
        firstDraft.parts.withUnsafeBufferPointer { firstBuffer in
            secondDraft.parts.withUnsafeBufferPointer { secondBuffer in
                #expect(firstBuffer.baseAddress == secondBuffer.baseAddress)
            }
        }
    }

    @Test func normalAttachmentBatchKeepsIndividualCells() {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 30)
        )
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let maximumIndividualCells = 20
        let attachments = (0..<maximumIndividualCells).map { index in
            TextBoxAttachment(
                displayName: "file-\(index).txt",
                submissionText: "/tmp/file-\(index).txt",
                submissionPath: "/tmp/file-\(index).txt",
                localURL: nil
            )
        }

        #expect(textView.insertAttachments(attachments))
        #expect(textView.inlineAttachments().count == attachments.count)
        #expect(inlineAttachmentCellCount(in: textView) == attachments.count)
    }

    @Test func deletingLargeAttachmentGroupRemovesEveryLogicalFile() {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 30)
        )
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let attachments = (0..<1_000).map { index in
            TextBoxAttachment(
                displayName: "file-\(index).txt",
                submissionText: "/tmp/file-\(index).txt",
                submissionPath: "/tmp/file-\(index).txt",
                localURL: nil
            )
        }
        #expect(textView.insertAttachments(attachments))
        #expect(inlineAttachmentCellCount(in: textView) == 1)

        textView.deleteAttachment(at: 0)

        #expect(textView.inlineAttachments().isEmpty)
        #expect(inlineAttachmentCellCount(in: textView) == 0)
    }

    @Test func imageAttachmentCreatesThumbnailSourceWithoutReadingTheFile() {
        let missingImageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).png")
        let attachment = TextBoxAttachment(
            localURL: missingImageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: missingImageURL)
        )

        #expect(attachment.isImage)
        #expect(attachment.inlineThumbnailSource != nil)
    }

    @Test func largeSessionDraftRestoresEveryFileIntoOneInlineCell() {
        let attachmentParts = (0..<1_000).map { index in
            SessionTextBoxInputDraftPart.attachment(
                SessionTextBoxInputAttachmentSnapshot(
                    displayName: "file-\(index).txt",
                    submissionText: "/tmp/file-\(index).txt",
                    submissionPath: "/tmp/file-\(index).txt",
                    localPath: nil,
                    cleanupLocalPathWhenDisposed: false
                )
            )
        }
        let draft = SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("before ")] + attachmentParts + [.text(" after")]
        )
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 30)
        )
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor

        textView.installSessionDraft(draft)

        #expect(textView.inlineAttachments().count == 1_000)
        #expect(inlineAttachmentCellCount(in: textView) == 1)
        #expect(textView.plainText() == "before  after")
    }

    @Test func exactDraftSnapshotDoesNotDuplicateTrailingText() throws {
        let attachment = TextBoxAttachment(
            displayName: "first.txt",
            submissionText: "/tmp/first.txt",
            submissionPath: "/tmp/first.txt",
            localURL: nil
        )
        let attachmentSnapshot = SessionTextBoxInputAttachmentSnapshot(attachment)
        let expectedParts: [SessionTextBoxInputDraftPart] = [
            .attachment(attachmentSnapshot),
            .text("describe this"),
        ]
        let cache = TerminalPanelTextBoxDraftCache()

        cache.recordExactSnapshot(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: expectedParts
        ))
        cache.updateText("describe this")

        #expect(try #require(cache.currentSnapshot()).parts == expectedParts)
    }

    @Test func attachmentUpdatePreservesExactDraftPartOrdering() throws {
        let first = TextBoxAttachment(
            displayName: "first.txt",
            submissionText: "/tmp/first.txt",
            submissionPath: "/tmp/first.txt",
            localURL: nil
        )
        let second = TextBoxAttachment(
            displayName: "second.txt",
            submissionText: "/tmp/second.txt",
            submissionPath: "/tmp/second.txt",
            localURL: nil
        )
        let added = TextBoxAttachment(
            displayName: "added.txt",
            submissionText: "/tmp/added.txt",
            submissionPath: "/tmp/added.txt",
            localURL: nil
        )
        let firstPart = SessionTextBoxInputDraftPart.attachment(
            SessionTextBoxInputAttachmentSnapshot(first)
        )
        let secondPart = SessionTextBoxInputDraftPart.attachment(
            SessionTextBoxInputAttachmentSnapshot(second)
        )
        let addedPart = SessionTextBoxInputDraftPart.attachment(
            SessionTextBoxInputAttachmentSnapshot(added)
        )
        let cache = TerminalPanelTextBoxDraftCache()

        cache.recordExactSnapshot(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [firstPart, .text("compare"), secondPart]
        ))
        cache.updateAttachments([first, second, added])

        #expect(
            try #require(cache.currentSnapshot()).parts
                == [firstPart, .text("compare"), secondPart, addedPart]
        )
    }

    private func inlineAttachmentCellCount(in textView: TextBoxInputTextView) -> Int {
        var count = 0
        let attributed = textView.attributedString()
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, _ in
            if value is TextBoxInlineTextAttachment {
                count += 1
            }
        }
        return count
    }

    @Test func identicalRefreshReusesRenderedChipImage() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let textView = fixture.makeTextView(attachments: [fixture.firstAttachment])
        let inlineAttachment = try #require(fixture.inlineAttachments(in: textView).first)
        let initialImage = try fixture.renderedImage(for: inlineAttachment)

        textView.refreshInlineAttachmentCells(
            font: try #require(textView.font),
            foregroundColor: try #require(textView.textColor)
        )

        let refreshedImage = try fixture.renderedImage(for: inlineAttachment)
        #expect(
            refreshedImage === initialImage,
            "An unchanged inline attachment should reuse its rendered chip bitmap."
        )
    }

    @Test func focusingOneAttachmentDoesNotRefreshUnchangedAttachment() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let textView = fixture.makeTextView(
            attachments: [fixture.firstAttachment, fixture.secondAttachment]
        )
        let inlineAttachments = fixture.inlineAttachments(in: textView)
        let first = try #require(inlineAttachments.first)
        let second = try #require(inlineAttachments.last)
        let focusedCellBeforeSelection = try #require(first.attachmentCell)
        let unchangedCell = try #require(second.attachmentCell)
        let firstLocation = try #require(fixture.location(of: first, in: textView))

        textView.selectAttachment(at: firstLocation)

        #expect(first.attachmentCell !== focusedCellBeforeSelection)
        #expect(
            second.attachmentCell === unchangedCell,
            "Changing focus should refresh only the attachment whose visual focus state changed."
        )
    }

    @Test func thumbnailNormalizationRunsOnceOffMainActor() async throws {
        let normalizer = RecordingThumbnailNormalizer()
        let source = TextBoxInlineAttachmentThumbnailSource(
            fileURL: URL(fileURLWithPath: "/unused/image.png"),
            normalizer: normalizer
        )
        let pixelSize = TextBoxInlineAttachmentThumbnailSize(width: 32, height: 32)

        _ = await source.thumbnail(pixelSize: pixelSize)
        _ = await source.thumbnail(pixelSize: pixelSize)

        #expect(normalizer.invocationCount == 1)
        #expect(normalizer.didRunOnMainThread == false)
    }

    @Test func deletingOneDuplicateAttachmentStillRefreshesTheRemainingThumbnail() async throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let textView = fixture.makeTextView(
            attachments: [fixture.firstAttachment, fixture.firstAttachment]
        )
        let inlineAttachments = fixture.inlineAttachments(in: textView)
        let first = try #require(inlineAttachments.first)
        let remaining = try #require(inlineAttachments.last)
        let firstLocation = try #require(fixture.location(of: first, in: textView))

        textView.deleteAttachment(at: firstLocation)

        let placeholder = try fixture.renderedImage(for: remaining)
        #expect(
            await fixture.waitForRenderedImageChange(
                from: placeholder,
                for: remaining
            ),
            "Deleting one occurrence must not cancel thumbnail rendering for another occurrence."
        )
    }

    @Test func directUndoRequeuesAThumbnailRequestCancelledByDeletion() async throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let textView = fixture.makeTextView(
            attachments: [fixture.firstAttachment],
            allowsUndo: true
        )
        let inlineAttachment = try #require(fixture.inlineAttachments(in: textView).first)
        let location = try #require(fixture.location(of: inlineAttachment, in: textView))
        let undoManager = try #require(textView.undoManager)
        undoManager.removeAllActions()

        textView.deleteAttachment(at: location)
        undoManager.undo()

        let restoredAttachment = try #require(fixture.inlineAttachments(in: textView).first)
        let placeholder = try fixture.renderedImage(for: restoredAttachment)
        #expect(
            await fixture.waitForRenderedImageChange(
                from: placeholder,
                for: restoredAttachment
            ),
            "Undo must retry a request whose previous in-flight task was cancelled."
        )
    }
}

// The source actor serializes writes, and the test reads only after awaiting both calls.
private final class RecordingThumbnailNormalizer:
    TextBoxInlineAttachmentThumbnailNormalizing,
    @unchecked Sendable
{
    private(set) var invocationCount = 0
    private(set) var didRunOnMainThread = false

    func normalizedThumbnail(
        for fileURL: URL,
        pixelSize: TextBoxInlineAttachmentThumbnailSize
    ) -> TextBoxInlineAttachmentThumbnailPixels? {
        invocationCount += 1
        didRunOnMainThread = Thread.isMainThread
        return TextBoxInlineAttachmentThumbnailPixels(
            size: pixelSize,
            bytesPerRow: pixelSize.width * 4,
            rgba8: Data(repeating: 0, count: pixelSize.width * pixelSize.height * 4)
        )
    }
}

@MainActor
private final class AttachmentFixture {
    let directoryURL: URL
    let firstAttachment: TextBoxAttachment
    let secondAttachment: TextBoxAttachment
    private var window: NSWindow?

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-inline-attachment-rendering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let firstURL = directoryURL.appendingPathComponent("first.png")
        let secondURL = directoryURL.appendingPathComponent("second.png")
        try Self.writeImage(to: firstURL, color: .systemRed)
        try Self.writeImage(to: secondURL, color: .systemBlue)
        firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )
    }

    func cleanup() {
        window?.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func makeTextView(
        attachments: [TextBoxAttachment],
        allowsUndo: Bool = false
    ) -> TextBoxInputTextView {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 30)
        )
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = allowsUndo
        if allowsUndo {
            let scrollView = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 420, height: 30)
            )
            scrollView.documentView = textView
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 30),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            window.makeFirstResponder(textView)
            self.window = window
        }
        textView.insertAttachments(attachments)
        return textView
    }

    func inlineAttachments(in textView: TextBoxInputTextView) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        let attributed = textView.attributedString()
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                result.append(attachment)
            }
        }
        return result
    }

    func renderedImage(for attachment: NSTextAttachment) throws -> NSImage {
        let cell = try #require(attachment.attachmentCell as? NSTextAttachmentCell)
        return try #require(cell.image)
    }

    func waitForRenderedImageChange(
        from initialImage: NSImage,
        for attachment: NSTextAttachment
    ) async -> Bool {
        for _ in 0..<10_000 {
            await Task.yield()
            guard let cell = attachment.attachmentCell as? NSTextAttachmentCell,
                  let image = cell.image else {
                continue
            }
            if image !== initialImage {
                return true
            }
        }
        return false
    }

    func location(
        of target: NSTextAttachment,
        in textView: TextBoxInputTextView
    ) -> Int? {
        let attributed = textView.attributedString()
        var result: Int?
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, stop in
            guard let attachment = value as? NSTextAttachment,
                  attachment === target else {
                return
            }
            result = range.location
            stop.pointee = true
        }
        return result
    }

    private static func writeImage(to url: URL, color: NSColor) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw FixtureError.imageCreationFailed
        }
        bitmap.size = NSSize(width: 32, height: 32)
        for x in 0..<32 {
            for y in 0..<32 {
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureError.imageCreationFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private enum FixtureError: Error {
        case imageCreationFailed
    }
}
