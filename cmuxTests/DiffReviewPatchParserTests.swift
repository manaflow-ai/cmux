import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class DiffReviewPatchParserTests: XCTestCase {
    func testParsesModifiedFileHunksAndLineKinds() throws {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,4 @@ func render()
         import Foundation
        -let title = "Old"
        +let title = "New"
        +let enabled = true
         render()
        """

        let files = DiffReviewPatchParser.parse(diff)

        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.path, "Sources/App.swift")
        XCTAssertNil(file.oldPath)
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.addedLineCount, 2)
        XCTAssertEqual(file.deletedLineCount, 1)

        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.oldLength, 3)
        XCTAssertEqual(hunk.newStart, 1)
        XCTAssertEqual(hunk.newLength, 4)
        XCTAssertEqual(hunk.sectionHeading, "func render()")
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .deletion, .addition, .addition, .context])
        XCTAssertTrue(hunk.patch.contains("@@ -1,3 +1,4 @@ func render()"))
    }

    func testUntrackedPathsOverrideAddedStatus() {
        let diff = """
        diff --git a/Sources/NewPanel.swift b/Sources/NewPanel.swift
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/Sources/NewPanel.swift
        @@ -0,0 +1,2 @@
        +import SwiftUI
        +struct NewPanel {}
        """

        let files = DiffReviewPatchParser.parse(diff, untrackedPaths: ["Sources/NewPanel.swift"])

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "Sources/NewPanel.swift")
        XCTAssertEqual(files[0].status, .untracked)
        XCTAssertEqual(files[0].addedLineCount, 2)
        XCTAssertEqual(files[0].deletedLineCount, 0)
    }

    func testLoadSnapshotReportsNotGitRepositoryForPlainDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-diff-review-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await DiffReviewGitClient.loadSnapshot(
                directory: directory.path,
                selectedTargetID: DiffReviewTarget.workingTreeID
            )
            XCTFail("Expected a not-git-repository error")
        } catch let error as DiffReviewGitError {
            XCTAssertEqual(error, .notGitRepository)
        } catch {
            XCTFail("Expected a not-git-repository error, got \(error)")
        }
    }
}
