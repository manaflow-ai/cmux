import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File preview reload completion")
struct FilePreviewReloadCompletionTests {
    @Test("Refresh waits for text loaded by a preview-mode transition")
    func refreshWaitsForTextModeTransition() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-mode-transition-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([0x00]).write(to: fileURL)

        let resolver = FilePreviewModeTransitionResolver()
        let loader = DeferredFilePreviewTextLoader()
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false,
            textLoader: { _ in await loader.load() },
            modeResolver: { _ in await resolver.resolve() }
        )
        defer { panel.close() }
        await resolver.waitForInitialResolution()
        #expect(panel.previewMode == .quickLook)

        await panel.reloadFromDisk().value

        #expect(panel.previewMode == .text)
        #expect(panel.textContent == "transitioned")
    }

    @Test("Refresh keeps unsaved text visible when disk content changes preview mode")
    func refreshKeepsDirtyTextMode() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-dirty-mode-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let propertyList = ["key": "value"]
        let xmlData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try xmlData.write(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        await panel.reloadFromDisk().value
        #expect(panel.previewMode == .text)
        panel.updateTextContent("unsaved edits\n")

        let binaryData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try binaryData.write(to: fileURL)
        await panel.reloadFromDisk().value

        #expect(panel.previewMode == .text)
        #expect(panel.textContent == "unsaved edits\n")
        #expect(panel.isDirty)
    }
}

private actor FilePreviewModeTransitionResolver {
    private var callCount = 0
    private var initialResolutionContinuation: CheckedContinuation<Void, Never>?

    func resolve() -> FilePreviewMode {
        callCount += 1
        if callCount == 1 {
            initialResolutionContinuation?.resume()
            initialResolutionContinuation = nil
            return .quickLook
        }
        return .text
    }

    func waitForInitialResolution() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { initialResolutionContinuation = $0 }
    }
}

private actor DeferredFilePreviewTextLoader {
    func load() async -> FilePreviewTextLoader.Result {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                await Task.yield()
                continuation.resume()
            }
        }
        return .loaded(content: "transitioned", encoding: .utf8)
    }
}
