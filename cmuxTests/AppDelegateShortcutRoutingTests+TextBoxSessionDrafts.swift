import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import Observation
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Text box session draft persistence and restore tests
extension AppDelegateShortcutRoutingTests {
    func testTextBoxSessionDraftRoundTripsInterspersedImages() throws {
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )

        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello "
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        textView.insertAttachments([firstAttachment])
        textView.insertText(" middle ", replacementRange: textView.selectedRange())
        textView.insertAttachments([secondAttachment])
        textView.insertText(" done", replacementRange: textView.selectedRange())

        let draft = try XCTUnwrap(textView.sessionDraftSnapshot(isActive: true))
        let terminalSnapshot = SessionTerminalPanelSnapshot(
            workingDirectory: "/tmp",
            scrollback: nil,
            agent: nil,
            tmuxStartCommand: nil,
            textBoxDraft: draft
        )

        let data = try JSONEncoder().encode(terminalSnapshot)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        let decodedDraft = try XCTUnwrap(decoded.textBoxDraft)
        XCTAssertEqual(decodedDraft, draft)

        let restoredTextView = makeRetainedTextBoxInputTextView()
        restoredTextView.font = NSFont.systemFont(ofSize: 14)
        restoredTextView.textColor = .labelColor
        restoredTextView.installSessionDraft(decodedDraft)

        XCTAssertEqual(restoredTextView.inlineAttachments().map(\.displayName), ["moon.png", "sun.png"])
        XCTAssertEqual(
            submissionPartSummaries(restoredTextView.submissionParts()),
            submissionPartSummaries(textView.submissionParts())
        )
        XCTAssertEqual(restoredTextView.submissionText(), textView.submissionText())
    }

    func testTextBoxSessionDraftCopiesOwnedTemporaryImageToDurableStorage() throws {
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

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertEqual(snapshot.submissionPath, durableURL.path)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forLocalFileURL: durableURL))
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)

        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let restoredAttachment = snapshot.textBoxAttachment()
        XCTAssertEqual(restoredAttachment.localURL?.standardizedFileURL.path, durableURL.path)
        XCTAssertEqual(restoredAttachment.submissionPath, durableURL.path)
    }

    func testTextBoxSessionDraftSnapshotDoesNotSynchronouslyCopyUnpreparedTemporaryImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        addTeardownBlock {
            attachment.debugCancelSessionDraftCopyForTesting()
            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let snapshot = SessionTextBoxInputAttachmentSnapshot(attachment)

        let durablePath = try XCTUnwrap(snapshot.localPath)
        XCTAssertNotEqual(durablePath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, durablePath)
        XCTAssertEqual(
            snapshot.submissionText,
            TextBoxAttachment.submissionText(forLocalFileURL: URL(fileURLWithPath: durablePath))
        )
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)
    }

    func testTextBoxSessionDraftKeepsOwnedTemporaryImageWhenDurableCopyFails() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )

        try FileManager.default.removeItem(at: temporaryURL)
        let draft = try XCTUnwrap(
            TextBoxInputTextView.sessionDraftSnapshot(
                text: "",
                attachments: [attachment],
                isActive: true
            )
        )
        let snapshot = try XCTUnwrap(draft.parts.first?.attachment)

        XCTAssertEqual(draft.parts.count, 1)
        XCTAssertEqual(snapshot.localPath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL))
        XCTAssertTrue(snapshot.cleanupLocalPathWhenDisposed)
    }

    func testTextBoxSessionDraftPreservesRemoteSubmissionPathWhenCopyingPreviewImage() throws {
        let temporaryURL = try makeTemporaryPNGFile(named: "moon.png")
        GhosttyPasteboardHelper.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        let snapshot = try preparedSessionAttachmentSnapshot(attachment)
        let durablePath = try XCTUnwrap(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: durableURL)
        }

        XCTAssertNotEqual(durableURL.path, temporaryURL.path)
        XCTAssertEqual(snapshot.submissionPath, remotePath)
        XCTAssertEqual(snapshot.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        let restoredAttachment = snapshot.textBoxAttachment()
        XCTAssertEqual(restoredAttachment.localURL?.standardizedFileURL.path, durableURL.path)
        XCTAssertEqual(restoredAttachment.submissionPath, remotePath)
        XCTAssertEqual(restoredAttachment.submissionText, TextBoxAttachment.submissionText(forPath: remotePath))
    }

    func testTextBoxSessionDraftRejectsInvalidPartPayloads() throws {
        let invalidTextPart = Data("""
        {
          "kind": "text",
          "attachment": {
            "displayName": "moon.png",
            "submissionText": "/tmp/moon.png",
            "submissionPath": "/tmp/moon.png",
            "localPath": "/tmp/moon.png",
            "cleanupLocalPathWhenDisposed": false
          }
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionTextBoxInputDraftPart.self, from: invalidTextPart))

        let invalidAttachmentPart = Data("""
        {
          "kind": "attachment",
          "text": "moon"
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionTextBoxInputDraftPart.self, from: invalidAttachmentPart))
    }

    func testTerminalPanelPreservesTextBoxDraftForUnmountWithoutPublishing() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))
        let originalTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        originalTextView.string = "preserve this"

        // `TerminalPanel` is `@Observable` (no `objectWillChange`); assert no
        // change notification fires for any view-facing (formerly
        // `@Published`) panel state during unmount preservation.
        final class ChangeFlag: @unchecked Sendable { var didChange = false }
        let flag = ChangeFlag()
        withObservationTracking {
            _ = terminalPanel.title
            _ = terminalPanel.directory
            _ = terminalPanel.tmuxLayoutReport
            _ = terminalPanel.isTextBoxActive
            _ = terminalPanel.textBoxContent
            _ = terminalPanel.textBoxAttachments
            _ = terminalPanel.searchState
            _ = terminalPanel.viewReattachToken
            _ = terminalPanel.agentHibernationState
        } onChange: {
            flag.didChange = true
        }

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)

        let draft = try XCTUnwrap(terminalPanel.sessionTextBoxDraftSnapshot())
        XCTAssertEqual(textBoxSessionDraftPartSummaries(draft.parts), [.text("preserve this")])
        XCTAssertFalse(
            flag.didChange,
            "TextBox unmount preservation runs from NSViewRepresentable.dismantleNSView and must not publish during SwiftUI teardown"
        )
    }

    func testTerminalPanelCloseDisposesTextBoxAttachmentDrafts() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

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
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: durableURL)
        }

        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: "close ", afterText: " draft")
        terminalPanel.registerTextBoxInputView(textView)
        terminalPanel.isTextBoxActive = true

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableURL.path))

        terminalPanel.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: durableURL.path))
        XCTAssertNil(terminalPanel.sessionTextBoxDraftSnapshot())
        XCTAssertTrue(textView.inlineAttachments().isEmpty)
    }

    func testWorkspaceSessionRestoreRestoresActiveTextBoxDraftWithImage() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )
        let originalTextView = makeRetainedTextBoxInputTextView()
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "restore ", afterText: " now")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)
        terminalPanel.isTextBoxActive = true

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.terminal?.textBoxDraft?.isActive, true)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: restoredPanelId))
        XCTAssertTrue(restoredPanel.isTextBoxActive)

        let remountedTextView = makeRetainedTextBoxInputTextView()
        remountedTextView.font = NSFont.systemFont(ofSize: 14)
        remountedTextView.textColor = .labelColor
        restoredPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "restore ", url: originalURL, after: " now")
        )
    }

    func testWorkspaceSessionRestoreKeepsHiddenTextBoxDraftUntilOpened() throws {
        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal surface")
            return
        }

        let originalURL = try makeTemporaryPNGFile(named: "moon.png")
        let originalAttachment = TextBoxAttachment(
            localURL: originalURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: originalURL)
        )
        let originalTextView = makeRetainedTextBoxInputTextView()
        originalTextView.font = NSFont.systemFont(ofSize: 14)
        originalTextView.textColor = .labelColor
        originalTextView.installDebugInlineFixture(originalAttachment, beforeText: "hidden ", afterText: " draft")

        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)
        terminalPanel.isTextBoxActive = false

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.terminal?.textBoxDraft?.isActive, false)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restoredWorkspace.terminalPanel(for: restoredPanelId))
        XCTAssertFalse(restoredPanel.isTextBoxActive)

        XCTAssertTrue(restoredPanel.focusTextBoxInputOrTerminal())
        let remountedTextView = makeRetainedTextBoxInputTextView()
        remountedTextView.font = NSFont.systemFont(ofSize: 14)
        remountedTextView.textColor = .labelColor
        restoredPanel.registerTextBoxInputView(remountedTextView)

        XCTAssertEqual(remountedTextView.inlineAttachments().map(\.displayName), ["moon.png"])
        XCTAssertEqual(
            remountedTextView.submissionText(),
            expectedImageSubmission(before: "hidden ", url: originalURL, after: " draft")
        )
    }

    func testWorkspaceSessionRestoreRestoresTextBoxDraftsAcrossSplits() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let firstPanel = try XCTUnwrap(workspace.terminalPanel(for: firstPanelId))
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: firstPanelId,
            orientation: .horizontal,
            focus: false
        ))

        try installTextBoxSessionDraft(
            on: firstPanel,
            imageName: "left.png",
            beforeText: "left split ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: secondPanel,
            imageName: "right.png",
            beforeText: "right split ",
            afterText: " draft",
            isActive: false
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.panels.compactMap { $0.terminal?.textBoxDraft }.count, 2)

        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)

        let restoredDrafts = restoredTextBoxDraftSummaries(in: restoredWorkspace)
        XCTAssertEqual(Set(restoredDrafts), Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("left split "), .attachment("left.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: false, parts: [.text("right split "), .attachment("right.png"), .text(" draft")])
        ]))
    }

    func testTabManagerSessionRestoreRestoresTextBoxDraftsAcrossWorkspaces() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let firstWorkspace = try XCTUnwrap(manager.tabs.first)
        let secondWorkspace = manager.addWorkspace(
            title: "Second",
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        )

        try installTextBoxSessionDraft(
            on: XCTUnwrap(firstWorkspace.focusedTerminalPanel),
            imageName: "first-workspace.png",
            beforeText: "first workspace ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: XCTUnwrap(secondWorkspace.focusedTerminalPanel),
            imageName: "second-workspace.png",
            beforeText: "second workspace ",
            afterText: " draft",
            isActive: false
        )

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restoredManager = TabManager(autoWelcomeIfNeeded: false)
        restoredManager.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restoredManager.tabs.count, 2)
        XCTAssertEqual(restoredManager.selectedTabId, restoredManager.tabs.last?.id)
        XCTAssertEqual(Set(restoredManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:))), Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("first workspace "), .attachment("first-workspace.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: false, parts: [.text("second workspace "), .attachment("second-workspace.png"), .text(" draft")])
        ]))
    }

    func testAppSessionSnapshotRoundTripsTextBoxDraftsAcrossWindows() throws {
        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)

        try installTextBoxSessionDraft(
            on: XCTUnwrap(firstManager.selectedWorkspace?.focusedTerminalPanel),
            imageName: "first-window.png",
            beforeText: "first window ",
            afterText: " draft",
            isActive: true
        )
        try installTextBoxSessionDraft(
            on: XCTUnwrap(secondManager.selectedWorkspace?.focusedTerminalPanel),
            imageName: "second-window.png",
            beforeText: "second window ",
            afterText: " draft",
            isActive: true
        )

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_700_000_000,
            windows: [
                sessionWindowSnapshot(tabManager: firstManager),
                sessionWindowSnapshot(tabManager: secondManager)
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows.count, 2)

        let restoredFirstManager = TabManager(autoWelcomeIfNeeded: false)
        let restoredSecondManager = TabManager(autoWelcomeIfNeeded: false)
        restoredFirstManager.restoreSessionSnapshot(decoded.windows[0].tabManager)
        restoredSecondManager.restoreSessionSnapshot(decoded.windows[1].tabManager)

        let restoredDrafts = Set(
            restoredFirstManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:)) +
            restoredSecondManager.tabs.flatMap(restoredTextBoxDraftSummaries(in:))
        )

        XCTAssertEqual(restoredDrafts, Set([
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("first window "), .attachment("first-window.png"), .text(" draft")]),
            TextBoxSessionDraftSummary(isActive: true, parts: [.text("second window "), .attachment("second-window.png"), .text(" draft")])
        ]))
    }

    private enum TextBoxSessionDraftPartSummary: Hashable {
        case text(String)
        case attachment(String)
    }

    private struct TextBoxSessionDraftSummary: Hashable {
        let isActive: Bool
        let parts: [TextBoxSessionDraftPartSummary]
    }

    private func installTextBoxSessionDraft(
        on terminalPanel: TerminalPanel,
        imageName: String,
        beforeText: String,
        afterText: String,
        isActive: Bool
    ) throws {
        let imageURL = try makeTemporaryPNGFile(named: imageName)
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let textView = makeRetainedTextBoxInputTextView()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.installDebugInlineFixture(attachment, beforeText: beforeText, afterText: afterText)

        terminalPanel.preserveTextBoxContentForUnmount(from: textView)
        terminalPanel.isTextBoxActive = isActive
    }

    private func restoredTextBoxDraftSummaries(in workspace: Workspace) -> [TextBoxSessionDraftSummary] {
        workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .compactMap { panel in
                guard let draft = panel.sessionTextBoxDraftSnapshot() else { return nil }
                return TextBoxSessionDraftSummary(
                    isActive: draft.isActive,
                    parts: textBoxSessionDraftPartSummaries(draft.parts)
                )
            }
    }

    private func textBoxSessionDraftPartSummaries(
        _ parts: [SessionTextBoxInputDraftPart]
    ) -> [TextBoxSessionDraftPartSummary] {
        parts.compactMap { part in
            switch part.kind {
            case .text:
                guard let text = part.text, !text.isEmpty else { return nil }
                return .text(text)
            case .attachment:
                guard let attachment = part.attachment else { return nil }
                return .attachment(attachment.displayName)
            }
        }
    }

}
