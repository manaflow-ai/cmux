import CmuxFilePreviewCore
import Combine
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File Preview panel git tracking", .timeLimit(.minutes(1)))
struct FilePreviewPanelGitTrackingTests {
    private static func tracked(_ changes: [Int: FilePreviewGitLineChange]) -> FilePreviewGitGutterMarkers {
        FilePreviewGitGutterMarkers(isTracked: true, changes: changes)
    }

    @Test("Hiding the gutter stops git tracking and showing it resumes")
    func hidingGutterPausesTracking() async throws {
        let workspace = try TemporaryTextFile(contents: "b\n")
        defer { workspace.remove() }
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: workspace.filePath,
            fileContentChangeCoordinator: FileContentChangeCoordinator(),
            gitHeadContentReader: FixedHeadContentReader(content: "a\n")
        )
        defer { panel.close() }
        #expect(await Self.markers(of: panel) { $0 == Self.tracked([1: .modified]) } != nil)

        panel.setGitGutterVisible(false)
        #expect(panel.gitGutterMarkers == .untracked)

        panel.setGitGutterVisible(true)
        #expect(await Self.markers(of: panel) { $0 == Self.tracked([1: .modified]) } != nil)
    }

    @Test("Discarding the panel without close stops git tracking")
    func discardWithoutCloseStopsTracking() async throws {
        let workspace = try TemporaryTextFile(contents: "b\n")
        defer { workspace.remove() }
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: workspace.filePath,
            fileContentChangeCoordinator: FileContentChangeCoordinator(),
            gitHeadContentReader: FixedHeadContentReader(content: "a\n")
        )
        defer { panel.close() }
        #expect(await Self.markers(of: panel) { $0 == Self.tracked([1: .modified]) } != nil)

        panel.stopWatchingForFileChanges()

        #expect(panel.gitGutterMarkers == .untracked)
    }

    @Test("A workspace transfer keeps the markers and moves the repository watch")
    func transferKeepsMarkersAndMovesWatch() async throws {
        let workspace = try TemporaryTextFile(contents: "b\n")
        defer { workspace.remove() }
        let headPath = workspace.directory.appendingPathComponent("HEAD").path
        try Data("ref: refs/heads/main\n".utf8).write(to: URL(fileURLWithPath: headPath))
        let reader = FixedHeadContentReader(content: "a\n", watchedPaths: [headPath])
        var headReads = reader.headReads.makeAsyncIterator()
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: workspace.filePath,
            fileContentChangeCoordinator: FileContentChangeCoordinator(),
            gitHeadContentReader: reader
        )
        defer { panel.close() }
        #expect(await Self.markers(of: panel) { $0 == Self.tracked([1: .modified]) } != nil)
        _ = await headReads.next()

        let destination = FileContentChangeCoordinator()
        panel.updateWorkspaceId(UUID(), fileContentChangeCoordinator: destination)
        #expect(panel.gitGutterMarkers == Self.tracked([1: .modified]))

        // The destination's watch is installed once its registration reads the base.
        _ = await headReads.next()
        await reader.setContent("b\n")
        destination.fileWriteCompleted(at: headPath)

        #expect(await Self.markers(of: panel) { $0 == Self.tracked([:]) } != nil)
    }

    /// Returns the first published markers that satisfy `predicate`.
    private static func markers(
        of panel: FilePreviewPanel,
        where predicate: (FilePreviewGitGutterMarkers) -> Bool
    ) async -> FilePreviewGitGutterMarkers? {
        for await markers in panel.$gitGutterMarkers.values where predicate(markers) {
            return markers
        }
        return nil
    }
}

/// A text file in its own temporary directory, removed by ``remove()``.
private struct TemporaryTextFile {
    let directory: URL
    let filePath: String

    init(contents: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-panel-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("notes.txt")
        try Data(contents.utf8).write(to: fileURL)
        filePath = fileURL.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
