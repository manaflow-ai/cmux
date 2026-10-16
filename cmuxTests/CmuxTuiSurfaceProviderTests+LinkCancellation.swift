import CmuxCloud
import CmuxCloudTui
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CmuxTuiSurfaceProviderTests {
    @Test func sshLinkPassesTheSelectedSessionToItsClient() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("client")
        let argumentsFile = root.appendingPathComponent("arguments")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argumentsFile.path)'
        exit 2
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(
            machineID: "ssh-test", clientURL: client, paths: CloudTuiClientPaths(home: root)
        )
        do {
            _ = try await link.connect(
                route: "ssh://user@fixture", session: "owned-session",
                sshArguments: ["-p", "2222", "-i", "/keys/with spaces", "-o", "ProxyJump=fixture-jump"]
            )
            Issue.record("the fixture exits before connecting")
        } catch CloudMachineLink.LinkError.exited(let status, _) {
            #expect(status == 2)
        }
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let sessionIndex = try #require(arguments.firstIndex(of: "--session"))
        #expect(arguments[sessionIndex + 1] == "owned-session")
        #expect(Array(arguments.prefix(3)) == ["remote", "connect", "ssh://user@fixture"])
        #expect(Array(arguments.suffix(12)) == [
            "--ssh-arg", "-p", "--ssh-arg", "2222", "--ssh-arg", "-i",
            "--ssh-arg", "/keys/with spaces", "--ssh-arg", "-o", "--ssh-arg", "ProxyJump=fixture-jump"
        ])
    }

    @Test(.timeLimit(.minutes(1))) func cancellingLinkConnectStopsItsChildBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cloud-connect-cancel-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("link.pid")
        let client = root.appendingPathComponent("fake-cmux-tui")
        try """
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        exec /bin/sleep 30
        """.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        let link = CloudMachineLink(
            machineID: "test-machine",
            clientURL: client,
            paths: CloudTuiClientPaths(home: root)
        )
        try #require(Darwin.mkfifo(pidFile.path, 0o600) == 0)
        let readyFD = Darwin.open(pidFile.path, O_RDWR | O_NONBLOCK)
        try #require(readyFD >= 0)
        let readyHandle = FileHandle(fileDescriptor: readyFD, closeOnDealloc: true)
        var readyLines = CloudLinkPipe.lines(from: readyHandle).makeAsyncIterator()
        let task = Task {
            try await link.connect(route: "ws://10.0.0.1:1337/v1/link", session: "main")
        }
        defer { task.cancel() }
        let pidLine = try #require(await readyLines.next())
        let pid = try #require(Int32(pidLine))
        defer { _ = Darwin.kill(pid, SIGKILL) }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled link connect must throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("a cancelled link connect returned \(error) instead of CancellationError")
        }
        let killResult = Darwin.kill(pid, 0)
        let killErrno = errno
        #expect(killResult == -1 && killErrno == ESRCH, "the link child must be reaped before connect returns")
    }
}
