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
