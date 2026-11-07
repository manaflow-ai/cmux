import CmuxFilePreviewCore
import Observation
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
        #expect(panel.gitGutter.markers == .untracked)

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

        #expect(panel.gitGutter.markers == .untracked)
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
        #expect(panel.gitGutter.markers == Self.tracked([1: .modified]))

        // The destination's watch is installed once its registration reads the base.
        _ = await headReads.next()
        await reader.setContent("b\n")
        destination.fileWriteCompleted(at: headPath)

        #expect(await Self.markers(of: panel) { $0 == Self.tracked([:]) } != nil)
    }

    /// Returns the first markers that satisfy `predicate`, waiting on
    /// observation changes of the panel's gutter model.
    private static func markers(
        of panel: FilePreviewPanel,
        where predicate: (FilePreviewGitGutterMarkers) -> Bool
    ) async -> FilePreviewGitGutterMarkers? {
        let (changes, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let model = panel.gitGutter
        func observedMarkers() -> FilePreviewGitGutterMarkers {
            withObservationTracking {
                model.markers
            } onChange: {
                continuation.yield(())
            }
        }
        var current = observedMarkers()
        var iterator = changes.makeAsyncIterator()
        while !predicate(current) {
            guard await iterator.next() != nil else { return nil }
            current = observedMarkers()
        }
        return current
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
