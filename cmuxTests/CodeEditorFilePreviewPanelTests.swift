import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for the FilePreview panel hooks the CodeMirror web
/// editor relies on (`fileEditor.engine = "code"`): the JS webview owns the
/// live buffer, so the panel must expose disk-baseline state, accept dirty
/// updates from JS, and route native saves through the web save handler.
@MainActor
@Suite("Code editor file preview panel", .serialized)
struct CodeEditorFilePreviewPanelTests {
    private func makeTemporaryFile(contents: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-code-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sample.swift", isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func removeTemporaryFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The panel's file watcher reloads concurrently with explicit
    /// `loadTextContent` calls (each load invalidates the other's generation;
    /// whichever starts last wins). Tests therefore wait for convergence
    /// instead of awaiting a single load task.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test("saveResolvedTextContent writes to disk, clears dirty, and moves the disk baseline")
    func saveResolvedTextContentWritesAndCleans() async throws {
        let fileURL = try makeTemporaryFile(contents: "let a = 1\n")
        defer { removeTemporaryFile(fileURL) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        #expect(panel.textContent == "let a = 1\n")

        panel.webEditorDidChangeDirty(true)
        let saved = await panel.saveResolvedTextContent("let a = 2\n")

        #expect(saved)
        #expect(panel.isDirty == false)
        #expect(panel.diskTextContent == "let a = 2\n")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "let a = 2\n")
    }

    @Test("saveResolvedTextContent with unchanged content is a clean no-op")
    func saveResolvedTextContentNoOp() async throws {
        let fileURL = try makeTemporaryFile(contents: "same\n")
        defer { removeTemporaryFile(fileURL) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        panel.webEditorDidChangeDirty(true)
        let saved = await panel.saveResolvedTextContent("same\n")

        #expect(saved)
        #expect(panel.isDirty == false)
    }

    @Test("webEditorDidChangeDirty drives the panel dirty flag in text mode")
    func webDirtyStateDrivesPanelDirty() async throws {
        let fileURL = try makeTemporaryFile(contents: "x\n")
        defer { removeTemporaryFile(fileURL) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        panel.webEditorDidChangeDirty(true)
        #expect(panel.isDirty)
        panel.webEditorDidChangeDirty(false)
        #expect(panel.isDirty == false)
    }

    @Test("native save entry points route through the web save handler when set")
    func nativeSaveRoutesThroughWebHandler() async throws {
        let fileURL = try makeTemporaryFile(contents: "x\n")
        defer { removeTemporaryFile(fileURL) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        var handlerCalls = 0
        panel.webEditorSaveHandler = {
            handlerCalls += 1
            return nil
        }
        _ = panel.saveTextContent()
        #expect(handlerCalls == 1)
    }

    @Test("external disk change while clean refreshes the buffer and bumps the sync token")
    func externalReloadWhileClean() async throws {
        let fileURL = try makeTemporaryFile(contents: "old\n")
        defer { removeTemporaryFile(fileURL) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        let initialToken = panel.textDiskSyncToken

        try "new\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await panel.loadTextContent(replacingDirtyContent: false).value

        #expect(await waitUntil { panel.textContent == "new\n" })
        #expect(panel.diskTextContent == "new\n")
        #expect(panel.isDirty == false)
        #expect(panel.textDiskSyncToken > initialToken)
    }

    @Test("external disk change while web-dirty moves the baseline but keeps dirty state")
    func externalChangeWhileWebDirty() async throws {
        let fileURL = try makeTemporaryFile(contents: "old\n")
        defer { removeTemporaryFile(fileURL) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.webEditorDidChangeDirty(true)
        let initialToken = panel.textDiskSyncToken

        try "new\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await panel.loadTextContent(replacingDirtyContent: false).value

        #expect(await waitUntil { panel.diskTextContent == "new\n" })
        #expect(panel.isDirty)
        #expect(panel.textDiskSyncToken > initialToken)
    }

    @Test("attaching the plain NSTextView editor clears the web save handler")
    func attachTextViewClearsWebSaveHandler() async throws {
        let fileURL = try makeTemporaryFile(contents: "x\n")
        defer { removeTemporaryFile(fileURL) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        panel.webEditorSaveHandler = { nil }
        panel.attachTextView(NSTextView())
        #expect(panel.webEditorSaveHandler == nil)
    }
}
