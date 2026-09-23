import CmuxFilePreviewCore
import CmuxGit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File Preview git diff tracker", .timeLimit(.minutes(1)))
struct FilePreviewGitDiffTrackerTests {
    private static let path = "/repo/file.txt"

    private static func tracked(_ changes: [Int: FilePreviewGitLineChange]) -> FilePreviewGitGutterMarkers {
        FilePreviewGitGutterMarkers(isTracked: true, changes: changes)
    }

    @Test("Publishes markers once the HEAD base loads")
    func publishesMarkersOnceBaseLoads() async {
        let reader = FixedHeadContentReader(content: "a\nb\n")
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: SidebarTestManualClock())
        var updates = tracker.updates.makeAsyncIterator()

        tracker.update(currentText: "a\nB\n")
        tracker.refreshBase()

        let initial = await updates.next()
        #expect(initial == Self.tracked([2: .modified]))
        tracker.cancel()
    }

    @Test("An unchanged tracked file still reports tracked so the gutter reserves the stripe")
    func unchangedTrackedFileReportsTracked() async {
        let reader = FixedHeadContentReader(content: "a\n")
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: SidebarTestManualClock())
        var updates = tracker.updates.makeAsyncIterator()

        tracker.update(currentText: "a\n")
        tracker.refreshBase()

        let initial = await updates.next()
        #expect(initial == Self.tracked([:]))
        tracker.cancel()
    }

    @Test("Waits for the debounce on the injected clock before diffing an edit")
    func waitsForDebounceBeforeDiffing() async {
        let clock = SidebarTestManualClock()
        let reader = FixedHeadContentReader(content: "a\n")
        let tracker = FilePreviewGitDiffTracker(
            filePath: Self.path,
            reader: reader,
            debounce: .milliseconds(150),
            clock: clock
        )
        var updates = tracker.updates.makeAsyncIterator()
        tracker.update(currentText: "a\nb\n")
        tracker.refreshBase()
        let initial = await updates.next()
        #expect(initial == Self.tracked([2: .added]))

        tracker.update(currentText: "a\nb\nc\n")
        await clock.waitUntilSleeping(for: .milliseconds(150))
        clock.advance(by: .milliseconds(149))
        // Resumes only while the debounce sleep is still parked 1 ms short of its deadline.
        await clock.waitUntilSleeping(for: .milliseconds(1))
        clock.advance(by: .milliseconds(1))

        let afterDebounce = await updates.next()
        #expect(afterDebounce == Self.tracked([2: .added, 3: .added]))
        tracker.cancel()
    }

    @Test("Coalesces rapid edits into the latest buffer")
    func coalescesRapidEdits() async {
        let clock = SidebarTestManualClock()
        let reader = FixedHeadContentReader(content: "a\n")
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: clock)
        var updates = tracker.updates.makeAsyncIterator()
        tracker.update(currentText: "a\nb\n")
        tracker.refreshBase()
        let initial = await updates.next()
        #expect(initial == Self.tracked([2: .added]))

        tracker.update(currentText: "A\n")
        tracker.update(currentText: "a\nb\nc\n")
        tracker.update(currentText: "x\n")
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))

        let afterBurst = await updates.next()
        #expect(afterBurst == Self.tracked([1: .modified]))
        tracker.cancel()
    }

    @Test("Clears markers when the file stops being tracked")
    func clearsMarkersWhenFileBecomesUntracked() async {
        let reader = FixedHeadContentReader(content: "a\n")
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: SidebarTestManualClock())
        var updates = tracker.updates.makeAsyncIterator()
        tracker.update(currentText: "b\n")
        tracker.refreshBase()
        let initial = await updates.next()
        #expect(initial == Self.tracked([1: .modified]))

        await reader.setContent(nil)
        tracker.refreshBase()

        let afterUntrack = await updates.next()
        #expect(afterUntrack == FilePreviewGitGutterMarkers.untracked)
        tracker.cancel()
    }

    @Test("A new HEAD base moves the markers without a buffer edit")
    func newBaseMovesMarkers() async {
        let reader = FixedHeadContentReader(content: "a\n")
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: SidebarTestManualClock())
        var updates = tracker.updates.makeAsyncIterator()
        tracker.update(currentText: "a\nb\n")
        tracker.refreshBase()
        let initial = await updates.next()
        #expect(initial == Self.tracked([2: .added]))

        await reader.setContent("a\nb\nc\n")
        tracker.refreshBase()

        let afterNewBase = await updates.next()
        #expect(afterNewBase == Self.tracked([2: .removedAtEnd]))
        tracker.cancel()
    }

    @Test("Decodes the base with the buffer's encoding")
    func decodesBaseWithBufferEncoding() async throws {
        let latin1Base = try #require("café\n".data(using: .isoLatin1))
        let reader = FixedHeadContentReader(bytes: latin1Base)
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: SidebarTestManualClock())
        var updates = tracker.updates.makeAsyncIterator()

        tracker.update(encoding: .isoLatin1)
        tracker.update(currentText: "café\nnew\n")
        tracker.refreshBase()

        let initial = await updates.next()
        #expect(initial == Self.tracked([2: .added]))
        tracker.cancel()
    }

    @Test("Outside a repository the repository watch still reads the base once")
    func repositoryWatchWithoutRepositoryReadsBase() async {
        let reader = FixedHeadContentReader(content: "a\n")
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: SidebarTestManualClock())
        var updates = tracker.updates.makeAsyncIterator()

        tracker.update(currentText: "b\n")
        tracker.startWatchingRepository(using: FileContentChangeCoordinator())

        let initial = await updates.next()
        #expect(initial == Self.tracked([1: .modified]))
        tracker.cancel()
    }

    @Test("A HEAD move without an index change refreshes the markers")
    func headMoveRefreshesMarkers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-git-tracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let headPath = directory.appendingPathComponent("HEAD").path
        try Data("ref: refs/heads/main\n".utf8).write(to: URL(fileURLWithPath: headPath))
        let reader = FixedHeadContentReader(content: "a\n", watchedPaths: [headPath])
        let coordinator = FileContentChangeCoordinator()
        let tracker = FilePreviewGitDiffTracker(filePath: Self.path, reader: reader, clock: SidebarTestManualClock())
        var updates = tracker.updates.makeAsyncIterator()
        tracker.update(currentText: "a\nb\n")
        tracker.startWatchingRepository(using: coordinator)
        let initial = await updates.next()
        #expect(initial == Self.tracked([2: .added]))

        await reader.setContent("a\nb\n")
        coordinator.fileWriteCompleted(at: headPath)

        let afterHeadMove = await updates.next()
        #expect(afterHeadMove == Self.tracked([:]))
        tracker.cancel()
    }

    @Test("Dropping the tracker without cancel finishes the update stream")
    func droppingTrackerFinishesUpdates() async throws {
        var tracker: FilePreviewGitDiffTracker? = FilePreviewGitDiffTracker(
            filePath: Self.path,
            reader: FixedHeadContentReader(content: nil),
            clock: SidebarTestManualClock()
        )
        var updates = try #require(tracker).updates.makeAsyncIterator()
        tracker?.startWatchingRepository(using: FileContentChangeCoordinator())

        tracker = nil

        let afterRelease = await updates.next()
        #expect(afterRelease == nil)
    }

    @Test("Cancel finishes the update stream")
    func cancelFinishesUpdates() async {
        let tracker = FilePreviewGitDiffTracker(
            filePath: Self.path,
            reader: FixedHeadContentReader(content: nil),
            clock: SidebarTestManualClock()
        )
        var updates = tracker.updates.makeAsyncIterator()

        tracker.cancel()

        let afterCancel = await updates.next()
        #expect(afterCancel == nil)
    }
}

private actor FixedHeadContentReader: GitHeadContentReading {
    private var bytes: Data?
    private let paths: [String]?

    init(content: String?, watchedPaths: [String]? = nil) {
        bytes = content.map { Data($0.utf8) }
        paths = watchedPaths
    }

    init(bytes: Data?) {
        self.bytes = bytes
        paths = nil
    }

    func setContent(_ content: String?) {
        bytes = content.map { Data($0.utf8) }
    }

    func headContent(forFile absolutePath: String) async -> Data? {
        bytes
    }

    func watchedPaths(forFile absolutePath: String) async -> [String]? {
        paths
    }
}
