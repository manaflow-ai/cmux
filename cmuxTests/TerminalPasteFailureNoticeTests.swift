import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Cmd+V that produces nothing used to be a beep (worker timeout) or silence
/// (image over the 10 MB cap). These pin the two cases that now also get a
/// brief notice, and that every other outcome stays as it was.
@MainActor
@Suite(.serialized)
struct TerminalPasteFailureNoticeTests {
    @Test("an oversized pasteboard image is rejected distinctly on paste")
    func oversizedImagePasteIsDistinct() throws {
        let (pasteboard, directory, service) = try makeOversizedImagePasteboard()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }

        let prepared = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: .paste,
            pasteboardService: service
        )

        #expect(prepared == .rejectOversizedImage)
        #expect(prepared.isRejection)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        // It plans and prepares for the composer exactly like any rejection.
        #expect(TerminalImageTransferPlanner.plan(preparedContent: prepared, target: .local) == .reject)
        #expect(TextBoxPastePreparationService().prepare(preparedContent: prepared) == .reject)
    }

    @Test("an oversized image drop keeps the plain rejection")
    func oversizedImageDropIsUnchanged() throws {
        let (pasteboard, directory, service) = try makeOversizedImagePasteboard()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }

        let prepared = TerminalImageTransferPlanner.prepareSynchronously(
            pasteboard: pasteboard,
            mode: .drop,
            pasteboardService: service
        )

        #expect(prepared == .reject)
    }

    @Test("only an oversized image and a worker timeout get a notice")
    func noticeMapping() {
        func notice(
            _ content: TerminalImageTransferPreparedContent,
            _ failure: TerminalPastePreparationFailure?
        ) -> TerminalPasteFailureNotice? {
            TerminalPasteFailureNotice.notice(
                for: TerminalImageTransferPreparationOutcome(content: content, failure: failure)
            )
        }

        #expect(notice(.rejectOversizedImage, nil) == .imageTooLarge)
        #expect(notice(.reject, .deadlineExceeded) == .timedOut)
        #expect(notice(.reject, nil) == nil)
        #expect(notice(.reject, .cancelled) == nil)
        #expect(notice(.reject, .queueFull) == nil)
        #expect(notice(.reject, .workerFailed) == nil)
        #expect(notice(.insertText("hello"), nil) == nil)
        #expect(notice(.fileURLs([URL(fileURLWithPath: "/tmp/x.png")]), nil) == nil)
    }

    @Test("both notices have text")
    func noticeMessages() {
        #expect(!TerminalPasteFailureNotice.imageTooLarge.message.isEmpty)
        #expect(!TerminalPasteFailureNotice.timedOut.message.isEmpty)
        #expect(TerminalPasteFailureNotice.imageTooLarge.message != TerminalPasteFailureNotice.timedOut.message)
    }

    @Test("the notice is a non-interactive badge over the terminal until dismissed")
    func presenterShowsAndDismissesBadge() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let presenter = TerminalPasteFailureNoticePresenter()

        presenter.show(.imageTooLarge, over: host)

        let badge = try #require(host.subviews.last as? FileDropHintBadgeView)
        #expect(!badge.isHidden)
        #expect(badge.accessibilityLabel() == TerminalPasteFailureNotice.imageTooLarge.message)
        #expect(badge.hitTest(NSPoint(x: badge.frame.midX, y: badge.frame.midY)) == nil)
        #expect(host.bounds.contains(badge.frame))

        // A second notice reuses the same badge instead of stacking another.
        presenter.show(.timedOut, over: host)
        #expect(host.subviews.filter { $0 is FileDropHintBadgeView }.count == 1)
        #expect(badge.accessibilityLabel() == TerminalPasteFailureNotice.timedOut.message)

        presenter.dismiss()
        #expect(badge.superview == nil)
        #expect(badge.isHidden)
    }

    private func makeOversizedImagePasteboard() throws -> (NSPasteboard, URL, TerminalPasteboardService) {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-paste-notice-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Data(count: 10 * 1024 * 1024 + 1), forType: .png)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-paste-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return (pasteboard, directory, TerminalPasteboardService(temporaryDirectory: directory))
    }
}
