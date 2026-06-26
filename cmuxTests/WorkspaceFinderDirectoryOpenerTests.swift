import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct WorkspaceFinderDirectoryOpenerTests {
    @MainActor
    @Test func routesWorkingDirectoryThroughSharedFinderOpener() async {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-index-cwd-\(UUID().uuidString)", isDirectory: true)
            .path
        var finderOpenedPaths: [String?] = []

        let task = WorkspaceFinderDirectoryOpener.openInFinder(
            path: cwd,
            openInFinder: { finderOpenedPaths.append($0?.path) }
        )
        await task.value

        #expect(finderOpenedPaths == [cwd])
    }
}
