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

// MARK: - Text box attachment draft-copy cleanup tests
extension AppDelegateShortcutRoutingTests {
    func testTextBoxDraftCopyIsRemovedWhenOriginalTemporaryAttachmentIsDisposed() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.cleanupDisposableAttachmentFiles([attachment])

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxLocalPathSubmitDropsDraftCopyButKeepsSubmittedFile() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).isEmpty
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.cleanupCopiedDraftFilesForPreservedLocalPathSubmissions([attachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxDraftCopyIsRemovedWhenAttachmentPillIsDeleted() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
    }

    func testTextBoxKeyboardDeleteAttachmentCleansDraftCopy() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])
        _ = textView.debugInteract(action: "select_first_attachment")

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxTypingOverSelectedAttachmentCleansDisposableFile() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        addTeardownBlock {
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = false
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
        textView.installDebugInlineFixture(attachment, beforeText: "hello ", afterText: " world")
        _ = textView.debugInteract(action: "select_first_attachment")

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        guard let keyEvent = makeKeyDownEvent(
            key: "x",
            modifiers: [],
            keyCode: UInt16(kVK_ANSI_X),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct key event")
            return
        }
        textView.keyDown(with: keyEvent)

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertEqual(textView.plainText(), "hello x world")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testTextBoxKeyboardDeleteTextSelectionAfterAttachmentKeepsAttachment() {
        let attachment = TextBoxAttachment(
            displayName: "moon.png",
            submissionText: "[Image #1]",
            submissionPath: "/tmp/moon.png",
            localURL: nil
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: "hello ", afterText: " world")

        let selectionStart = ("hello " as NSString).length + 1
        textView.setSelectedRange(NSRange(location: selectionStart, length: (" world" as NSString).length))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(textView.plainText(), "hello ")
    }

    func testTextBoxUndoableDraftAttachmentDeleteDefersCleanupUntilDismantle() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

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

        textView.installDebugInlineFixture(restoredAttachment, beforeText: "hello ", afterText: " world")
        _ = textView.debugInteract(action: "close_first_attachment")

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            textView.submissionText(),
            expectedImageSubmission(before: "hello ", url: durableURL, after: " world")
        )
        textView.cleanupPendingUndoableAttachmentFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        _ = textView.debugInteract(action: "close_first_attachment")
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxPrepareForSubmitFlushesDeletedAttachmentCleanup() throws {
        let deletedTemporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let inlineTemporaryURL = try makeTemporaryPNGFile(named: "sun.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(deletedTemporaryURL)
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(inlineTemporaryURL)
        let deletedAttachment = TextBoxAttachment(
            localURL: deletedTemporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: deletedTemporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let inlineAttachment = TextBoxAttachment(
            localURL: inlineTemporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: inlineTemporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let deletedSnapshot = try preparedSessionAttachmentSnapshot(deletedAttachment)
        let inlineSnapshot = try preparedSessionAttachmentSnapshot(inlineAttachment)
        let deletedDurablePath = try XCTUnwrap(deletedSnapshot.localPath)
        let inlineDurablePath = try XCTUnwrap(inlineSnapshot.localPath)
        let deletedDurableURL = URL(fileURLWithPath: deletedDurablePath).standardizedFileURL
        let inlineDurableURL = URL(fileURLWithPath: inlineDurablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: deletedDurableURL)
            try? FileManager.default.removeItem(at: inlineDurableURL)
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([deletedTemporaryURL, inlineTemporaryURL])
        }

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

        textView.insertAttachments([deletedSnapshot.textBoxAttachment()])
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedDurableURL.path))
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.insertAttachments([inlineSnapshot.textBoxAttachment()])
        textView.prepareForSubmit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedDurableURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inlineDurableURL.path))
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["sun.png"])
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testTextBoxPrepareForSubmitDropsPendingCleanupForRestoredAttachment() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

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

        textView.installDebugInlineFixture(
            snapshot.textBoxAttachment(),
            beforeText: "hello ",
            afterText: " world"
        )
        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

        textView.prepareForSubmit()
        textView.clearContent(cleanupAttachmentFiles: false)
        textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxSubmitClearDefersDraftCopyCleanup() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL)
        )
        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }
        let restoredAttachment = snapshot.textBoxAttachment()

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([restoredAttachment])

        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        textView.clearContent(cleanupAttachmentFiles: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).isEmpty
        )
        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:claude"
            ).isEmpty
        )
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(restoredAttachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        restoredAttachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )

        textView.cleanupDisposableAttachmentFiles([restoredAttachment])
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxSubmitCleanupPreservesReinsertedActiveAttachment() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(imageURL)
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL),
            cleanupLocalURLWhenDisposed: true
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.installDebugInlineFixture(
            attachment,
            beforeText: "new ",
            afterText: " prompt"
        )

        textView.cleanupDisposableAttachmentFiles([attachment])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imageURL.path),
            "Async submit cleanup must not delete a disposable file that is active in the next prompt"
        )

        textView.clearContent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testTextBoxSubmitCleanupDisposesSynchronousRemoteAttachmentAfterEditorClears() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.installDebugInlineFixture(
            attachment,
            beforeText: "describe ",
            afterText: ""
        )

        textView.prepareForSubmit()
        textView.clearContent(cleanupAttachmentFiles: false)
        let cleanupAttachments = TextBoxSubmit.cleanupAttachmentsAfterSubmit(
            from: [.attachment(attachment)],
            terminalAgentContext: "restoredAgent:opencode"
        )
        textView.cleanupDisposableAttachmentFiles(cleanupAttachments)

        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testTextBoxSubmitCleanupCanDisposeRemotePreviewImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:opencode"
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSubmitCleanupKeepsClaudeImageUntilTokenIsConfirmed() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        XCTAssertTrue(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude"
            ).isEmpty
        )
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        attachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )
    }

}
