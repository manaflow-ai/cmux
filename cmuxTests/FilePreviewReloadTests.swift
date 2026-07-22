import AppKit
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File preview reloads")
struct FilePreviewReloadTests {
    @Test("A text preview reloads after its file changes on disk")
    func textPreviewReloadsAfterFileChange() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-reload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appending(path: "live.txt")
        let originalContent = "before\n"
        let updatedContent = "after\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        #expect(panel.textContent == originalContent)

        let (contentChanges, continuation) = AsyncStream.makeStream(of: String.self)
        let observation = panel.$textContent.sink { continuation.yield($0) }
        defer {
            observation.cancel()
            continuation.finish()
        }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(await firstMatch(updatedContent, in: contentChanges))
        #expect(panel.textContent == updatedContent)
        #expect(!panel.isDirty)
    }

    @Test("The manual refresh path reloads a text preview")
    func manualRefreshReloadsTextPreview() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-manual-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "before\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        await panel.loadTextContent().value

        try "after\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await panel.reloadFromDisk().value

        #expect(panel.textContent == "after\n")
        #expect(!panel.isDirty)
    }

    @Test("Refreshing a dirty text preview preserves unsaved edits")
    func manualRefreshPreservesDirtyText() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-dirty-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "on disk\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("unsaved edits\n")

        try "changed on disk\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await panel.reloadFromDisk().value

        #expect(panel.textContent == "unsaved edits\n")
        #expect(panel.isDirty)
    }

    @Test("The manual refresh path replaces a cached Quick Look item")
    func manualRefreshReplacesQuickLookItem() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-manual-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([0x00, 0x01]).write(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        #expect(panel.previewMode == .quickLook)

        let view = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        let container = try #require(view as? FilePreviewQuickLookContainerView)
        let firstItem = try #require(container.livePreviewView()?.previewItem as AnyObject?)

        try Data([0x02, 0x03]).write(to: fileURL)
        await panel.reloadFromDisk().value
        panel.nativeViewSessions.quickLook.update(
            view,
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        let refreshedItem = try #require(container.livePreviewView()?.previewItem as AnyObject?)
        #expect(refreshedItem !== firstItem)
    }

    @Test("Markdown manual refresh rereads the file")
    func markdownManualRefreshRereadsFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-manual-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "# Before\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        try "# After\n".write(to: fileURL, atomically: true, encoding: .utf8)

        panel.reloadFromDisk()

        #expect(panel.content == "# After\n")
        #expect(!panel.isDirty)
    }

    private func firstMatch(_ expected: String, in changes: AsyncStream<String>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await content in changes where content == expected {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }

            let matched = await group.next() ?? false
            group.cancelAll()
            return matched
        }
    }
}
