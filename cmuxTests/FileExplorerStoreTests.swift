import AppKit
import CmuxFileTree
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Files tree store behavior lives in FileExplorerTreeStoreTests.swift; this
// file keeps the Find controller suite and the provider fixture it uses.

// MARK: - Mock Provider

private final class MockFileExplorerProvider: FileExplorerProvider, @unchecked Sendable {
    var homePath: String
    var isAvailable: Bool

    init(homePath: String = "/home/user", isAvailable: Bool = true) {
        self.homePath = homePath
        self.isAvailable = isAvailable
    }

    func listDirectory(at path: String) async throws -> FileTreeListing {
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return FileTreeListing(entries: [])
    }
}

@MainActor
@Suite(.serialized)
struct FileSearchControllerTests {
    private struct WaitTimeout: Error {}

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchIncludesDotfilesWithoutSearchingGitInternals() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "visible needle\n".write(
            to: rootURL.appendingPathComponent("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "hidden needle\n".write(
            to: rootURL.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        let gitURL = rootURL.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
        try "git needle\n".write(
            to: gitURL.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        for generatedDirectoryName in ["node_modules", "dist", "build", "DerivedData"] {
            let generatedURL = rootURL.appendingPathComponent(generatedDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: generatedURL, withIntermediateDirectories: true)
            try "generated needle\n".write(
                to: generatedURL.appendingPathComponent("generated.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true)
        let finalSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        #expect(finalSnapshot.status == .matches)
        #expect(finalSnapshot.results.contains { $0.relativePath == "visible.txt" })
        #expect(finalSnapshot.results.contains { $0.relativePath == ".env" })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix(".git/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("node_modules/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("dist/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("build/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("DerivedData/") })
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchPublishesAllMatchingFilesInFolder() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let nestedURL = rootURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let matchingFiles = [
            "Alpha.swift",
            "Beta.swift",
            "Nested/Gamma.swift",
        ]
        for relativePath in matchingFiles {
            try "issue3817Token \(relativePath)\n".write(
                to: rootURL.appendingPathComponent(relativePath),
                atomically: true,
                encoding: .utf8
            )
        }
        try "no matching content\n".write(
            to: rootURL.appendingPathComponent("Other.swift"),
            atomically: true,
            encoding: .utf8
        )

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "issue3817Token", rootPath: rootURL.path, isLocal: true)
        let finalSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        #expect(finalSnapshot.status == .matches)
        #expect(Set(finalSnapshot.results.map(\.relativePath)) == Set(matchingFiles))
        #expect(finalSnapshot.results.count == matchingFiles.count)
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchLimitsHighVolumeResultsWithoutWaitingForRipgrepExit() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for index in 0..<650 {
            try "needle \(index)\n".write(
                to: rootURL.appendingPathComponent(String(format: "match-%04d.txt", index)),
                atomically: true,
                encoding: .utf8
            )
        }

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true)
        let finalSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        #expect(finalSnapshot.status == .limited(500))
        #expect(finalSnapshot.results.count == 500)
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchRefreshesWhenContentRevisionChanges() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let emptySnapshot = try await waitForSettledSearchSnapshot { snapshots.last }
        #expect(emptySnapshot.status == .noMatches)

        try "fresh needle\n".write(
            to: rootURL.appendingPathComponent("fresh.txt"),
            atomically: true,
            encoding: .utf8
        )

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 2)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        #expect(refreshedSnapshot.status == .matches)
        #expect(refreshedSnapshot.results.map(\.relativePath) == ["fresh.txt"])
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchRefreshesSameRequestAfterFileContentsChange() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileURL = rootURL.appendingPathComponent("editable.txt")
        try "old text\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let emptySnapshot = try await waitForSettledSearchSnapshot { snapshots.last }
        #expect(emptySnapshot.status == .noMatches)

        try "fresh needle\n".write(to: fileURL, atomically: true, encoding: .utf8)

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        #expect(refreshedSnapshot.status == .matches)
        #expect(refreshedSnapshot.results.map(\.relativePath) == ["editable.txt"])
    }

    @Test
    func testTypingBurstDebouncesFindSearches() async throws {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = SpyFileSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        store.provider = MockFileExplorerProvider(homePath: "/tmp")
        store.setRootPath("/tmp/cmux-find-debounce-test")
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        let searchField = try #require(Self.findSearchField(in: container))
        searchController.searchRequests.removeAll()

        for query in ["p", "pr", "pri", "priv", "priva", "privat", "private"] {
            searchField.stringValue = query
            container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        }

        // Wait on the real completion signal (the debounce firing and issuing its one
        // search) instead of sleeping for the debounce window. The seven synchronous
        // keystrokes feed a single Combine `.debounce`, so it emits exactly once; this
        // returns the instant that single search lands.
        try await waitForSearchRequestCount(1, in: searchController)

        #expect(
            searchController.searchRequests.count <= 1,
            "A burst of typing should coalesce into one ripgrep search per debounce window."
        )
        #expect(searchController.searchRequests.last?.query == "private")
    }

    @Test
    func testSearchFieldReturnCommitsWhenOpenSelectionShortcutsAreUnbound() throws {
        try withIsolatedShortcutSettings {
            let store = FileExplorerStore()
            let state = FileExplorerState()
            let searchController = SpyFileSearchController()
            var openedPaths: [String] = []
            let coordinator = FileExplorerPanelView.Coordinator(
                store: store,
                state: state,
                onOpenFilePreview: { path in
                    openedPaths.append(path)
                }
            )
            let container = FileExplorerContainerView(
                coordinator: coordinator,
                presentation: .find,
                searchController: searchController
            )
            store.provider = MockFileExplorerProvider(homePath: "/tmp")
            store.setRootPath("/tmp/cmux-find-return-fallback-test")
            container.updateHeader(store: store)
            container.updatePresentation(.find)

            KeyboardShortcutSettings.setShortcut(.unbound, for: .fileExplorerOpenSelection)
            KeyboardShortcutSettings.setShortcut(.unbound, for: .fileExplorerOpenSelectionFinderAlias)

            let searchField = try #require(Self.findSearchField(in: container))
            let result = Self.searchResult(relativePath: "selected.txt")
            searchController.publish(FileSearchSnapshot(
                query: "needle",
                results: [result],
                status: .matches,
                isSearching: false
            ))

            let handled = container.control(
                searchField,
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )

            #expect(handled)
            #expect(openedPaths == [result.path])
        }
    }

    @Test
    func testContentRevisionChangeDoesNotRestartActiveFindSearch() async throws {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = SpyFileSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        store.provider = MockFileExplorerProvider(homePath: "/tmp")
        store.setRootPath("/tmp/cmux-find-content-revision-test")
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        let searchField = try #require(Self.findSearchField(in: container))
        searchField.stringValue = "needle"
        container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        try await waitForSearchRequestCount(1, in: searchController)
        #expect(searchController.searchRequests.count == 1)

        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [Self.searchResult(relativePath: "first.txt")],
            status: .searching,
            isSearching: true
        ))
        let originalRequestCount = searchController.searchRequests.count

        store.reload()
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        #expect(
            searchController.searchRequests.count == originalRequestCount,
            "A content revision while a search is active should not cancel and restart the result stream."
        )

        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [Self.searchResult(relativePath: "first.txt")],
            status: .matches,
            isSearching: false
        ))

        #expect(searchController.searchRequests.count == originalRequestCount + 1)
        #expect(searchController.searchRequests.last?.contentRevision == store.contentRevision)
    }

    @Test
    func testRedundantVisibilityAndPresentationPassesDoNotInvalidateLayout() {
        // Regression for #4931: redundant updateNSView passes must not invalidate layout,
        // or the unconditional KVO/isHidden writes re-enter the SwiftUI graph and hang.
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = SpyFileSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        store.provider = MockFileExplorerProvider(homePath: "/tmp")
        store.setRootPath("/tmp/cmux-find-idempotent-layout-test")
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        // updateVisibility runs on every store/content update and is unguarded; a second
        // identical pass must not invalidate layout.
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        // This container is windowless and never runs a layout pass, so the real invalidations
        // above leave layout pending and `needsLayout = false` does not take effect. Run the
        // pending pass first so each probe below measures only new invalidations.
        container.layoutSubtreeIfNeeded()
        container.needsLayout = false
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        #expect(
            !container.needsLayout,
            "A redundant updateVisibility pass must not invalidate layout; otherwise updateNSView re-enters the SwiftUI graph and loops (#4931)."
        )

        // The guard-else in updatePresentation(.find) re-runs updateSearchLayout on every
        // redundant pass (the Cmd+Shift+F re-entry path); it must be a no-op too.
        container.layoutSubtreeIfNeeded()
        container.needsLayout = false
        container.updatePresentation(.find)
        #expect(
            !container.needsLayout,
            "A redundant updatePresentation(.find) pass must not invalidate layout (#4931)."
        )

        // Positive control: a genuine visibility change must still invalidate layout, so
        // the no-op assertions above are meaningful rather than vacuous.
        container.layoutSubtreeIfNeeded()
        container.needsLayout = false
        container.updateVisibility(hasContent: false, isLoading: false, statusMessage: nil)
        #expect(
            container.needsLayout,
            "A genuine visibility change must still invalidate layout."
        )
    }

    @Test
    func testRipgrepResolverPrefersConfiguredBinaryPath() {
        let configuredPath = "/nix/store/custom-ripgrep/bin/rg"
        let fallbackPath = "/usr/local/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == configuredPath || $0 == fallbackPath }
        )

        #expect(executable?.url.path == configuredPath)
    }

    @Test
    func testRipgrepResolverExpandsTildeConfiguredBinaryPath() {
        let configuredPath = "~/.nix-profile/bin/rg"
        let expandedPath = "/Users/nixuser/.nix-profile/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == expandedPath }
        )

        #expect(executable?.url.path == expandedPath)
    }

    @Test
    func testRipgrepResolverChecksNixProfilePathsBeforePATHFallback() {
        let nixProfilePath = "/etc/profiles/per-user/nixuser/bin/rg"
        let pathFallback = "/tmp/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: nil,
            environment: ["PATH": "/tmp/bin"],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == nixProfilePath || $0 == pathFallback }
        )

        #expect(executable?.url.path == nixProfilePath)
    }

    @Test
    func testRipgrepResolverChecksHomeManagerProfilePathsBeforePATHFallback() {
        let homeManagerProfilePath = "/Users/nixuser/.nix-profile/bin/rg"
        let pathFallback = "/tmp/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: nil,
            environment: ["PATH": "/tmp/bin"],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == homeManagerProfilePath || $0 == pathFallback }
        )

        #expect(executable?.url.path == homeManagerProfilePath)
    }

    @Test
    func testRipgrepResolverChecksNixPerUserProfilePathBeforePATHFallback() {
        let perUserProfilePath = "/nix/var/nix/profiles/per-user/nixuser/profile/bin/rg"
        let pathFallback = "/tmp/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: nil,
            environment: ["PATH": "/tmp/bin"],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == perUserProfilePath || $0 == pathFallback }
        )

        #expect(executable?.url.path == perUserProfilePath)
    }

    @Test
    func testRipgrepResolverRejectsNonExecutableConfiguredBinaryPath() {
        let configuredPath = "/nix/store/missing-ripgrep/bin/rg"
        let fallbackPath = "/usr/local/bin/rg"

        let resolution = RipgrepExecutableResolver.resolution(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == fallbackPath }
        )

        #expect(resolution == .configuredPathNotExecutable(configuredPath))
        #expect(RipgrepExecutableResolver.resolve(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == fallbackPath }
        ) == nil)
    }

    @Test
    func testConfiguredRipgrepPathErrorMessageSubstitutesPath() {
        let configuredPath = "/nix/store/missing-ripgrep/bin/rg"

        let message = FileExplorerSearchMessages.configuredRipgrepPathNotExecutable(configuredPath)

        #expect(message.contains(configuredPath))
        #expect(!(message.contains("%@")))
    }

    private static func searchResult(relativePath: String) -> FileSearchResult {
        FileSearchResult(
            path: "/tmp/cmux-find-content-revision-test/\(relativePath)",
            relativePath: relativePath,
            lineNumber: 1,
            columnNumber: 1,
            preview: "needle"
        )
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-file-explorer-store"
        )
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }

        try body()
    }

    private func waitForSearchRequestCount(
        _ expectedCount: Int,
        in searchController: SpyFileSearchController,
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if searchController.searchRequests.count >= expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(expectedCount) file search requests")
        throw WaitTimeout()
    }

    private func waitForSettledSearchSnapshot(
        timeout: TimeInterval = 5,
        _ snapshot: @MainActor @escaping () -> FileSearchSnapshot?
    ) async throws -> FileSearchSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = snapshot(), !current.isSearching {
                return current
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for file search to finish")
        throw WaitTimeout()
    }

    private nonisolated static func hasRipgrep() -> Bool {
        RipgrepExecutableResolver.resolve(configuredPath: nil) != nil
    }

    private static func findSearchField(in root: NSView) -> NSSearchField? {
        if let field = root as? NSSearchField,
           field.accessibilityIdentifier() == "FileExplorerSearchField" {
            return field
        }
        for subview in root.subviews {
            if let field = findSearchField(in: subview) {
                return field
            }
        }
        return nil
    }

    private final class SpyFileSearchController: FileSearchControlling {
        struct SearchRequest: Equatable {
            let query: String
            let rootPath: String
            let isLocal: Bool
            let contentRevision: Int
        }

        var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?
        var searchRequests: [SearchRequest] = []
        var cancelCount = 0

        func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {
            searchRequests.append(SearchRequest(
                query: rawQuery,
                rootPath: rootPath,
                isLocal: isLocal,
                contentRevision: contentRevision
            ))
        }

        func publish(_ snapshot: FileSearchSnapshot) {
            onSnapshotChanged?(snapshot)
        }

        func cancel(clear: Bool) {
            cancelCount += 1
        }
    }
}
