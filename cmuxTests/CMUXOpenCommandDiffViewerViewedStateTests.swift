import Foundation
import XCTest

/// Diff viewer review-parity slice A: the toggle-viewed shortcut and the
/// review labels the CLI bakes into every generated viewer page.
extension CMUXOpenCommandTests {
    private func makeViewedStateTestRepo() throws -> (rootURL: URL, repoURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let trackedURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        try "one\ntwo\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        return (rootURL, repoURL)
    }

    func testDiffCommandShortcutPayloadIncludesToggleViewed() throws {
        let cliPath = try bundledCLIPath()
        let (rootURL, repoURL) = try makeViewedStateTestRepo()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )
        let payload = try diffViewerPayload(from: result.html)
        let shortcuts = try XCTUnwrap(payload["shortcuts"] as? [String: Any])
        let toggleViewed = try XCTUnwrap(shortcuts["diffViewerToggleViewed"] as? [String: Any])
        let first = try XCTUnwrap(toggleViewed["first"] as? [String: Any])
        XCTAssertEqual(first["key"] as? String, "v")
        XCTAssertEqual(first["command"] as? Bool, false)
        XCTAssertNil(toggleViewed["second"])
    }

    func testDiffCommandLabelsIncludeReviewParityStrings() throws {
        let cliPath = try bundledCLIPath()
        let (rootURL, repoURL) = try makeViewedStateTestRepo()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )
        let payload = try diffViewerPayload(from: result.html)
        let labels = try XCTUnwrap(payload["labels"] as? [String: String])
        for key in [
            "viewed", "markViewed", "markNotViewed", "changedSinceViewed", "filesViewedProgress",
            "filterFiles", "filterAddedFiles", "filterModifiedFiles", "filterDeletedFiles",
            "filterRenamedFiles", "hideViewedFiles", "showViewedFiles", "noFilesMatchFilter",
            "generatedFile", "largeDiff", "loadDiff", "clearFileFilter",
        ] {
            XCTAssertFalse((labels[key] ?? "").isEmpty, "missing diff viewer label \(key)")
        }
        XCTAssertEqual(labels["filesViewedProgress"], "{viewed} of {total} files viewed")
    }
}
