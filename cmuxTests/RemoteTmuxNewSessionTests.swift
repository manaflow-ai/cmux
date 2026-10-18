import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Focused coverage for the strict remote `new` operation used by
/// `cmux ssh-tmux <host> new <session>`.
@Suite struct RemoteTmuxNewSessionTests {
    @Test @MainActor func controllerOnlyReusesPendingNamedSessionForTheSameRequest() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let environment = try FakeSSHEnvironment(exitCode: 0, stderr: "")
            defer { environment.cleanUp() }
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH(environment.executablePath)
            defer { restoreSSH() }
            let controller = RemoteTmuxController()
            let host = RemoteTmuxHost(destination: "user@host")

            #expect(try await controller.createRemoteSession(host: host, sessionName: "work", requestID: "request-a"))
            #expect(!(try await controller.createRemoteSession(host: host, sessionName: "work", requestID: "request-a")))
            let firstInvocations = try environment.invocations()
            #expect(firstInvocations.count == 1)

            // An independent `new` remains strict even while the first request is awaiting its
            // mirror/authentication retry; it must issue its own create command.
            #expect(try await controller.createRemoteSession(host: host, sessionName: "work", requestID: "request-b"))
            let independentInvocations = try environment.invocations()
            #expect(independentInvocations.count == 2)

            // A successful mirror retires the pending marker, so a later explicit `new` request
            // is allowed to issue another strict create operation.
            controller.completeRemoteSessionCreation(host: host, sessionName: "work", requestID: "request-b")
            #expect(try await controller.createRemoteSession(host: host, sessionName: "work", requestID: "request-c"))
            let secondInvocations = try environment.invocations()
            #expect(secondInvocations.count == 3)
        }
    }

    @Test func createSessionSendsNameAndRemoteWorkingDirectoryAsTmuxArguments() async throws {
        let environment = try FakeSSHEnvironment(exitCode: 0, stderr: "")
        defer { environment.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: environment.executablePath
        )

        try await transport.createSession(
            named: "work",
            workingDirectory: "/srv/project with spaces"
        )

        let invocation = try #require(environment.invocations().last)
        #expect(invocation.contains("'new-session' '-d' '-s' 'work' '-c' '/srv/project with spaces'"))
    }

    @Test func existingNameRemainsACommandFailureInsteadOfImplicitAttach() async throws {
        let environment = try FakeSSHEnvironment(
            exitCode: 1,
            stderr: "duplicate session: work\n"
        )
        defer { environment.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: environment.executablePath
        )

        do {
            try await transport.createSession(named: "work")
            Issue.record("Expected creation to fail for an existing tmux session")
        } catch let error as RemoteTmuxError {
            guard case let .commandFailed(exitCode, stderr) = error else {
                Issue.record("Expected commandFailed, got \(error)")
                return
            }
            #expect(exitCode == 1)
            #expect(stderr.contains("duplicate session: work"))
            #expect(error.message.contains("duplicate session: work"))
        }
    }

    private struct FakeSSHEnvironment {
        let root: URL
        let executablePath: String
        private let logPath: String

        init(exitCode: Int32, stderr: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-tmux-new-session-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            logPath = root.appendingPathComponent("argv.log").path
            let escapedStderr = stderr.replacingOccurrences(of: "'", with: "'\\''")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(logPath)'
            printf '%s' '\(escapedStderr)' >&2
            exit \(exitCode)
            """
            let executable = root.appendingPathComponent("ssh")
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            executablePath = executable.path
        }

        func invocations() throws -> [String] {
            String(decoding: try Data(contentsOf: URL(fileURLWithPath: logPath)), as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
