import Foundation
import XCTest

/// Diff viewer round-1 regressions: untracked files in the unstaged source,
/// persisted viewer preferences seeding the generated page, and the hunk
/// navigation shortcut payload.
extension CMUXOpenCommandTests {
    private func makeDiffTestRepo() throws -> (rootURL: URL, repoURL: URL, trackedURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let trackedURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try ".gitignore\nignored.txt\n".write(
            to: repoURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        return (rootURL, repoURL, trackedURL)
    }

    func testDiffCommandUnstagedIncludesUntrackedFiles() throws {
        let cliPath = try bundledCLIPath()
        let (rootURL, repoURL, trackedURL) = try makeDiffTestRepo()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try "one\ntwo\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try "brand new content\n".write(
            to: repoURL.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored content\n".write(
            to: repoURL.appendingPathComponent("ignored.txt"),
            atomically: true,
            encoding: .utf8
        )

        // The typed sidecar session is what the live viewer renders.
        let unstaged = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(unstaged.patch.contains("+two"), unstaged.patch)
        XCTAssertTrue(unstaged.patch.contains("b/untracked.txt"), unstaged.patch)
        XCTAssertTrue(unstaged.patch.contains("new file mode"), unstaged.patch)
        XCTAssertTrue(unstaged.patch.contains("+brand new content"), unstaged.patch)
        XCTAssertFalse(unstaged.patch.contains("ignored content"), unstaged.patch)

        // An untracked-only working tree is not the friendly empty state.
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        let untrackedOnly = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL
        )
        XCTAssertFalse(untrackedOnly.patch.contains("+two"), untrackedOnly.patch)
        XCTAssertTrue(untrackedOnly.patch.contains("+brand new content"), untrackedOnly.patch)
    }

    func testDiffCommandHonorsPersistedViewerPreferences() throws {
        let cliPath = try bundledCLIPath()
        let (rootURL, repoURL, trackedURL) = try makeDiffTestRepo()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try "one\ntwo\n".write(to: trackedURL, atomically: true, encoding: .utf8)

        let prefsURL = rootURL.appendingPathComponent("diff-viewer-prefs.json")
        try """
        {"layout":"split","wordWrap":true,"diffIndicators":"classic","bogus":"x","lineNumbers":"nope"}
        """.write(to: prefsURL, atomically: true, encoding: .utf8)

        // Persisted preferences seed the layout and the viewerOptions payload;
        // invalid values and unknown keys are dropped.
        let persisted = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            environmentOverrides: ["CMUX_DIFF_VIEWER_PREFS_PATH": prefsURL.path],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )
        let persistedPayload = try diffViewerPayload(from: persisted.html)
        XCTAssertEqual(persistedPayload["layout"] as? String, "split")
        XCTAssertEqual(persistedPayload["layoutSource"] as? String, "default")
        let viewerOptions = try XCTUnwrap(persistedPayload["viewerOptions"] as? [String: Any])
        XCTAssertEqual(viewerOptions["wordWrap"] as? Bool, true)
        XCTAssertEqual(viewerOptions["diffIndicators"] as? String, "classic")
        XCTAssertNil(viewerOptions["bogus"])
        XCTAssertNil(viewerOptions["lineNumbers"])
        XCTAssertNil(viewerOptions["layout"])

        // An explicit --layout flag still wins over the persisted preference.
        let explicit = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged", "--layout", "unified"],
            environmentOverrides: ["CMUX_DIFF_VIEWER_PREFS_PATH": prefsURL.path],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )
        let explicitPayload = try diffViewerPayload(from: explicit.html)
        XCTAssertEqual(explicitPayload["layout"] as? String, "unified")
        XCTAssertEqual(explicitPayload["layoutSource"] as? String, "explicit")
    }

    func testDiffCommandShortcutPayloadIncludesHunkNavigation() throws {
        let cliPath = try bundledCLIPath()
        let (rootURL, repoURL, trackedURL) = try makeDiffTestRepo()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try "one\ntwo\n".write(to: trackedURL, atomically: true, encoding: .utf8)

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )
        let payload = try diffViewerPayload(from: result.html)
        let shortcuts = try XCTUnwrap(payload["shortcuts"] as? [String: Any])
        let nextHunk = try XCTUnwrap(shortcuts["diffViewerNextHunk"] as? [String: Any])
        XCTAssertEqual((try XCTUnwrap(nextHunk["first"] as? [String: Any]))["key"] as? String, "n")
        XCTAssertNil(nextHunk["second"])
        let previousHunk = try XCTUnwrap(shortcuts["diffViewerPreviousHunk"] as? [String: Any])
        XCTAssertEqual((try XCTUnwrap(previousHunk["first"] as? [String: Any]))["key"] as? String, "p")
        XCTAssertNil(previousHunk["second"])
    }
}
