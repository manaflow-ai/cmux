import AppKit
import Bonsplit
import Carbon.HIToolbox
import Foundation
import Quartz
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class FilePreviewTabMetadataTestHost: FilePreviewTabMetadataHost {
    let bonsplitController: BonsplitController
    let panelId: UUID
    let tabId: TabID

    init(
        bonsplitController: BonsplitController,
        panelId: UUID,
        tabId: TabID
    ) {
        self.bonsplitController = bonsplitController
        self.panelId = panelId
        self.tabId = tabId
    }

    func filePreviewTabId(forPanelId panelId: UUID) -> TabID? {
        panelId == self.panelId ? tabId : nil
    }

    func filePreviewTabTitlePresentation(
        for metadata: FilePreviewTabMetadata,
        panelId _: UUID,
        existingTab _: Bonsplit.Tab
    ) -> (title: String?, hasCustomTitle: Bool?) {
        (metadata.title, false)
    }
}

@MainActor
@Suite(.serialized)
struct FilePreviewReviewFeedbackTests {
    @Test
    func tabMetadataBindingReplacesItsHostAndUnbindStopsProjection() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            startFileWatcher: false,
            modeResolver: { _ in .text }
        )
        defer { panel.close() }
        await panel.loadTextContent().value

        let firstHost = try makeTabMetadataHost(for: panel.id)
        let secondHost = try makeTabMetadataHost(for: panel.id)
        panel.bindTabMetadata(to: firstHost)
        panel.bindTabMetadata(to: secondHost)
        panel.updateTextContent("edited")

        #expect(firstHost.bonsplitController.tab(firstHost.tabId)?.isDirty == false)
        #expect(secondHost.bonsplitController.tab(secondHost.tabId)?.isDirty == true)

        panel.unbindTabMetadata()
        panel.updateTextContent("original")

        #expect(secondHost.bonsplitController.tab(secondHost.tabId)?.isDirty == true)
    }

    @Test
    func appBundleExportsFilePreviewDragType() {
        let declarations = (Bundle(for: AppDelegate.self).object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]) ?? []
        let exported = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })

        #expect(
            exported.contains("com.cmux.filepreview.transfer"),
            "Expected app bundle to export file-preview transfer type, got \(exported)"
        )
    }

    @Test
    func extensionlessUTF16TextWithBOMResolvesAsTextAfterSniffing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "hello".write(to: url, atomically: true, encoding: .utf16)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .quickLook)
        #expect(FilePreviewKindResolver.mode(for: url) == .text)
    }

    @Test
    func extensionlessANSITextResolvesAsTextAfterSniffing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "\u{001B}[31mred\u{001B}[0m\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .quickLook)
        #expect(FilePreviewKindResolver.mode(for: url) == .text)
    }

    @Test
    func typeScriptFileResolvesAsTextInsteadOfTransportStreamMedia() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        export const answer: number = 42;
        console.log(answer);
        """.write(to: url, atomically: true, encoding: .utf8)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver.mode(for: url) == .text)
    }

    @Test
    func utf8BOMTypeScriptFileResolvesAsText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("export const answer: number = 42;\n".utf8))
        try data.write(to: url, options: .atomic)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver.mode(for: url) == .text)
    }

    @Test
    func typeScriptFileWithNULBytesDoesNotResolveAsText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data("export const answer = 42;".utf8)
        data.append(contentsOf: [0x00, 0x00])
        try data.write(to: url, options: .atomic)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver.mode(for: url) != .text)
    }

    @Test
    func typeScriptTextWinsOverTransportStreamSyncBytePattern() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        let source = "G"
            + String(repeating: "a", count: 187)
            + "G"
            + String(repeating: "b", count: 187)
            + "\nexport const answer: number = 42;\n"
        try source.write(to: url, atomically: true, encoding: .utf8)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver.mode(for: url) == .text)
    }

    @Test
    func binaryTransportStreamFileKeepsMediaPreview() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data(repeating: 0, count: 188 * 2)
        data[0] = 0x47
        data[1] = 0x40
        data[2] = 0x00
        data[3] = 0x10
        data[188] = 0x47
        data[189] = 0x41
        data[190] = 0x00
        data[191] = 0x10
        try data.write(to: url, options: .atomic)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver.mode(for: url) == .media)
    }

    @Test
    func m2tsTransportStreamFileKeepsMediaPreview() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ts")
        defer { try? FileManager.default.removeItem(at: url) }

        var data = Data(repeating: 0, count: 192 * 2)
        data[4] = 0x47
        data[5] = 0x40
        data[6] = 0x00
        data[7] = 0x10
        data[196] = 0x47
        data[197] = 0x41
        data[198] = 0x00
        data[199] = 0x10
        try data.write(to: url, options: .atomic)

        #expect(FilePreviewKindResolver.initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver.mode(for: url) == .media)
    }

    @Test
    func quickLookSessionCloseDoesNotReadoptDismantledRepresentableView() throws {
        let url = try temporaryBinaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        #expect(panel.previewMode == .quickLook)

        let view = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        let container = try #require(
            view as? FilePreviewQuickLookContainerView,
            "Expected Quick Look to vend a preview host"
        )
        let previewView = try #require(
            container.livePreviewView(),
            "Expected Quick Look to vend an active preview"
        )
        #expect(previewView.previewItem != nil)

        panel.nativeViewSessions.quickLook.close()

        panel.nativeViewSessions.quickLook.update(
            view,
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        #expect(previewView.previewItem == nil)
        #expect(container.livePreviewView() == nil)
    }

    @Test
    func quickLookSessionDismantlingRetiredViewDoesNotResetActivePreviewItem() throws {
        let url = try temporaryBinaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        let retiredView = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        try #require(
            retiredView is FilePreviewQuickLookContainerView,
            "Expected Quick Look to vend a preview host"
        )

        panel.nativeViewSessions.quickLook.close()

        let activeView = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        let activeContainer = try #require(
            activeView as? FilePreviewQuickLookContainerView,
            "Expected Quick Look to vend a preview host"
        )
        let activePreviewView = try #require(
            activeContainer.livePreviewView(),
            "Expected Quick Look to vend an active preview"
        )
        let activeItem = try #require(activePreviewView.previewItem as AnyObject?)

        panel.nativeViewSessions.quickLook.dismantle(retiredView)
        panel.nativeViewSessions.quickLook.update(
            activeView,
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        let updatedItem = try #require(activePreviewView.previewItem as AnyObject?)
        #expect(updatedItem === activeItem)
    }

    @Test
    func nativeViewSessionDismantlesRetiredViewAfterClose() {
        let view = NSView()
        var closeCount = 0
        var dismantleCount = 0
        let session = PanelOwnedNativeViewSession<NSView>(
            makeView: { view },
            closeView: {
                #expect($0 === view)
                closeCount += 1
            },
            dismantleView: {
                #expect($0 === view)
                dismantleCount += 1
            }
        )

        #expect(session.view(configure: { _ in }) === view)
        session.close()
        #expect(closeCount == 1)
        #expect(dismantleCount == 0)

        #expect(!session.dismantle(view))
        #expect(dismantleCount == 1)

        #expect(!session.dismantle(view))
        #expect(dismantleCount == 1)
    }

    @Test
    func textLoaderRejectsOversizedTextFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: FilePreviewTextLoader.maximumLoadedTextBytes + 1)
        try handle.close()

        let result = FilePreviewTextLoader.loadSynchronously(url: url)
        let isUnavailable: Bool
        if case .unavailable = result {
            isUnavailable = true
        } else {
            isUnavailable = false
        }
        #expect(isUnavailable, "Expected oversized text file to be unavailable")
    }

    @Test
    func focusCoordinatorKeepsPendingFocusUntilEndpointHasWindow() {
        let textView = FilePreviewReviewFocusTestView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let coordinator = FilePreviewFocusCoordinator(preferredIntent: .textEditor)
        coordinator.register(root: textView, primaryResponder: textView, intent: .textEditor)

        #expect(!coordinator.focus(.textEditor))

        let window = NSWindow(contentRect: textView.bounds, styleMask: [], backing: .buffered, defer: false)
        // AppKit releases a closed window unless the owner opts out, and callers close
        // this window. Without this the close over-releases and kills the test host,
        // losing this suite's verdict and its shard-mates' along with it.
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = textView
        coordinator.fulfillPendingFocusIfNeeded()

        #expect(window.firstResponder === textView)
    }

    @Test
    func fileOpenHonorsExplicitPaneDestinationInsteadOfReusingExistingPreview() throws {
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
        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let existingPanel = try #require(workspace.newFilePreviewSurface(
            inPane: firstPane,
            filePath: originalURL.path,
            focus: false
        ))
        let placeholderPanel = try #require(workspace.splitPaneWithFilePreview(
            targetPane: firstPane,
            orientation: .horizontal,
            insertFirst: false,
            filePath: placeholderURL.path
        ))
        let targetPane = try #require(workspace.paneId(forPanelId: placeholderPanel.id))
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
            Issue.record("Expected file.open to succeed, got \(result)")
            return
        }

        #expect(openedPanelId != existingPanel.id)
        #expect(payload["pane_id"] as? String == targetPane.id.uuidString)
        #expect(workspace.paneId(forPanelId: openedPanelId)?.id == targetPane.id)
        #expect(
            workspace.bonsplitController.tabs(inPane: targetPane).count
                == startingTargetTabs + 1
        )
    }

    @Test
    func surfaceListIncludesFilePathsForPreviewSurfaces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-list-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("source.swift")
        let markdownURL = directory.appendingPathComponent("README.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try "# Preview\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: directory)
            TerminalController.shared.setActiveTabManager(nil)
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        defer { workspace.teardownAllPanels() }
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let filePanel = try #require(workspace.newFilePreviewSurface(
            inPane: pane,
            filePath: fileURL.path,
            focus: false
        ))
        let markdownPanel = try #require(workspace.newMarkdownSurface(
            inPane: pane,
            filePath: markdownURL.path,
            focus: false
        ))
        TerminalController.shared.setActiveTabManager(manager)

        let request: [String: Any] = [
            "id": "surface-list-file-path",
            "method": "surface.list",
            "params": ["workspace_id": workspace.id.uuidString],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let response = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(response.data(using: .utf8))
        let envelope = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(envelope["result"] as? [String: Any])
        let surfaces = try #require(result["surfaces"] as? [[String: Any]])
        let fileRow = try #require(surfaces.first { ($0["id"] as? String) == filePanel.id.uuidString })
        let markdownRow = try #require(surfaces.first { ($0["id"] as? String) == markdownPanel.id.uuidString })

        #expect(fileRow["file_path"] as? String == fileURL.path)
        #expect(markdownRow["file_path"] as? String == markdownURL.path)
    }

    private func temporaryTextFile(contents: String, encoding: String.Encoding) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func makeTabMetadataHost(
        for panelId: UUID
    ) throws -> FilePreviewTabMetadataTestHost {
        let controller = BonsplitController()
        let paneId = try #require(controller.allPaneIds.first)
        let tabId = try #require(
            controller.createTab(
                title: "Unbound preview",
                inPane: paneId
            )
        )
        return FilePreviewTabMetadataTestHost(
            bonsplitController: controller,
            panelId: panelId,
            tabId: tabId
        )
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

    // Regression test for manaflow-ai/cmux#4576: drag-selecting deep into a large file pegged the
    // main thread because TextKit 2's `NSTextSelectionNavigation` hit-tests are O(N) in line
    // fragments. Selection hit-testing near the bottom of a large file must stay responsive.
    @Test
    func largeFileSelectionHitTestStaysResponsive() {
        let lineCount = 60_000
        let text = (0..<lineCount)
            .map { "  \"row_\($0)\": { \"id\": \($0), \"value\": \"item-\($0)-payload\" }," }
            .joined(separator: "\n")

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = text
        // Realize layout so hit-testing measures steady-state cost (as it would after the file is
        // displayed and the user has scrolled), not first-layout cost. Deliberately do NOT touch
        // `layoutManager`/`textLayoutManager` here: that would force a TextKit mode in the test view
        // and the test could no longer detect a production regression back to TextKit 2.
        textView.sizeToFit()

        // Geometry precondition: the hit-tests below must actually land deep in the document. If
        // headless layout left the view collapsed, `bottomY` would sit at the top where even
        // TextKit 2 is cheap, turning this into a silent false negative. Fail loudly instead.
        let documentHeight = textView.bounds.height
        #expect(
            documentHeight > 100_000,
            "Test precondition failed: a \(lineCount)-line document laid out to only \(documentHeight)pt, so hit-tests would not reach the bottom and the timing assertion would be meaningless."
        )

        let bottomY = max(documentHeight - 5, 1)
        let start = ProcessInfo.processInfo.systemUptime
        for offset in 0..<20 {
            _ = textView.characterIndexForInsertion(at: CGPoint(x: 200, y: bottomY - CGFloat(offset)))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        // TextKit 2 takes several seconds here; TextKit 1 + non-contiguous layout takes a few ms.
        // The 1.0s ceiling sits far from both, so it is a clean, non-flaky regression signal.
        #expect(
            elapsed < 1.0,
            "Selection hit-testing near the bottom of a \(lineCount)-line file took \(elapsed)s. File Preview likely regressed to TextKit 2 O(N) selection navigation (see https://github.com/manaflow-ai/cmux/issues/4576)."
        )
    }
}

@MainActor
@Suite(.serialized)
struct FilePreviewSaveShortcutTests {
    @Test
    func savingTextViewUsesChordedSaveShortcut() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let saveRecorder = FilePreviewSaveRecorder()
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            startFileWatcher: false,
            textSaver: { content, _, _ in
                await saveRecorder.record(content)
                return .saved
            }
        )
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = "saved by chord"
        textView.panel = panel
        panel.attachTextView(textView)
        panel.updateTextContent(textView.string)

        let prefixEvent = try #require(
            keyEvent(key: "k", keyCode: UInt16(kVK_ANSI_K))
        )
        let suffixEvent = try #require(
            keyEvent(key: "s", keyCode: UInt16(kVK_ANSI_S))
        )

        let saveAction = KeyboardShortcutSettings.Action.saveFilePreview
        let hadPersistedSaveShortcut =
            UserDefaults.standard.object(forKey: saveAction.defaultsKey) != nil
        let originalSaveShortcut = KeyboardShortcutSettings.shortcut(for: saveAction)
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(
                first: ShortcutStroke(
                    key: "k",
                    command: true,
                    shift: false,
                    option: false,
                    control: false,
                    keyCode: UInt16(kVK_ANSI_K)
                ),
                second: ShortcutStroke(
                    key: "s",
                    command: true,
                    shift: false,
                    option: false,
                    control: false,
                    keyCode: UInt16(kVK_ANSI_S)
                )
            ),
            for: saveAction
        )
        let handledPrefix = textView.performKeyEquivalent(with: prefixEvent)
        #expect(handledPrefix)
        #expect(!panel.isSaving)
        #expect((try? String(contentsOf: url, encoding: .utf8)) == "original")

        let handledSuffix = textView.performKeyEquivalent(with: suffixEvent)
        if hadPersistedSaveShortcut {
            KeyboardShortcutSettings.setShortcut(originalSaveShortcut, for: saveAction)
        } else {
            KeyboardShortcutSettings.resetShortcut(for: saveAction)
        }
        #expect(handledSuffix)
        let savedContent = await waitForSavedContent(in: saveRecorder)
        #expect(savedContent == "saved by chord")
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

    private func waitForSavedContent(
        in recorder: FilePreviewSaveRecorder
    ) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let content = await recorder.content {
                return content
            }
            await Task.yield()
        }
        return await recorder.content
    }
}

private actor FilePreviewSaveRecorder {
    private(set) var content: String?

    func record(_ content: String) {
        self.content = content
    }
}

private final class FilePreviewReviewFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}
