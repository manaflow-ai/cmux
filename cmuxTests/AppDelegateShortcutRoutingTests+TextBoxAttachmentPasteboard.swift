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

// MARK: - Text box attachment pasteboard tests
extension AppDelegateShortcutRoutingTests {
    func testTextBoxCutAttachmentPreservesClipboardFile() throws {
        try withPreservedGeneralPasteboard {
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
            textView.cut(nil)

            XCTAssertTrue(textView.inlineAttachments().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), durableURL.absoluteString)
            XCTAssertEqual(
                NSPasteboard.general.string(forType: .string),
                TextBoxAttachment.submissionText(forLocalFileURL: durableURL)
            )
        }
    }

    func testTextBoxCutRestoredAttachmentClearsDeferredCleanup() throws {
        try withPreservedGeneralPasteboard {
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

            textView.installDebugInlineFixture(snapshot.textBoxAttachment(), beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "close_first_attachment")
            XCTAssertTrue(textView.undoManager?.canUndo == true)
            textView.undoManager?.undo()
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

            _ = textView.debugInteract(action: "select_first_attachment")
            textView.cut(nil)

            XCTAssertTrue(textView.inlineAttachments().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
            XCTAssertEqual(NSPasteboard.general.string(forType: .fileURL), durableURL.absoluteString)

            textView.prepareForSubmit()
            textView.discardUndoHistoryAndCleanupPendingAttachmentFiles()

            XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        }
    }

    func testTextBoxRepastedDraftCopyRemainsDisposable() throws {
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

        let repastedAttachment = TextBoxAttachment(
            localURL: durableURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: durableURL),
            cleanupLocalURLWhenDisposed: TextBoxAttachment.shouldCleanupLocalURLWhenDisposed(durableURL)
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([repastedAttachment])

        XCTAssertTrue(TextBoxAttachment.shouldCleanupLocalURLWhenDisposed(durableURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        _ = textView.debugInteract(action: "close_first_attachment")
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
    }

    func testTextBoxPasteboardRestorationSkipsAfterUserClipboardChange() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let fileURL = try makeTemporaryPNGFile(named: "moon.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        let token = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )
        XCTAssertTrue(TextBoxPasteboardRestorationGuard.shouldRestore(pasteboard: pasteboard, token: token))

        pasteboard.clearContents()
        pasteboard.setString("new user clipboard", forType: .string)

        XCTAssertFalse(TextBoxPasteboardRestorationGuard.shouldRestore(pasteboard: pasteboard, token: token))
    }

    func testTextBoxPasteboardRestorationAllowsSameTemporaryFileAfterChangeCountAdvance() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let fileURL = try makeTemporaryPNGFile(named: "moon.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        let token = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: fileURL,
            to: pasteboard
        )
        let staleChangeCountToken = TextBoxPasteboardRestorationToken(
            changeCount: token.changeCount - 1,
            fileURL: token.fileURL
        )

        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.shouldRestore(
                pasteboard: pasteboard,
                token: staleChangeCountToken
            )
        )
    }

    func testTextBoxPasteboardRestorationRecognizesUserChangeBetweenTemporaryWrites() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.textbox.restore.\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstURL as NSURL]))
        let firstToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: firstURL,
            to: pasteboard
        )
        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: firstToken
            )
        )

        pasteboard.clearContents()
        pasteboard.setString("new user clipboard", forType: .string)
        XCTAssertFalse(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: firstToken
            )
        )
        let userClipboardSnapshot = snapshotPasteboardItems(pasteboard)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([secondURL as NSURL]))
        let secondToken = TextBoxPasteboardRestorationGuard.token(
            afterWritingTemporaryFileURL: secondURL,
            to: pasteboard
        )
        XCTAssertTrue(
            TextBoxPasteboardRestorationGuard.isCurrentTemporaryWrite(
                pasteboard: pasteboard,
                token: secondToken
            )
        )

        restorePasteboardItems(userClipboardSnapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user clipboard")
    }

    func testTextBoxFocusedAttachmentCopyCutPasteUseFilePasteboard() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let replacementURL = try makeTemporaryPNGFile(named: "sun.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.onPaste = { pasteboard, textView in
            switch TerminalImageTransferPlanner.prepare(pasteboard: pasteboard, mode: .paste) {
            case .fileURLs(let fileURLs):
                textView.insertAttachments(
                    fileURLs.map {
                        TextBoxAttachment(
                            localURL: $0,
                            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0)
                        )
                    }
                )
                return true
            case .insertText(let text):
                textView.insertText(text, replacementRange: textView.selectedRange())
                return true
            case .reject:
                return false
            }
        }

        guard let copyEvent = makeKeyDownEvent(
            key: "c",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: 0
        ), let cutEvent = makeKeyDownEvent(
            key: "x",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_X),
            windowNumber: 0
        ), let pasteEvent = makeKeyDownEvent(
            key: "v",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_V),
            windowNumber: 0
        ) else {
            XCTFail("Failed to construct edit command events")
            return
        }

        try withPreservedGeneralPasteboard {
            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")

            XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1))
            XCTAssertTrue(textView.performKeyEquivalent(with: copyEvent))
            XCTAssertEqual(PasteboardFileURLReader.fileURLs(from: .general).map(\.path), [originalURL.path])
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["moon.png"])

            XCTAssertTrue(textView.performKeyEquivalent(with: cutEvent))
            XCTAssertEqual(PasteboardFileURLReader.fileURLs(from: .general).map(\.path), [originalURL.path])
            XCTAssertTrue(textView.inlineAttachments().isEmpty)

            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")
            writeFileURLs([replacementURL], to: .general)

            XCTAssertTrue(textView.performKeyEquivalent(with: pasteEvent))
            XCTAssertEqual(textView.inlineAttachments().map(\.displayName), ["sun.png"])
            XCTAssertEqual(
                textView.submissionText(),
                expectedImageSubmission(before: "hello ", url: replacementURL, after: " world")
            )
        }
    }

    func testTextBoxFocusedAttachmentCopyFollowsSelectionAfterSelectionChanges() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor

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

        guard let copyEvent = makeKeyDownEvent(
            key: "c",
            modifiers: .command,
            keyCode: UInt16(kVK_ANSI_C),
            windowNumber: window.windowNumber
        ) else {
            XCTFail("Failed to construct copy event")
            return
        }

        try withPreservedGeneralPasteboard {
            textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
            _ = textView.debugInteract(action: "select_first_attachment")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1))

            textView.setSelectedRange(NSRange(location: 0, length: 5))
            textView.refreshInlineAttachmentFocus()
            NSPasteboard.general.clearContents()

            XCTAssertTrue(textView.performKeyEquivalent(with: copyEvent))
            XCTAssertTrue(PasteboardFileURLReader.fileURLs(from: .general).isEmpty)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")
        }
    }

    func testTextBoxFocusedAttachmentClearsWhenTextBoxLosesFocus() throws {
        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TerminalImageTransferPlanner.escapeForShell(originalURL.path)
        )

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        scrollView.documentView = textView
        let otherView = FocusableTestView(frame: NSRect(x: 0, y: 32, width: 24, height: 24))
        contentView.addSubview(scrollView)
        contentView.addSubview(otherView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.makeFirstResponder(textView)
        Self.retainedTextBoxUndoWindows.append(window)

        textView.installDebugInlineFixture(originalAttachment, beforeText: "hello ", afterText: " world")
        let focusedState = textView.debugInteract(action: "select_first_attachment")
        XCTAssertEqual(focusedState["focused_attachment_index"] as? Int, 6)

        XCTAssertTrue(window.makeFirstResponder(otherView))
        let unfocusedState = textView.debugInteractionState()
        XCTAssertEqual(unfocusedState["focused_attachment_index"] as? Int, -1)
    }

    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    func withPreservedGeneralPasteboard(_ body: () throws -> Void) throws {
        let pasteboard = NSPasteboard.general
        let snapshots = snapshotPasteboardItems(pasteboard)
        defer {
            restorePasteboardItems(snapshots, to: pasteboard)
        }
        try body()
    }

    private func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        pasteboard.pasteboardItems?.map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            )
        } ?? []
    }

    private func restorePasteboardItems(
        _ snapshots: [PasteboardItemSnapshot],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func writeFileURLs(
        _ fileURLs: [URL],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        pasteboard.declareTypes(
            [.fileURL, PasteboardFileURLReader.legacyFilenamesPboardType, .string],
            owner: nil
        )
        if let firstURL = fileURLs.first {
            pasteboard.setString(firstURL.absoluteString, forType: .fileURL)
        }
        pasteboard.setPropertyList(
            fileURLs.map(\.path),
            forType: PasteboardFileURLReader.legacyFilenamesPboardType
        )
        pasteboard.setString(
            TerminalImageTransferPlanner.insertedText(forFileURLs: fileURLs),
            forType: .string
        )
    }

}
