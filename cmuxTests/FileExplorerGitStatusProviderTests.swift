import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct FileExplorerGitStatusProviderTests {
    @Test
    func statusQueryDoesNotRefreshGitIndex() throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try Self.runGit(["init"], in: repoURL)
        try Self.runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try Self.runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)

        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "tracked.txt"], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)

        let indexURL = repoURL.appendingPathComponent(".git/index")
        let indexBeforeStatus = try Data(contentsOf: indexURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: trackedURL.path
        )

        _ = GitStatusProvider.fetchStatus(directory: repoURL.path)

        let indexAfterStatus = try Data(contentsOf: indexURL)
        #expect(indexAfterStatus == indexBeforeStatus)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-explorer-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed: \(stderr)")
        if process.terminationStatus != 0 {
            throw GitSetupFailure(message: stderr)
        }
        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    }

    private struct GitSetupFailure: Error {
        let message: String
    }
}
