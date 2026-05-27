import AppKit
import Bonsplit
import Carbon.HIToolbox
import Quartz
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FilePreviewReviewFeedbackTests: XCTestCase {
    func testAppBundleExportsFilePreviewDragType() {
        let declarations = (Bundle(for: AppDelegate.self).object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]) ?? []
        let exported = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })

        XCTAssertTrue(
            exported.contains("com.cmux.filepreview.transfer"),
            "Expected app bundle to export file-preview transfer type, got \(exported)"
        )
    }

    func testSavingTextViewUsesChordedSaveShortcut() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                first: ShortcutStroke(key: "k", command: true, shift: false, option: false, control: false, keyCode: UInt16(kVK_ANSI_K)),
                second: ShortcutStroke(key: "s", command: true, shift: false, option: false, control: false, keyCode: UInt16(kVK_ANSI_S))
            ),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "saved by chord"
        textView.panel = panel
        panel.attachTextView(textView)
        panel.updateTextContent(textView.string)

        let prefixEvent = try XCTUnwrap(keyEvent(key: "k", keyCode: UInt16(kVK_ANSI_K)))
        let suffixEvent = try XCTUnwrap(keyEvent(key: "s", keyCode: UInt16(kVK_ANSI_S)))

        XCTAssertTrue(textView.performKeyEquivalent(with: prefixEvent))
        XCTAssertFalse(panel.isSaving)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertTrue(textView.performKeyEquivalent(with: suffixEvent))
        await waitForPanelSave(panel)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved by chord")
    }

    func testExtensionlessUTF16TextWithBOMResolvesAsTextAfterSniffing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "hello".write(to: url, atomically: true, encoding: .utf16)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testQuickLookSessionCloseDoesNotDeactivateMountedRepresentableView() throws {
        let url = try temporaryBinaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        XCTAssertEqual(panel.previewMode, .quickLook)

        let view = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        guard let previewView = view as? QLPreviewView else {
            return XCTFail("Expected Quick Look to vend a QLPreviewView")
        }
        XCTAssertNotNil(previewView.previewItem)

        panel.nativeViewSessions.quickLook.close()

        panel.nativeViewSessions.quickLook.update(
            view,
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        XCTAssertNil(previewView.previewItem)
    }

    func testQuickLookSessionDismantlingRetiredViewDoesNotResetActivePreviewItem() throws {
        let url = try temporaryBinaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        let retiredView = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        guard retiredView is QLPreviewView else {
            return XCTFail("Expected Quick Look to vend a QLPreviewView")
        }

        panel.nativeViewSessions.quickLook.close()

        let activeView = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        guard let activePreviewView = activeView as? QLPreviewView else {
            return XCTFail("Expected Quick Look to vend a QLPreviewView")
        }
        let activeItem = try XCTUnwrap(activePreviewView.previewItem as AnyObject?)

        panel.nativeViewSessions.quickLook.dismantle(retiredView)
        panel.nativeViewSessions.quickLook.update(
            activeView,
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        let updatedItem = try XCTUnwrap(activePreviewView.previewItem as AnyObject?)
        XCTAssertTrue(updatedItem === activeItem)
    }

    func testNativeViewSessionDismantlesRetiredViewAfterClose() {
        let view = NSView()
        var closeCount = 0
        var dismantleCount = 0
        let session = PanelOwnedNativeViewSession<NSView>(
            makeView: { view },
            closeView: {
                XCTAssertTrue($0 === view)
                closeCount += 1
            },
            dismantleView: {
                XCTAssertTrue($0 === view)
                dismantleCount += 1
            }
        )

        XCTAssertTrue(session.view(configure: { _ in }) === view)
        session.close()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(dismantleCount, 0)

        XCTAssertFalse(session.dismantle(view))
        XCTAssertEqual(dismantleCount, 1)

        XCTAssertFalse(session.dismantle(view))
        XCTAssertEqual(dismantleCount, 1)
    }

    func testTextLoaderRejectsOversizedTextFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: FilePreviewTextLoader.maximumLoadedTextBytes + 1)
        try handle.close()

        guard case .unavailable = FilePreviewTextLoader.loadSynchronously(url: url) else {
            XCTFail("Expected oversized text file to be unavailable")
            return
        }
    }

    func testFocusCoordinatorKeepsPendingFocusUntilEndpointHasWindow() {
        let textView = FilePreviewReviewFocusTestView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let coordinator = FilePreviewFocusCoordinator(preferredIntent: .textEditor)
        coordinator.register(root: textView, primaryResponder: textView, intent: .textEditor)

        XCTAssertFalse(coordinator.focus(.textEditor))

        let window = NSWindow(contentRect: textView.bounds, styleMask: [], backing: .buffered, defer: false)
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = textView
        coordinator.fulfillPendingFocusIfNeeded()

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testFileOpenHonorsExplicitPaneDestinationInsteadOfReusingExistingPreview() throws {
        let originalURL = try temporaryTextFile(contents: "original", encoding: .utf8)
        let placeholderURL = try temporaryTextFile(contents: "placeholder", encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: placeholderURL)
            TerminalController.shared.setActiveTabManager(nil)
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        defer { workspace.teardownAllPanels() }
        let firstPane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let existingPanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: firstPane,
            filePath: originalURL.path,
            focus: false
        ))
        let placeholderPanel = try XCTUnwrap(workspace.splitPaneWithFilePreview(
            targetPane: firstPane,
            orientation: .horizontal,
            insertFirst: false,
            filePath: placeholderURL.path
        ))
        let targetPane = try XCTUnwrap(workspace.paneId(forPanelId: placeholderPanel.id))
        let startingTargetTabs = workspace.bonsplitController.tabs(inPane: targetPane).count
        TerminalController.shared.setActiveTabManager(manager)

        let result = TerminalController.shared.v2FileOpen(params: [
            "paths": [originalURL.path],
            "workspace_id": workspace.id.uuidString,
            "pane_id": targetPane.id.uuidString,
            "focus": false
        ])

        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let openedPanelIdString = payload["surface_id"] as? String,
              let openedPanelId = UUID(uuidString: openedPanelIdString) else {
            XCTFail("Expected file.open to succeed, got \(result)")
            return
        }

        XCTAssertNotEqual(openedPanelId, existingPanel.id)
        XCTAssertEqual(payload["pane_id"] as? String, targetPane.id.uuidString)
        XCTAssertEqual(workspace.paneId(forPanelId: openedPanelId)?.id, targetPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: targetPane).count, startingTargetTabs + 1)
    }

    private func temporaryTextFile(contents: String, encoding: String.Encoding) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func temporaryBinaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        try Data([0, 1, 2, 3, 0, 4]).write(to: url, options: .atomic)
        return url
    }

    private func keyEvent(key: String, keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func waitForPanelSave(
        _ panel: FilePreviewPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while panel.isSaving, Date() < deadline {
            await Task.yield()
        }
        if panel.isSaving {
            XCTFail("Timed out waiting for panel save", file: file, line: line)
        }
    }
}

private final class FilePreviewReviewFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}
