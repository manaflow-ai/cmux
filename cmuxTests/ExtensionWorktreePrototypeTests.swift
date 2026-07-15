import Foundation
@_implementationOnly import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ExtensionWorktreePrototypeTests: XCTestCase {
    func testPipeOutputCollectorDrainsBufferedOutputOnFinish() async throws {
        let pipe = Pipe()
        let collector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)

        pipe.fileHandleForWriting.write(Data("exclude-path\n".utf8))
        try pipe.fileHandleForWriting.close()

        let output = await collector.finish()

        XCTAssertEqual(String(data: output, encoding: .utf8), "exclude-path\n")
    }

    func testCreateWorktreeKeepsCmuxDirectoryLocallyIgnored() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-worktree-prototype-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try runGit(["init"], in: projectRoot)
        try "hello\n".write(to: projectRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "README.md"], in: projectRoot)
        _ = try runGit([
            "-c", "user.name=cmux Test",
            "-c", "user.email=cmux@example.invalid",
            "commit",
            "-m",
            "initial"
        ], in: projectRoot)

        let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRoot.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.worktreePath))
        XCTAssertTrue(result.workspaceTitle.hasPrefix("cmux-sidebar-"))
        let status = try runGit(["status", "--short", "--untracked-files=all"], in: projectRoot)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
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
            // Apple's `/usr/bin/git` shim resolves the real git via
            // `xcodebuild -find git`. On a CI runner whose xcode-select default is
            // an Xcode ABI-incompatible with the test host, that resolution
            // dlopen-crashes ("Symbol not found" / "Error loading required
            // libraries") before git can run. That is a runner toolchain defect,
            // not a product failure, so skip rather than fail. scripts/select-ci-
            // xcode.sh aligns the default to prevent this; this guard keeps the
            // test honest if a runner still diverges.
            if output.contains("libxcodebuildLoader")
                || output.contains("Error loading required libraries") {
                throw XCTSkip("git toolchain unavailable on this runner: \(output)")
            }
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(output)")
            throw NSError(domain: "ExtensionWorktreePrototypeTests", code: Int(process.terminationStatus))
        }
        return output
    }
}
