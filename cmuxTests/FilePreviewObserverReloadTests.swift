import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File preview observer reloads")
struct FilePreviewObserverReloadTests {
    @Test("Saving a text editor refreshes an adjacent Markdown preview")
    func editorSaveRefreshesMarkdownPreview() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-editor-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appending(path: "live.md")
        let originalContent = "# Before\n"
        let updatedContent = "# After saving\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let workspaceID = UUID()
        let fileChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let editor = FilePreviewPanel(
            workspaceId: workspaceID,
            filePath: fileURL.path,
            fileContentChangeCoordinator: fileChanges
        )
        let preview = MarkdownPanel(
            workspaceId: workspaceID,
            filePath: fileURL.path,
            fileContentChangeCoordinator: fileChanges
        )
        defer {
            editor.close()
            preview.close()
        }
        await editor.loadTextContent().value
        if let initialPreviewLoad = preview.loadTextContent() {
            await initialPreviewLoad.value
        }
        #expect(editor.textContent == originalContent)
        #expect(preview.content == originalContent)

        let (contentChanges, continuation) = AsyncStream.makeStream(of: String.self)
        let observation = preview.$content.sink { continuation.yield($0) }
        defer {
            observation.cancel()
            continuation.finish()
        }

        editor.updateTextContent(updatedContent)
        let save = try #require(editor.saveTextContent())
        await save.value

        #expect(await waitForMatchingContent(updatedContent, in: contentChanges))
        #expect(preview.content == updatedContent)
        #expect(!preview.isDirty)
    }

    @Test("Starting file observation reconciles a change missed before subscription")
    func startingObservationReconcilesMissedChange() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-subscription-gap-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let originalContent = "before observing\n"
        let updatedContent = "changed before observing\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let fileChanges = FileContentChangeCoordinator(makeFileWatcher: { _ in nil })
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false,
            fileContentChangeCoordinator: fileChanges
        )
        defer { panel.close() }
        await panel.loadTextContent().value
        #expect(panel.textContent == originalContent)

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
        let (contentChanges, continuation) = AsyncStream.makeStream(of: String.self)
        let observation = panel.$textContent.sink { continuation.yield($0) }
        defer {
            observation.cancel()
            continuation.finish()
        }

        panel.startWatchingForFileChanges()

        #expect(await waitForMatchingContent(updatedContent, in: contentChanges))
        #expect(panel.textContent == updatedContent)
        #expect(!panel.isDirty)
    }

    @Test("Markdown reload retries when the file changes during the read")
    func markdownReloadRetriesWhenFileChangesDuringRead() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-read-race-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let before = "# Before\n"
        let after = "# After updated\n"
        try before.write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = ControlledMarkdownTextLoader(
            firstResult: .loaded(content: before, encoding: .utf8),
            subsequentResult: .loaded(content: after, encoding: .utf8)
        )
        let panel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            fileContentChangeCoordinator: FileContentChangeCoordinator(
                makeFileWatcher: { _ in nil }
            ),
            textLoader: { _ in await loader.load() }
        )
        defer { panel.close() }

        await loader.waitForFirstStart()
        try after.write(to: fileURL, atomically: false, encoding: .utf8)
        await loader.releaseFirstRead()

        #expect(await loader.waitForCount(2))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while panel.content != after, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        #expect(await loader.count == 2)
        #expect(panel.content == after)
    }

    private func waitForMatchingContent(
        _ expected: String,
        in changes: AsyncStream<String>,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await content in changes where content == expected {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let matched = await group.next() ?? false
            group.cancelAll()
            return matched
        }
    }
}

private actor ControlledMarkdownTextLoader {
    private(set) var count = 0
    private let firstResult: FilePreviewTextLoader.Result
    private let subsequentResult: FilePreviewTextLoader.Result
    private var firstStartContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    init(
        firstResult: FilePreviewTextLoader.Result,
        subsequentResult: FilePreviewTextLoader.Result
    ) {
        self.firstResult = firstResult
        self.subsequentResult = subsequentResult
    }

    func load() async -> FilePreviewTextLoader.Result {
        count += 1
        switch count {
        case 1:
            firstStartContinuation?.resume()
            firstStartContinuation = nil
            await withCheckedContinuation { firstReleaseContinuation = $0 }
            return firstResult
        default:
            return subsequentResult
        }
    }

    func waitForFirstStart() async {
        guard count == 0 else { return }
        await withCheckedContinuation { firstStartContinuation = $0 }
    }

    func releaseFirstRead() {
        firstReleaseContinuation?.resume()
        firstReleaseContinuation = nil
    }

    func waitForCount(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while count < expected, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        return count >= expected
    }
}
