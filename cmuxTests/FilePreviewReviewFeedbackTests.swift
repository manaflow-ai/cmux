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

private final class RemoteMaterializationCancellationProbe: @unchecked Sendable {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation

    private let lock = NSLock()
    private var didFulfillCancellation = false

    init(label: String) {
        self.started = XCTestExpectation(description: "\(label) started")
        self.cancelled = XCTestExpectation(description: "\(label) cancelled")
        self.started.assertForOverFulfill = false
        self.cancelled.assertForOverFulfill = false
    }

    func fulfillStarted() {
        started.fulfill()
    }

    func fulfillCancelled() {
        lock.lock()
        defer { lock.unlock() }
        guard !didFulfillCancellation else { return }
        didFulfillCancellation = true
        cancelled.fulfill()
    }
}

private final class RemoteMaterializationAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class RejectingFilePreviewCreateTabDelegate: BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        false
    }
}

private final class RejectingFilePreviewSplitPaneDelegate: BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool {
        false
    }
}

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

    func testRemotePreviewDisplayPathUsesSSHURIPathSeparator() {
        let source = remotePreviewSource(remotePath: "/tmp/remote preview.mov")

        XCTAssertEqual(source.displayPath, "ssh://dev@example.com:2222/tmp/remote preview.mov")
    }

    func testRemotePreviewDisplayPathPreservesPathWhitespace() {
        let source = remotePreviewSource(remotePath: "/tmp/ remote preview.mov ")

        XCTAssertEqual(source.displayPath, "ssh://dev@example.com:2222/tmp/ remote preview.mov ")
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

    func testRejectedFilePreviewTabCancelsRemoteMaterialization() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let source = remotePreviewSource()
        let probe = RemoteMaterializationCancellationProbe(label: "rejected file preview tab")
        installHangingRemoteMaterializer(probe: probe)
        defer { FilePreviewPanel.remoteMaterializerForTesting = nil }

        let rejectingDelegate = RejectingFilePreviewCreateTabDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate

        let created = workspace.newFilePreviewSurface(
            inPane: paneId,
            filePath: RemoteFilePreviewMaterializer.cacheURL(for: source).path,
            displayPath: source.displayPath,
            remoteSource: source,
            focus: false
        )

        XCTAssertNil(created)
        wait(for: [probe.started, probe.cancelled], timeout: 2.0)
        XCTAssertTrue(workspace.panels.values.allSatisfy { !($0 is FilePreviewPanel) })
    }

    func testRejectedRegisteredFilePreviewDropKeepsRegistryEntry() throws {
        FilePreviewDragRegistry.shared.discardAll()
        defer { FilePreviewDragRegistry.shared.discardAll() }

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let rejectingDelegate = RejectingFilePreviewCreateTabDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate

        let dragID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/retry-after-rejected-drop.txt", displayTitle: "retry.txt")
        )

        let handled = workspace.handleRegisteredFilePreviewDrop(
            id: dragID,
            destination: .insert(targetPane: paneId, targetIndex: nil)
        )

        XCTAssertFalse(handled)
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: dragID))
    }

    func testSuccessfulRegisteredFilePreviewDropDiscardsRegistryEntry() throws {
        FilePreviewDragRegistry.shared.discardAll()
        defer { FilePreviewDragRegistry.shared.discardAll() }

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let dragID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/successful-drop.txt", displayTitle: "successful-drop.txt")
        )

        let handled = workspace.handleRegisteredFilePreviewDrop(
            id: dragID,
            destination: .insert(targetPane: paneId, targetIndex: nil)
        )

        XCTAssertTrue(handled)
        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: dragID))
    }

    func testRejectedFilePreviewSplitCancelsRemoteMaterialization() throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let source = remotePreviewSource(remotePath: "/tmp/split-preview.pdf")
        let probe = RemoteMaterializationCancellationProbe(label: "rejected file preview split")
        installHangingRemoteMaterializer(probe: probe)
        defer { FilePreviewPanel.remoteMaterializerForTesting = nil }

        let rejectingDelegate = RejectingFilePreviewSplitPaneDelegate()
        workspace.bonsplitController.delegate = rejectingDelegate

        let created = workspace.splitPaneWithFilePreview(
            targetPane: paneId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: RemoteFilePreviewMaterializer.cacheURL(for: source).path,
            displayPath: source.displayPath,
            remoteSource: source
        )

        XCTAssertNil(created)
        wait(for: [probe.started, probe.cancelled], timeout: 2.0)
        XCTAssertTrue(workspace.panels.values.allSatisfy { !($0 is FilePreviewPanel) })
    }

    func testReusingFailedRemotePreviewRetriesMaterialization() async throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let source = remotePreviewSource(remotePath: "/tmp/retry-preview.txt")
        let entry = FilePreviewDragEntry(
            filePath: RemoteFilePreviewMaterializer.cacheURL(for: source).path,
            displayTitle: "retry-preview.txt",
            displayPath: source.displayPath,
            remoteSource: source,
            textInsertionPath: source.remotePath
        )
        let attempts = RemoteMaterializationAttemptCounter()
        let firstAttempt = expectation(description: "first materialization attempt")
        let secondAttempt = expectation(description: "second materialization attempt")

        FilePreviewPanel.remoteMaterializerForTesting = { _, destinationURL in
            switch attempts.next() {
            case 1:
                firstAttempt.fulfill()
                throw RemoteFilePreviewMaterializerError.materializationFailed
            default:
                secondAttempt.fulfill()
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "downloaded".write(to: destinationURL, atomically: true, encoding: .utf8)
                return destinationURL
            }
        }
        defer {
            FilePreviewPanel.remoteMaterializerForTesting = nil
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: entry.filePath).deletingLastPathComponent())
        }

        let opened = workspace.openFileSurfaces(
            inPane: paneId,
            entries: [entry],
            focus: false
        )
        let panel = try XCTUnwrap(opened.first as? FilePreviewPanel)
        await fulfillment(of: [firstAttempt], timeout: 2.0)
        await waitUntil("remote preview failed") {
            panel.isFileUnavailable && !panel.isLoadingRemoteFile
        }

        let reopened = workspace.openFileSurfaces(
            inPane: paneId,
            entries: [entry],
            focus: false,
            reuseExisting: true
        )

        XCTAssertTrue((reopened.first as? FilePreviewPanel) === panel)
        await fulfillment(of: [secondAttempt], timeout: 2.0)
        await waitUntil("remote preview retried") {
            !panel.isFileUnavailable && !panel.isLoadingRemoteFile
        }
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

    private func remotePreviewSource(remotePath: String = "/tmp/remote-preview.mov") -> RemoteFilePreviewSource {
        RemoteFilePreviewSource(
            connection: SSHFileExplorerConnection(
                destination: "dev@example.com",
                port: 2222,
                identityFile: "/Users/alice/.ssh/id_ed25519",
                sshOptions: ["StrictHostKeyChecking=no"]
            ),
            displayTarget: "dev@example.com:2222",
            remotePath: remotePath
        )
    }

    private func installHangingRemoteMaterializer(probe: RemoteMaterializationCancellationProbe) {
        FilePreviewPanel.remoteMaterializerForTesting = { _, destinationURL in
            probe.fulfillStarted()
            if Task.isCancelled {
                probe.fulfillCancelled()
                throw CancellationError()
            }
            return try await withTaskCancellationHandler {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return destinationURL
            } onCancel: {
                probe.fulfillCancelled()
            }
        }
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

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        if !condition() {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
        }
    }
}

private final class FilePreviewReviewFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}
