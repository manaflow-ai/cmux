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

        try Self.initializeRepo(at: repoURL)

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

        _ = GitStatusProvider().fetchStatus(directory: repoURL.path)

        let indexAfterStatus = try Data(contentsOf: indexURL)
        #expect(indexAfterStatus == indexBeforeStatus)
    }

    @Test
    func statusQueryPreservesQuotedAndEscapedFilenames() throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try Self.initializeRepo(at: repoURL)

        let nestedURL = repoURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let trackedURL = nestedURL.appendingPathComponent("quoted \"name\" and \\ slash.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)
        try "two\n".write(to: trackedURL, atomically: true, encoding: .utf8)

        let status = GitStatusProvider().fetchStatus(directory: nestedURL.path)

        #expect(status[trackedURL.path] == .some(.modified))
    }

    @Test
    func statusQueryExcludesSiblingPathPrefixes() throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try Self.initializeRepo(at: repoURL)

        let explorerRootURL = repoURL.appendingPathComponent("work", isDirectory: true)
        let siblingURL = repoURL.appendingPathComponent("workspace-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: explorerRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)

        let visibleURL = explorerRootURL.appendingPathComponent("tracked.txt")
        let siblingFileURL = siblingURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "one\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
        try Self.runGit(["add", "."], in: repoURL)
        try Self.runGit(["commit", "-m", "initial"], in: repoURL)
        try "two\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "two\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)

        let status = GitStatusProvider().fetchStatus(directory: explorerRootURL.path)

        #expect(status[visibleURL.path] == .some(.modified))
        #expect(status[siblingFileURL.path] == nil)
        #expect(status[siblingURL.path] == nil)
    }

    @Test
    func statusQueryMapsTypeChangedAndUnmergedEntries() throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let fakeGitURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            if [ "${CMUX_TEST_GIT_ENV:-}" != "expected" ]; then
                exit 3
            fi
            if [ "${GIT_OPTIONAL_LOCKS:-}" != "0" ]; then
                exit 4
            fi
            case "$1 $2" in
            "rev-parse --show-toplevel")
                printf '%s\n' "$CMUX_TEST_REPO_ROOT"
                ;;
            "status --porcelain=v1")
                printf ' T type-change.txt\0UU conflicted.txt\0'
                ;;
            *)
                exit 2
                ;;
            esac
            """#,
            named: "fake-git",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_GIT_ENV"] = "expected"
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path

        let status = GitStatusProvider(
            gitExecutableURL: fakeGitURL,
            environment: environment
        ).fetchStatus(directory: repoURL.path)

        #expect(
            status[repoURL.appendingPathComponent("type-change.txt").path] == .some(.modified)
        )
        #expect(
            status[repoURL.appendingPathComponent("conflicted.txt").path] == .some(.modified)
        )
    }

    @Test
    func sshStatusQueryUsesInjectedProcessEnvironment() throws {
        let repoURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let fakeSSHURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            if [ "${CMUX_TEST_SSH_ENV:-}" != "expected" ]; then
                exit 3
            fi
            printf '%s\n---GIT_STATUS---\n M remote.txt\0' "$CMUX_TEST_REPO_ROOT"
            """#,
            named: "fake-ssh",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path
        environment["CMUX_TEST_SSH_ENV"] = "expected"

        let status = GitStatusProvider(
            sshExecutableURL: fakeSSHURL,
            environment: environment
        ).fetchStatusSSH(
            directory: repoURL.path,
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )

        #expect(
            status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified)
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-explorer-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private static func writeExecutableScript(
        _ contents: String, named name: String, in directory: URL
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent(name)
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func initializeRepo(at repoURL: URL) throws {
        try Self.runGit(["init"], in: repoURL)
        try Self.runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try Self.runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }
}
