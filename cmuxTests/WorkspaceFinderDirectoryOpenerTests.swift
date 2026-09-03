import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct WorkspaceFinderDirectoryOpenerTests {
    @MainActor
    @Test func openDirectoryOpensExistingWorkingDirectoryItself() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-index-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        var openedURLs: [URL] = []
        var beepCount = 0

        await WorkspaceFinderDirectoryOpener.openDirectory(
            path: directoryURL.path,
            openDirectory: { openedURLs.append($0) },
            beep: { beepCount += 1 }
        )

        let expectedURL = URL(fileURLWithPath: directoryURL.path, isDirectory: true).standardizedFileURL
        #expect(openedURLs == [expectedURL])
        #expect(beepCount == 0)
    }

    @MainActor
    @Test func openDirectoryBeepsWithoutOpeningMissingWorkingDirectory() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-index-missing-cwd-\(UUID().uuidString)", isDirectory: true)
        var openedURLs: [URL] = []
        var beepCount = 0

        await WorkspaceFinderDirectoryOpener.openDirectory(
            path: missingURL.path,
            openDirectory: { openedURLs.append($0) },
            beep: { beepCount += 1 }
        )

        #expect(openedURLs.isEmpty)
        #expect(beepCount == 1)
    }
}
