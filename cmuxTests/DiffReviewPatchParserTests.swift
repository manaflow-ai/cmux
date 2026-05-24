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

    func testBranchComparisonIncludesWorkingTreeAndUntrackedChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-diff-review-branch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "-b", "main"], in: directory)
        try runGit(["config", "user.name", "cmux tests"], in: directory)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: directory)

        let trackedFile = directory.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: trackedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let title = \"base\"\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "Sources/App.swift"], in: directory)
        try runGit(["commit", "-m", "Initial commit"], in: directory)
        try runGit(["checkout", "-b", "feature/review"], in: directory)
        try "let title = \"committed\"\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["commit", "-am", "Committed branch change"], in: directory)
        try "let title = \"worktree\"\n".write(to: trackedFile, atomically: true, encoding: .utf8)

        let untrackedFile = directory.appendingPathComponent("Sources/NewPanel.swift")
        try "struct NewPanel {}\n".write(to: untrackedFile, atomically: true, encoding: .utf8)

        let snapshot = try await DiffReviewGitClient.loadSnapshot(
            directory: directory.path,
            selectedTargetID: DiffReviewTarget.branch("main").id
        )

        XCTAssertEqual(snapshot.selectedTarget, .branch("main"))
        let trackedReviewFile = try XCTUnwrap(snapshot.files.first { $0.path == "Sources/App.swift" })
        XCTAssertTrue(
            trackedReviewFile.hunks.contains { hunk in
                hunk.lines.contains { $0.content.contains("worktree") }
            },
            "Branch comparisons should include uncommitted tracked working-tree edits."
        )
        let untrackedReviewFile = try XCTUnwrap(snapshot.files.first { $0.path == "Sources/NewPanel.swift" })
        XCTAssertEqual(untrackedReviewFile.status, .untracked)
    }

    @discardableResult
    private func runGit(
        _ arguments: [String],
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(output)", file: file, line: line)
            throw NSError(domain: "DiffReviewPatchParserTests", code: Int(process.terminationStatus))
        }
        return output
    }
}
