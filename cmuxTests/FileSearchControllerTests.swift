import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Mock Provider


@MainActor
final class FileSearchControllerTests: XCTestCase {
    private struct WaitTimeout: Error {}

    func testSearchIncludesDotfilesWithoutSearchingGitInternals() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

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

        XCTAssertEqual(finalSnapshot.status, .matches)
        XCTAssertTrue(finalSnapshot.results.contains { $0.relativePath == "visible.txt" })
        XCTAssertTrue(finalSnapshot.results.contains { $0.relativePath == ".env" })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix(".git/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("node_modules/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("dist/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("build/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("DerivedData/") })
    }

    func testSearchPublishesAllMatchingFilesInFolder() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

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

        XCTAssertEqual(finalSnapshot.status, .matches)
        XCTAssertEqual(Set(finalSnapshot.results.map(\.relativePath)), Set(matchingFiles))
        XCTAssertEqual(finalSnapshot.results.count, matchingFiles.count)
    }

    func testSearchLimitsHighVolumeResultsWithoutWaitingForRipgrepExit() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

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

        XCTAssertEqual(finalSnapshot.status, .limited(500))
        XCTAssertEqual(finalSnapshot.results.count, 500)
    }

    func testSearchRefreshesWhenContentRevisionChanges() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let emptySnapshot = try await waitForSettledSearchSnapshot { snapshots.last }
        XCTAssertEqual(emptySnapshot.status, .noMatches)

        try "fresh needle\n".write(
            to: rootURL.appendingPathComponent("fresh.txt"),
            atomically: true,
            encoding: .utf8
        )

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 2)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        XCTAssertEqual(refreshedSnapshot.status, .matches)
        XCTAssertEqual(refreshedSnapshot.results.map(\.relativePath), ["fresh.txt"])
    }

    func testSearchRefreshesSameRequestAfterFileContentsChange() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

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
        XCTAssertEqual(emptySnapshot.status, .noMatches)

        try "fresh needle\n".write(to: fileURL, atomically: true, encoding: .utf8)

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        XCTAssertEqual(refreshedSnapshot.status, .matches)
        XCTAssertEqual(refreshedSnapshot.results.map(\.relativePath), ["editable.txt"])
    }

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

        let searchField = try XCTUnwrap(Self.findSearchField(in: container))
        searchController.searchRequests.removeAll()

        for query in ["p", "pr", "pri", "priv", "priva", "privat", "private"] {
            searchField.stringValue = query
            container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertLessThanOrEqual(
            searchController.searchRequests.count,
            1,
            "A burst of typing should coalesce into one ripgrep search per debounce window."
        )
        XCTAssertEqual(searchController.searchRequests.last?.query, "private")
    }

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

        let searchField = try XCTUnwrap(Self.findSearchField(in: container))
        searchField.stringValue = "needle"
        container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        try await waitForSearchRequestCount(1, in: searchController)
        XCTAssertEqual(searchController.searchRequests.count, 1)

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

        XCTAssertEqual(
            searchController.searchRequests.count,
            originalRequestCount,
            "A content revision while a search is active should not cancel and restart the result stream."
        )

        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [Self.searchResult(relativePath: "first.txt")],
            status: .matches,
            isSearching: false
        ))

        XCTAssertEqual(searchController.searchRequests.count, originalRequestCount + 1)
        XCTAssertEqual(searchController.searchRequests.last?.contentRevision, store.contentRevision)
    }

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

        XCTAssertEqual(executable?.url.path, configuredPath)
    }

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

        XCTAssertEqual(executable?.url.path, expandedPath)
    }

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

        XCTAssertEqual(executable?.url.path, nixProfilePath)
    }

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

        XCTAssertEqual(executable?.url.path, homeManagerProfilePath)
    }

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

        XCTAssertEqual(executable?.url.path, perUserProfilePath)
    }

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

        XCTAssertEqual(resolution, .configuredPathNotExecutable(configuredPath))
        XCTAssertNil(RipgrepExecutableResolver.resolve(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == fallbackPath }
        ))
    }

    func testConfiguredRipgrepPathErrorMessageSubstitutesPath() {
        let configuredPath = "/nix/store/missing-ripgrep/bin/rg"

        let message = FileExplorerSearchMessages.configuredRipgrepPathNotExecutable(configuredPath)

        XCTAssertTrue(message.contains(configuredPath))
        XCTAssertFalse(message.contains("%@"))
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
        XCTFail(
            "Timed out waiting for \(expectedCount) file search requests",
            file: file,
            line: line
        )
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
        XCTFail("Timed out waiting for file search to finish")
        throw WaitTimeout()
    }

    private static func hasRipgrep() -> Bool {
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
