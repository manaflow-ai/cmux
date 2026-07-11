import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7899.
@Suite("Worktree include integration")
struct WorktreeIncludeIntegrationTests {
    @Test("sidebar worktree creation copies ignored files listed in .worktreeinclude")
    func sidebarCreationCopiesIncludedIgnoredFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-include-integration-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try runGit(["init"], in: projectRoot)
        try "*.env\n".write(
            to: projectRoot.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try ".env\n".write(
            to: projectRoot.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "hello\n".write(
            to: projectRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "secret=value\n".write(
            to: projectRoot.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", ".gitignore", ".worktreeinclude", "README.md"], in: projectRoot)
        try runGit([
            "-c", "user.name=cmux Test",
            "-c", "user.email=cmux@example.invalid",
            "commit", "-m", "initial",
        ], in: projectRoot)

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRoot.path)
        let copiedEnvironment = try String(
            contentsOf: URL(fileURLWithPath: result.worktreePath).appendingPathComponent(".env"),
            encoding: .utf8
        )

        #expect(copiedEnvironment == "secret=value\n")
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorktreeIncludeIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }
}
