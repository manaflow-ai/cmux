import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SessionIndexWorkingDirectoryOpenerTests {
    @MainActor
    @Test func routesWorkingDirectoryThroughSharedFinderOpener() async {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-index-cwd-\(UUID().uuidString)", isDirectory: true)
            .path
        var finderOpenedPaths: [String?] = []
        var directlyOpenedPaths: [String] = []

        let task = SessionIndexWorkingDirectoryOpener.open(
            cwd: cwd,
            openInFinder: { finderOpenedPaths.append($0?.path) },
            openURL: { directlyOpenedPaths.append($0.path) }
        )
        await task.value

        #expect(finderOpenedPaths == [cwd])
        #expect(directlyOpenedPaths.isEmpty)
    }
}
