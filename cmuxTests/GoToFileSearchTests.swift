import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

final class GoToFileSearchTests: XCTestCase {
    func testRankPrefersFilenameMatches() {
        let ranked = GoToFileSearchService.rank(
            paths: ["Sources/Workspace.swift", "Sources/WorkspaceTests.swift", "docs/workspaces.md"],
            query: "workspace",
            limit: 3
        )

        XCTAssertEqual(ranked.first, "Sources/Workspace.swift")
    }

    func testListedPathsUsesGitExcludeStandard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("go-to-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("tracked".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("ignored.log"))
        try Data("untracked".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))

        try runGit(arguments: ["-C", root.path, "init"])
        try runGit(arguments: ["-C", root.path, "add", "tracked.txt", ".gitignore"])
        try runGit(arguments: ["-C", root.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "fixture"])

        let paths = GoToFileSearchService.listedPaths(rootPath: root.path)
        XCTAssertTrue(paths.contains("tracked.txt"))
        XCTAssertTrue(paths.contains("visible.txt"))
        XCTAssertFalse(paths.contains("ignored.log"))
        XCTAssertFalse(paths.contains { $0.hasPrefix(".git/") })
    }

    private func runGit(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
