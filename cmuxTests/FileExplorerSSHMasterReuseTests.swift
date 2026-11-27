import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Background ssh runs beside a `cmux ssh` workspace must reuse its warm
/// ControlMaster and never become one: on a proxied host (Coder `*.coder`
/// ProxyCommand) a probe that negotiates its own master times out.
@Suite(.serialized)
struct FileExplorerSSHMasterReuseTests {
    private static let workspaceControlPath = "/Users/alice/.cmux/ssh/0123456789abcdef0123456789abcdef01234567"
    private static let workspaceSSHOptions = [
        "ControlMaster=auto",
        "ControlPersist=600",
        "ControlPath=\(workspaceControlPath)",
    ]

    @Test
    func explorerProbeReusesWorkspaceMasterWithoutBecomingOne() throws {
        let arguments = ProcessSSHFileExplorerTransport.sshArguments(
            connection: SSHFileExplorerConnection(
                destination: "dev@workspace.coder",
                port: nil,
                identityFile: nil,
                sshOptions: Self.workspaceSSHOptions
            ),
            command: "ls -1paF '/home/dev'"
        )

        try Self.expectReusesWorkspaceMasterWithoutBecomingOne(arguments)
    }

    @Test
    func gitStatusProbeReusesWorkspaceMasterWithoutBecomingOne() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-master-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let argumentsLogURL = directoryURL.appendingPathComponent("ssh-arguments")
        let fakeSSHURL = directoryURL.appendingPathComponent("fake-ssh")
        try #"""
        #!/bin/sh
        for arg in "$@"; do printf '%s\0' "$arg"; done > "$CMUX_TEST_SSH_ARGUMENTS_LOG"
        """#.write(to: fakeSSHURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSHURL.path)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_SSH_ARGUMENTS_LOG"] = argumentsLogURL.path

        _ = GitStatusProvider(
            sshExecutableURL: fakeSSHURL,
            environment: environment
        ).fetchStatusSSH(
            directory: "/home/dev/project",
            destination: "dev@workspace.coder",
            port: nil,
            identityFile: nil,
            sshOptions: Self.workspaceSSHOptions
        )

        let arguments = try String(contentsOf: argumentsLogURL, encoding: .utf8)
            .split(separator: "\0")
            .map(String.init)
        try Self.expectReusesWorkspaceMasterWithoutBecomingOne(arguments)
    }

    /// Asserts on what OpenSSH would do with `arguments`, as resolved by
    /// `ssh -G` without connecting.
    private static func expectReusesWorkspaceMasterWithoutBecomingOne(_ arguments: [String]) throws {
        let configuration = try effectiveSSHConfiguration(arguments)
        #expect(configuration["controlmaster"] == "false", "\(arguments)")
        #expect(configuration["controlpersist"] == "no", "\(arguments)")
        #expect(configuration["controlpath"] == workspaceControlPath, "\(arguments)")
    }

    private static func effectiveSSHConfiguration(_ arguments: [String]) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "ssh -G rejected \(arguments)")

        var configuration: [String: String] = [:]
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, configuration[String(parts[0])] == nil else { continue }
            configuration[String(parts[0])] = String(parts[1])
        }
        return configuration
    }
}
