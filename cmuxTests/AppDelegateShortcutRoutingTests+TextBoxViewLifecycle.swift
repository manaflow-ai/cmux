import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Text box view remount and pending upload lifecycle tests
extension AppDelegateShortcutRoutingTests {
    func testTextBoxInlineAttachmentsSurviveViewRemount() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        let remountedTextView = makeRetainedTextBoxInputTextView()
        terminalPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "hello ", url: originalURL, after: " world")
        )
    }

    func testTextBoxPendingAttachmentUploadIsStrippedWhenPreservedForRemount() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = originalTextView
        let textBoxWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        textBoxWindow.isReleasedWhenClosed = false
        textBoxWindow.contentView = scrollView
        textBoxWindow.makeFirstResponder(originalTextView)
        Self.retainedTextBoxUndoWindows.append(textBoxWindow)

        originalTextView.string = "hello world"
        originalTextView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        originalTextView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        let uploadToken = originalTextView.pendingAttachmentUploadValidationToken()
        XCTAssertTrue(originalTextView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertTrue(originalTextView.canAcceptPendingAttachmentUpload(validationToken: uploadToken))

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        XCTAssertFalse(originalTextView.canAcceptPendingAttachmentUpload(validationToken: uploadToken))

        let remountedTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        terminalPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertFalse(remountedTextView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertEqual(remountedTextView.submissionText(), "hello world")
    }

    func testTextBoxRepresentableDismantleDoesNotWriteSwiftUIBindings() {
        var text = "old"
        var attachments: [TextBoxAttachment] = []
        var height: CGFloat = 24
        var hasPendingAttachmentUpload = true
        var textWriteCount = 0
        var attachmentWriteCount = 0
        var heightWriteCount = 0
        var pendingWriteCount = 0
        var dismantledText: String?

        let inputView = TextBoxInputView(
            text: Binding(
                get: { text },
                set: { newValue in
                    textWriteCount += 1
                    text = newValue
                }
            ),
            attachments: Binding(
                get: { attachments },
                set: { newValue in
                    attachmentWriteCount += 1
                    attachments = newValue
                }
            ),
            textViewHeight: Binding(
                get: { height },
                set: { newValue in
                    heightWriteCount += 1
                    height = newValue
                }
            ),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { newValue in
                    pendingWriteCount += 1
                    hasPendingAttachmentUpload = newValue
                }
            ),
            font: NSFont.systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "codex",
            completionRootDirectory: nil,
            onSubmit: {},
            onEscape: {},
            onFocusTextBox: {},
            onToggleFocus: {},
            onForwardText: { _, _ in },
            onForwardKey: { _ in },
            onForwardControl: { _ in },
            onPaste: { _, _ in false },
            onInsertFileURLs: { _, _ in false },
            onChooseFiles: {},
            onContentChanged: {},
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { textView in
                dismantledText = textView.plainText()
            }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "preserve this"
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView

        TextBoxInputView.dismantleNSView(
            scrollView,
            coordinator: TextBoxInputView.Coordinator(parent: inputView)
        )

        XCTAssertEqual(dismantledText, "preserve this")
        XCTAssertEqual(textWriteCount, 0)
        XCTAssertEqual(attachmentWriteCount, 0)
        XCTAssertEqual(heightWriteCount, 0)
        XCTAssertEqual(pendingWriteCount, 0)
    }

    func testTextBoxPendingAttachmentUploadPreservesOriginalInsertionPoint() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forPath: "/tmp/remote/moon.png"),
            submissionPath: "/tmp/remote/moon.png"
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertEqual(textView.plainText(), "hello world")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("say ", replacementRange: textView.selectedRange())

        XCTAssertTrue(textView.replacePendingAttachmentUploadPlaceholder(id: uploadID, with: [originalAttachment]))
        XCTAssertEqual(
            textView.submissionText(),
            "say hello /tmp/remote/moon.png world"
        )
    }

    func testTextBoxPendingAttachmentUploadQueuesDurableDraftCopyForOwnedTemporaryImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/remote/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )
        addTeardownBlock {
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)

        XCTAssertTrue(textView.replacePendingAttachmentUploadPlaceholder(id: uploadID, with: [attachment]))
        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])

        let draft = try XCTUnwrap(textView.sessionDraftSnapshot(isActive: true))
        let snapshot = try XCTUnwrap(draft.parts.first?.attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertEqual(snapshot.submissionPath, remotePath)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
    }

    func testTextBoxPendingAttachmentUploadRemovalCleansPlaceholder() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))

        let uploadID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: uploadID)
        XCTAssertTrue(textView.hasPendingAttachmentUploadPlaceholder())

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("say ", replacementRange: textView.selectedRange())

        XCTAssertTrue(textView.removePendingAttachmentUploadPlaceholder(id: uploadID))
        XCTAssertFalse(textView.hasPendingAttachmentUploadPlaceholder())
        XCTAssertEqual(textView.plainText(), "say hello world")
        XCTAssertEqual(textView.submissionText(), "say hello world")
    }

    func testTextBoxAttachmentCloseIsUndoable() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            textView.submissionText(),
            expectedImageSubmission(before: "hello ", url: originalURL, after: " world")
        )
    }

    func testTextBoxPendingAttachmentUploadInvalidatesOnClear() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        let token = textView.pendingAttachmentUploadValidationToken()
        XCTAssertTrue(textView.canAcceptPendingAttachmentUpload(validationToken: token))

        textView.clearContent()

        XCTAssertFalse(textView.canAcceptPendingAttachmentUpload(validationToken: token))
    }

}
