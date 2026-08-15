import CmuxGit
import CmuxSidebarGit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A controllable fake for ``GitDiffWorkspaceChangesServing``.
///
/// An actor so it is `Sendable` and can report call counts deterministically;
/// it yields on an injected stream so tests can handshake on work completing.
private actor FakeChangesService: GitDiffWorkspaceChangesServing {
    let filesByDirectory: [String: WorkspaceChangedFiles]
    let diffsByPath: [String: WorkspaceFileDiff]
    let shouldFailChangedFiles: Bool
    let shouldFailFileDiff: Bool
    let changedContinuation: AsyncStream<Void>.Continuation
    let diffContinuation: AsyncStream<Void>.Continuation

    private(set) var changedFilesCallCount = 0

    init(
        filesByDirectory: [String: WorkspaceChangedFiles],
        diffsByPath: [String: WorkspaceFileDiff],
        shouldFailChangedFiles: Bool,
        shouldFailFileDiff: Bool,
        changedContinuation: AsyncStream<Void>.Continuation,
        diffContinuation: AsyncStream<Void>.Continuation
    ) {
        self.filesByDirectory = filesByDirectory
        self.diffsByPath = diffsByPath
        self.shouldFailChangedFiles = shouldFailChangedFiles
        self.shouldFailFileDiff = shouldFailFileDiff
        self.changedContinuation = changedContinuation
        self.diffContinuation = diffContinuation
    }

    func changedFiles(forDirectory directory: String, force: Bool) async throws -> WorkspaceChangedFiles {
        changedFilesCallCount += 1
        defer { changedContinuation.yield() }
        if shouldFailChangedFiles { throw WorkspaceChangesServiceError.gitFailure }
        return filesByDirectory[directory] ?? .notARepository
    }

    func fileDiff(
        forDirectory directory: String,
        path: String,
        maxLines: Int?
    ) async throws -> WorkspaceFileDiff {
        defer { diffContinuation.yield() }
        if shouldFailFileDiff { throw WorkspaceChangesServiceError.gitFailure }
        return diffsByPath[path] ?? WorkspaceFileDiff(
            path: path,
            oldPath: nil,
            status: .modified,
            isBinary: false,
            additions: 1,
            deletions: 1,
            unifiedDiff: "+line\n-line\n",
            truncated: false,
            totalLineCount: 2,
            contentFingerprint: nil
        )
    }
}

@Suite("Git diff panel view model", .serialized)
@MainActor
struct GitDiffPanelViewModelTests {
    // MARK: Helpers

    private func changedFiles(
        files: [WorkspaceChangedFile],
        branch: String? = "main",
        baseRef: String? = nil,
        comparisonBase: WorkspaceComparisonBase = .head,
        filesChanged: Int? = nil,
        truncated: Bool = false
    ) -> WorkspaceChangedFiles {
        WorkspaceChangedFiles(
            isRepository: true,
            repoRoot: "/repo",
            branch: branch,
            baseRef: baseRef,
            comparisonBase: comparisonBase,
            files: files,
            filesChanged: filesChanged ?? files.count,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions },
            truncated: truncated
        )
    }

    private func file(_ path: String, status: WorkspaceChangeStatus = .modified) -> WorkspaceChangedFile {
        WorkspaceChangedFile(
            path: path,
            oldPath: nil,
            status: status,
            additions: 1,
            deletions: 1,
            isBinary: false
        )
    }

    private func diff(_ path: String, unifiedDiff: String) -> WorkspaceFileDiff {
        WorkspaceFileDiff(
            path: path,
            oldPath: nil,
            status: .modified,
            isBinary: false,
            additions: 1,
            deletions: 1,
            unifiedDiff: unifiedDiff,
            truncated: false,
            totalLineCount: nil,
            contentFingerprint: nil
        )
    }

    private static func waitForSignal(_ stream: AsyncStream<Void>) async {
        for await _ in stream { return }
    }

    private static func waitForSignals(_ stream: AsyncStream<Void>, count: Int) async {
        var seen = 0
        for await _ in stream {
            seen += 1
            if seen >= count { return }
        }
    }

    /// Yields until `state` is `.loaded` with `selectedPath == path` (bounded).
    private static func waitForSelectedDiff(
        _ vm: GitDiffPanelViewModel,
        path: String,
        attempts: Int = 200
    ) async {
        for _ in 0..<attempts {
            if case .loaded(let snapshot) = vm.state, snapshot.selectedPath == path {
                return
            }
            await Task.yield()
            await MainActor.run {}
        }
    }

    // MARK: Tests

    @Test("nil directory shows unavailable")
    func nilDirectoryIsUnavailable() {
        let fake = FakeChangesService(
            filesByDirectory: [:],
            diffsByPath: [:],
            shouldFailChangedFiles: false,
            shouldFailFileDiff: false,
            changedContinuation: AsyncStream.makeStream().1,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(changesService: fake)
        vm.setDirectory(nil)
        guard case .unavailable = vm.state else {
            Issue.record("expected unavailable, got \(vm.state)")
            return
        }
    }

    @Test("non-repository directory shows unavailable")
    func nonRepositoryIsUnavailable() async {
        let (changed, changedContinuation) = AsyncStream<Void>.makeStream()
        let fake = FakeChangesService(
            filesByDirectory: ["/not-repo": .notARepository],
            diffsByPath: [:],
            shouldFailChangedFiles: false,
            shouldFailFileDiff: false,
            changedContinuation: changedContinuation,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(changesService: fake)
        vm.isVisible = true
        vm.setDirectory("/not-repo")
        await Self.waitForSignal(changed)
        await MainActor.run {}
        guard case .unavailable = vm.state else {
            Issue.record("expected unavailable, got \(vm.state)")
            return
        }
    }

    @Test("loads changed files into the loaded state")
    func loadsFiles() async {
        let files = changedFiles(files: [file("a.txt"), file("b.txt")])
        let (changed, changedContinuation) = AsyncStream<Void>.makeStream()
        let fake = FakeChangesService(
            filesByDirectory: ["/repo": files],
            diffsByPath: [:],
            shouldFailChangedFiles: false,
            shouldFailFileDiff: false,
            changedContinuation: changedContinuation,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(changesService: fake)
        vm.isVisible = true
        vm.setDirectory("/repo")
        await Self.waitForSignal(changed)
        await MainActor.run {}
        guard case .loaded(let snapshot) = vm.state else {
            Issue.record("expected loaded, got \(vm.state)")
            return
        }
        #expect(snapshot.files.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(snapshot.selectedPath == nil)
    }

    @Test("selecting a file populates diff rows")
    func selectingFilePopulatesDiffRows() async {
        let files = changedFiles(files: [file("a.txt")])
        let (changed, changedContinuation) = AsyncStream<Void>.makeStream()
        let fake = FakeChangesService(
            filesByDirectory: ["/repo": files],
            diffsByPath: ["a.txt": diff("a.txt", unifiedDiff: "+one\n-two\n")],
            shouldFailChangedFiles: false,
            shouldFailFileDiff: false,
            changedContinuation: changedContinuation,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(changesService: fake)
        vm.isVisible = true
        vm.setDirectory("/repo")
        await Self.waitForSignal(changed)
        await MainActor.run {}
        vm.selectFile("a.txt")
        await Self.waitForSelectedDiff(vm, path: "a.txt")
        guard case .loaded(let snapshot) = vm.state else {
            Issue.record("expected loaded, got \(vm.state)")
            return
        }
        #expect(snapshot.selectedPath == "a.txt")
        #expect(snapshot.diffRows.map(\.kind) == [.addition, .deletion])
        #expect(snapshot.diffRows.map(\.text) == ["+one", "-two"])
    }

    @Test("a git failure shows the error state with retry")
    func gitFailureShowsError() async {
        let (changed, changedContinuation) = AsyncStream<Void>.makeStream()
        let fake = FakeChangesService(
            filesByDirectory: ["/repo": changedFiles(files: [])],
            diffsByPath: [:],
            shouldFailChangedFiles: true,
            shouldFailFileDiff: false,
            changedContinuation: changedContinuation,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(changesService: fake)
        vm.isVisible = true
        vm.setDirectory("/repo")
        await Self.waitForSignal(changed)
        await MainActor.run {}
        guard case .error(_, let retry) = vm.state else {
            Issue.record("expected error, got \(vm.state)")
            return
        }
        #expect(retry)
    }

    @Test("a stale load result is dropped when a newer directory wins")
    func staleGenerationDropped() async {
        let filesA = changedFiles(files: [file("a.txt")])
        let filesB = changedFiles(files: [file("b.txt")])
        let (changed, changedContinuation) = AsyncStream<Void>.makeStream()
        let fake = FakeChangesService(
            filesByDirectory: ["/a": filesA, "/b": filesB],
            diffsByPath: [:],
            shouldFailChangedFiles: false,
            shouldFailFileDiff: false,
            changedContinuation: changedContinuation,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(changesService: fake)
        vm.isVisible = true
        // Two rapid setDirectory calls without yielding between them: the first
        // refresh task is cancelled before it runs, and only the second
        // generation's result may publish.
        vm.setDirectory("/a")
        vm.setDirectory("/b")
        await Self.waitForSignals(changed, count: 2)
        await MainActor.run {}
        guard case .loaded(let snapshot) = vm.state else {
            Issue.record("expected loaded, got \(vm.state)")
            return
        }
        #expect(snapshot.files.files.map(\.path) == ["b.txt"])
    }

    @Test("an invalidation event for the shown directory triggers a refresh")
    func invalidationTriggersRefresh() async {
        let files = changedFiles(files: [file("a.txt")])
        let (changed, changedContinuation) = AsyncStream<Void>.makeStream()
        let (events, eventContinuation) = AsyncStream<WorkspaceGitInvalidationEvent>.makeStream()
        let fake = FakeChangesService(
            filesByDirectory: ["/repo": files],
            diffsByPath: [:],
            shouldFailChangedFiles: false,
            shouldFailFileDiff: false,
            changedContinuation: changedContinuation,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(
            changesService: fake,
            invalidationStreamFactory: { events }
        )
        vm.isVisible = true
        vm.setDirectory("/repo")
        await Self.waitForSignal(changed)
        await MainActor.run {}
        #expect(await fake.changedFilesCallCount == 1)

        eventContinuation.yield(WorkspaceGitInvalidationEvent(directory: "/repo"))
        // The first signal was consumed above; the invalidation produces one more.
        await Self.waitForSignals(changed, count: 1)
        await MainActor.run {}
        #expect(await fake.changedFilesCallCount == 2)
    }

    @Test("an invalidation event for a different directory is ignored")
    func invalidationForOtherDirectoryIgnored() async {
        let files = changedFiles(files: [file("a.txt")])
        let (changed, changedContinuation) = AsyncStream<Void>.makeStream()
        let (events, eventContinuation) = AsyncStream<WorkspaceGitInvalidationEvent>.makeStream()
        let fake = FakeChangesService(
            filesByDirectory: ["/repo": files],
            diffsByPath: [:],
            shouldFailChangedFiles: false,
            shouldFailFileDiff: false,
            changedContinuation: changedContinuation,
            diffContinuation: AsyncStream.makeStream().1
        )
        let vm = GitDiffPanelViewModel(
            changesService: fake,
            invalidationStreamFactory: { events }
        )
        vm.isVisible = true
        vm.setDirectory("/repo")
        await Self.waitForSignal(changed)
        await MainActor.run {}
        #expect(await fake.changedFilesCallCount == 1)

        eventContinuation.yield(WorkspaceGitInvalidationEvent(directory: "/other"))
        // Give the subscription a chance to (incorrectly) fire, then confirm it did not.
        await Task.yield()
        await MainActor.run {}
        #expect(await fake.changedFilesCallCount == 1)
    }
}
