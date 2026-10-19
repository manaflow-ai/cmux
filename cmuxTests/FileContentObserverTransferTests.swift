import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File content observer transfers")
struct FileContentObserverTransferTests {
    @Test("A file editor save follows the panel to its destination coordinator")
    func fileEditorSaveCompletionFollowsTransfer() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-editor-save-transfer-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let originalContent = "# Before file editor transfer\n"
        let updatedContent = "# After file editor transfer\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let sourceChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let destinationChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let editor = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            fileContentChangeCoordinator: sourceChanges
        )
        let destinationWorkspaceID = UUID()
        let preview = MarkdownPanel(
            workspaceId: destinationWorkspaceID,
            filePath: fileURL.path,
            fileContentChangeCoordinator: destinationChanges
        )
        defer {
            editor.close()
            preview.close()
        }
        await editor.loadTextContent().value
        if let initialPreviewLoad = preview.loadTextContent() {
            await initialPreviewLoad.value
        }
        let (contentChanges, continuation) = AsyncStream.makeStream(of: String.self)
        let observation = preview.$content.dropFirst().sink { continuation.yield($0) }
        defer {
            observation.cancel()
            continuation.finish()
        }

        editor.updateTextContent(updatedContent)
        let save = try #require(editor.saveTextContent())
        editor.updateWorkspaceId(
            destinationWorkspaceID,
            fileContentChangeCoordinator: destinationChanges
        )
        await save.value

        #expect(await awaitContent(updatedContent, from: contentChanges))
        #expect(preview.content == updatedContent)
    }

    @Test("A Markdown editor save follows the panel to its destination coordinator")
    func markdownSaveCompletionFollowsTransfer() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-save-transfer-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let originalContent = "# Before Markdown transfer\n"
        let updatedContent = "# After Markdown transfer\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let sourceChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let destinationChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let editor = MarkdownPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            fileContentChangeCoordinator: sourceChanges
        )
        let destinationWorkspaceID = UUID()
        let preview = MarkdownPanel(
            workspaceId: destinationWorkspaceID,
            filePath: fileURL.path,
            fileContentChangeCoordinator: destinationChanges
        )
        defer {
            editor.close()
            preview.close()
        }

        if let initialEditorLoad = editor.loadTextContent() {
            await initialEditorLoad.value
        }
        if let initialPreviewLoad = preview.loadTextContent() {
            await initialPreviewLoad.value
        }
        let (contentChanges, continuation) = AsyncStream.makeStream(of: String.self)
        let observation = preview.$content.dropFirst().sink { continuation.yield($0) }
        defer {
            observation.cancel()
            continuation.finish()
        }

        editor.updateTextContent(updatedContent)
        let save = try #require(editor.saveTextContent())
        editor.updateWorkspaceId(
            destinationWorkspaceID,
            fileContentChangeCoordinator: destinationChanges
        )
        await save.value

        #expect(await awaitContent(updatedContent, from: contentChanges))
        #expect(preview.content == updatedContent)
    }

    @Test("Dock attachment moves Markdown observation to the destination coordinator")
    func dockAttachmentRetargetsMarkdownObservation() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-observer-transfer-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let originalContent = "# Before transfer\n"
        let updatedContent = "# After transfer\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let sourceChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let sourceWorkspace = Workspace(fileContentChangeCoordinator: sourceChanges)
        defer { sourceWorkspace.teardownAllPanels() }
        let sourcePane = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let panel = try #require(sourceWorkspace.newMarkdownSurface(
            inPane: sourcePane,
            filePath: fileURL.path,
            focus: false
        ))
        let detached = try #require(sourceWorkspace.detachSurface(panelId: panel.id))

        let destinationChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let destinationDock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            fileContentChangeCoordinator: destinationChanges
        )
        let destinationPane = try #require(destinationDock.bonsplitController.allPaneIds.first)
        let attachedPanelID = destinationDock.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )
        let destinationOwnsPanel = attachedPanelID == panel.id
        defer {
            destinationDock.closeAllPanels()
            if !destinationOwnsPanel {
                panel.close()
            }
        }

        #expect(destinationOwnsPanel)
        #expect(panel.workspaceId == destinationDock.workspaceId)
        if let initialLoad = panel.loadTextContent() {
            await initialLoad.value
        }
        #expect(panel.content == originalContent)
        let (contentChanges, continuation) = AsyncStream.makeStream(of: String.self)
        let observation = panel.$content.dropFirst().sink { continuation.yield($0) }
        defer {
            observation.cancel()
            continuation.finish()
        }

        try updatedContent.write(to: fileURL, atomically: false, encoding: .utf8)
        sourceChanges.fileWriteCompleted(at: fileURL.path)
        #expect(panel.content == originalContent)

        destinationChanges.fileWriteCompleted(at: fileURL.path)
        #expect(await awaitContent(updatedContent, from: contentChanges))
        #expect(panel.content == updatedContent)
    }

    @Test("Window Dock stores share the workspace file-change pipeline")
    func windowDockStoreSharesFileChangePipeline() {
        let manager = TabManager()
        let dockStore = manager.makeWindowDockStore(windowId: UUID())
        defer { dockStore.closeAllPanels() }
        let workspace = Workspace(
            fileContentChangeCoordinator: manager.fileContentChangeCoordinator
        )
        defer { workspace.teardownAllPanels() }

        #expect(
            dockStore.fileContentChangeCoordinator
                === workspace.fileContentChangeCoordinator
        )
    }

    @Test("Retargeting a Markdown panel does not reload an unchanged file")
    func markdownRetargetSkipsReloadForUnchangedFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-retarget-unchanged-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let originalContent = "# Retarget original\n"
        let updatedContent = "# Retarget updated\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let sourceChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let panel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            fileContentChangeCoordinator: sourceChanges
        )
        defer { panel.close() }
        if let initialLoad = panel.loadTextContent() {
            await initialLoad.value
        }
        #expect(panel.content == originalContent)

        var reloadPublishes = 0
        let observation = panel.$content.dropFirst().sink { _ in reloadPublishes += 1 }
        defer { observation.cancel() }

        let unchangedDestination = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        panel.updateWorkspaceId(
            UUID(),
            fileContentChangeCoordinator: unchangedDestination
        )
        #expect(reloadPublishes == 0)

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
        let changedDestination = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        panel.updateWorkspaceId(
            UUID(),
            fileContentChangeCoordinator: changedDestination
        )
        if let changedLoad = panel.loadTextContent(replacingDirtyContent: false) {
            await changedLoad.value
        }
        #expect(panel.content == updatedContent)
    }

    private func awaitContent(
        _ expected: String,
        from changes: AsyncStream<String>
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = changes.makeAsyncIterator()
                while let value = await iterator.next() {
                    if value == expected { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
