import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal panel pending attachments", .serialized)
@MainActor
struct TerminalPanelPendingAttachmentTests {
    @Test
    func pendingAttachmentsAreCoalescedAndBoundedUntilTheViewMounts() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-attachments-\(UUID().uuidString)", isDirectory: true)
        let queuedURLs = (0..<(TerminalPanel.maximumPendingTextBoxAttachmentCount - 1)).map {
            directoryURL.appendingPathComponent("file-\($0).txt")
        }
        let firstURL = try #require(queuedURLs.first)

        #expect(panel.attachFilesToTextBoxInput([firstURL, firstURL]) == .queued)
        #expect(panel.attachFilesToTextBoxInput([firstURL]) == .queued)
        #expect(panel.attachFilesToTextBoxInput(Array(queuedURLs.dropFirst())) == .queued)

        let rejectedURLs = [
            directoryURL.appendingPathComponent("rejected-1.txt"),
            directoryURL.appendingPathComponent("rejected-2.txt"),
        ]
        #expect(panel.attachFilesToTextBoxInput(rejectedURLs) == .queueFull)

        let view = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        var insertionCalls: [[URL]] = []
        view.onInsertFileURLs = { urls, _ in
            insertionCalls.append(urls)
            return true
        }
        panel.registerTextBoxInputView(view)
        #expect(insertionCalls.isEmpty)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.textBoxInputViewDidMoveToWindow(view)

        #expect(insertionCalls.count == 1)
        let insertedURLs = try #require(insertionCalls.first)
        #expect(insertedURLs == queuedURLs.map(\.standardizedFileURL))
        #expect(Set(insertedURLs).isDisjoint(with: rejectedURLs.map(\.standardizedFileURL)))
    }

    @Test
    func failedViewInsertionKeepsTheBoundedBatchForRetry() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-attachment-retry-\(UUID().uuidString).txt")
        #expect(panel.attachFilesToTextBoxInput([fileURL]) == .queued)

        let view = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        var insertionCalls: [[URL]] = []
        view.onInsertFileURLs = { urls, _ in
            insertionCalls.append(urls)
            return insertionCalls.count > 1
        }
        panel.registerTextBoxInputView(view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.textBoxInputViewDidMoveToWindow(view)
        panel.textBoxInputViewDidMoveToWindow(view)
        panel.textBoxInputViewDidMoveToWindow(view)

        let standardizedURL = fileURL.standardizedFileURL
        #expect(insertionCalls == [[standardizedURL], [standardizedURL]])
    }
}
