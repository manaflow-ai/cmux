import AppKit
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileSearchRipgrepParserTests: XCTestCase {
    func testParseMatchLineBuildsRelativeSearchResult() {
        let line = """
        {"type":"match","data":{"path":{"text":"/tmp/project/Sources/App.swift"},"lines":{"text":"let title = \\"Search files\\"\\n"},"line_number":42,"submatches":[{"match":{"text":"Search"},"start":13,"end":19}]}}
        """

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.path, "/tmp/project/Sources/App.swift")
        XCTAssertEqual(result?.relativePath, "Sources/App.swift")
        XCTAssertEqual(result?.lineNumber, 42)
        XCTAssertEqual(result?.columnNumber, 14)
        XCTAssertEqual(result?.preview, "let title = \"Search files\"")
    }

    func testParseMatchLineAcceptsBytesPayloads() throws {
        let line = try makeMatchLine(
            pathPayload: [
                "bytes": Data("/tmp/project/Sources/Bytes.swift".utf8).base64EncodedString(),
            ],
            linesPayload: [
                "bytes": Data("let title = \"Search files\"\n".utf8).base64EncodedString(),
            ]
        )

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.path, "/tmp/project/Sources/Bytes.swift")
        XCTAssertEqual(result?.relativePath, "Sources/Bytes.swift")
        XCTAssertEqual(result?.lineNumber, 7)
        XCTAssertEqual(result?.columnNumber, 5)
        XCTAssertEqual(result?.preview, "let title = \"Search files\"")
    }

    func testParseMatchLineMapsInvalidUtf8BytesPayloads() throws {
        let line = try makeMatchLine(
            pathPayload: [
                "bytes": Data("/tmp/project/Sources/Invalid.swift".utf8).base64EncodedString(),
            ],
            linesPayload: [
                "bytes": Data([0x20, 0x66, 0x6f, 0x80, 0x6f, 0x0a] as [UInt8]).base64EncodedString(),
            ]
        )

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.path, "/tmp/project/Sources/Invalid.swift")
        XCTAssertEqual(result?.relativePath, "Sources/Invalid.swift")
        XCTAssertEqual(result?.preview.unicodeScalars.map(\.value), [102, 111, 65_533, 111])
    }

    func testParseMatchLineUsesSharedRelativePathBoundaryRules() throws {
        let line = try makeMatchLine(
            pathPayload: [
                "text": "/tmp/project-backup/Sources/App.swift",
            ],
            linesPayload: [
                "text": "let title = \"Search files\"\n",
            ]
        )

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.relativePath, "/tmp/project-backup/Sources/App.swift")
    }

    func testParseMatchLineUsesSharedRelativePathSymlinkStandardization() throws {
        let line = try makeMatchLine(
            pathPayload: [
                "text": "/private/tmp/project/Sources/App.swift",
            ],
            linesPayload: [
                "text": "let title = \"Search files\"\n",
            ]
        )

        let result = FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project")

        XCTAssertEqual(result?.path, "/private/tmp/project/Sources/App.swift")
        XCTAssertEqual(result?.relativePath, "Sources/App.swift")
    }

    func testParseMatchLineIgnoresNonMatchEvents() {
        let line = #"{"type":"summary","data":{"elapsed_total":{"secs":0,"nanos":1}}}"#

        XCTAssertNil(FileSearchRipgrepParser.parseMatchLine(line, rootPath: "/tmp/project"))
    }

    private func makeMatchLine(
        pathPayload: [String: Any],
        linesPayload: [String: Any]
    ) throws -> String {
        let object: [String: Any] = [
            "type": "match",
            "data": [
                "path": pathPayload,
                "lines": linesPayload,
                "line_number": 7,
                "submatches": [
                    [
                        "match": ["text": "title"],
                        "start": 4,
                        "end": 9,
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

final class FileSearchOutputPipelineTests: XCTestCase {
    func testFinishPreservesLimitedStatusFromTrailingBufferedLine() async throws {
        let pipeline = FileSearchOutputPipeline(
            rootPath: "/tmp/project",
            maxResults: 1,
            snapshotInterval: 60
        )
        let line = try makeMatchLine(relativePath: "Sources/App.swift")

        let streamingUpdate = await pipeline.consumeStdout(Data(line.utf8))
        XCTAssertNil(streamingUpdate, "A match without a trailing newline should remain buffered until finish.")

        let finalUpdate = await pipeline.finish(status: 0)

        XCTAssertEqual(finalUpdate.status, .limited(1))
        XCTAssertEqual(finalUpdate.results.map(\.relativePath), ["Sources/App.swift"])
        XCTAssertFalse(finalUpdate.isSearching)
        XCTAssertTrue(finalUpdate.shouldStopProcess)
    }

    func testFinishKeepsEarlierLimitedStatusAfterStreamingLimit() async throws {
        let pipeline = FileSearchOutputPipeline(
            rootPath: "/tmp/project",
            maxResults: 1,
            snapshotInterval: 60
        )
        let line = try makeMatchLine(relativePath: "Sources/App.swift") + "\n"

        let maybeStreamingUpdate = await pipeline.consumeStdout(Data(line.utf8))
        let streamingUpdate = try XCTUnwrap(maybeStreamingUpdate)
        XCTAssertEqual(streamingUpdate.status, .limited(1))
        XCTAssertTrue(streamingUpdate.shouldStopProcess)

        let finalUpdate = await pipeline.finish(status: 0)

        XCTAssertEqual(finalUpdate.status, .limited(1))
        XCTAssertEqual(finalUpdate.results.map(\.relativePath), ["Sources/App.swift"])
        XCTAssertFalse(finalUpdate.isSearching)
        XCTAssertTrue(finalUpdate.shouldStopProcess)
    }

    private func makeMatchLine(relativePath: String) throws -> String {
        let object: [String: Any] = [
            "type": "match",
            "data": [
                "path": [
                    "text": "/tmp/project/\(relativePath)",
                ],
                "lines": [
                    "text": "let title = \"Search files\"\n",
                ],
                "line_number": 7,
                "submatches": [
                    [
                        "match": ["text": "title"],
                        "start": 4,
                        "end": 9,
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("File search workspace scope")
@MainActor
struct FileSearchWorkspaceScopeTests {
    private enum WaitTimeout: Error { case timedOut }

    @Test("Same-path local workspace switch resets Find search scope")
    func samePathLocalWorkspaceSwitchResetsFindSearchScope() async throws {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = SpyFileSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: state, onOpenFilePreview: { _ in })
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .find, searchController: searchController)
        let rootPath = "/tmp/cmux-find-same-directory-test"

        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: rootPath))
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        let searchField = try #require(Self.findSearchField(in: container))
        searchController.searchRequests.removeAll()
        searchField.stringValue = "adfasdf"
        container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        try await waitForSearchRequestCount(1, in: searchController)
        searchController.publish(FileSearchSnapshot(query: "adfasdf", results: [], status: .noMatches, isSearching: false))

        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: rootPath))
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        #expect(searchField.stringValue == "")
        #expect(container.searchSnapshot == .empty)
    }

    private func waitForSearchRequestCount(_ expectedCount: Int, in searchController: SpyFileSearchController) async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if searchController.searchRequests.count >= expectedCount { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(expectedCount) file search requests")
        throw WaitTimeout.timedOut
    }

    private static func findSearchField(in root: NSView) -> NSSearchField? {
        if let field = root as? NSSearchField, field.accessibilityIdentifier() == "FileExplorerSearchField" { return field }
        for subview in root.subviews {
            if let field = findSearchField(in: subview) { return field }
        }
        return nil
    }

    private final class SpyFileSearchController: FileSearchControlling {
        var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?
        var searchRequests: [String] = []

        func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {
            searchRequests.append(rawQuery)
        }

        func publish(_ snapshot: FileSearchSnapshot) {
            onSnapshotChanged?(snapshot)
        }

        func cancel(clear: Bool) {}
    }
}
