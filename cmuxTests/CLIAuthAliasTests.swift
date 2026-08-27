import XCTest
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CLINotifyProcessIntegrationRegressionTests {
    func testTopLevelLoginAliasesAuthLogin() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("auth-login")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "auth.status":
                return self.v2Response(id: id, ok: true, result: ["signed_in": false])
            case "auth.begin_sign_in":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "signed_in": true,
                        "user": ["email": "dev@example.com"],
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["login"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Opening sign-in popup on the cmux web app.\nSigned in as dev@example.com.\n")
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"auth.begin_sign_in""#) },
            "Expected login alias to call auth.begin_sign_in, saw \(state.commands)"
        )
    }

    func testTopLevelLogoutAliasesAuthLogout() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("auth-logout")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "auth.status":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "signed_in": true,
                        "user": ["email": "dev@example.com"],
                    ]
                )
            case "auth.sign_out":
                return self.v2Response(id: id, ok: true, result: ["signed_in": false])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["logout"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Signed out.\n")
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"auth.sign_out""#) },
            "Expected logout alias to call auth.sign_out, saw \(state.commands)"
        )
    }

}

@Suite("CodeRouter CLI aliases")
struct CLICoderouterAliasTests {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test("forwards argv and inherited stdio, preferring coderouter")
    func forwardsArgvAndStdioAndExitStatus() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-alias-\(UUID().uuidString)", isDirectory: true)
        let argsURL = root.appendingPathComponent("args.txt", isDirectory: false)
        let stdinURL = root.appendingPathComponent("stdin.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            set -eu
            : > "$CODEROUTER_ARGS_FILE"
            for arg in "$@"; do
              printf '<%s>\\n' "$arg" >> "$CODEROUTER_ARGS_FILE"
            done
            /bin/cat > "$CODEROUTER_STDIN_FILE"
            printf 'coderouter stdout\\n'
            printf 'coderouter stderr\\n' >&2
            exit 37
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )
        try writeExecutable(
            """
            #!/bin/sh
            printf 'the cr fallback must not win over coderouter\\n' >&2
            exit 99
            """,
            at: root.appendingPathComponent("cr", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: [
                "coderouter",
                "add",
                "--provider",
                "codex go",
                "--",
                "echo; touch should-not-run",
            ],
            environment: [
                "PATH": root.path,
                "CODEROUTER_ARGS_FILE": argsURL.path,
                "CODEROUTER_STDIN_FILE": stdinURL.path,
                "CMUX_SOCKET_PATH": makeSocketPath("missing"),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: "interactive login input\n"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 37, Comment(rawValue: result.stderr))
        #expect(result.stdout == "coderouter stdout\n")
        #expect(result.stderr == "coderouter stderr\n")
        #expect(
            try String(contentsOf: argsURL, encoding: .utf8)
                == """
                <add>
                <--provider>
                <codex go>
                <-->
                <echo; touch should-not-run>
                """ + "\n"
        )
        #expect(
            try String(contentsOf: stdinURL, encoding: .utf8)
                == "interactive login input\n"
        )
    }

    @Test("the short alias still prefers coderouter when both names exist")
    func crAliasPrefersCoderouter() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cr-preference-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf 'canonical coderouter\\n'
            exit 41
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )
        try writeExecutable(
            """
            #!/bin/sh
            printf 'the cr executable was selected\\n' >&2
            exit 99
            """,
            at: root.appendingPathComponent("cr", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["cr", "--version"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": makeSocketPath("missing"),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 41, Comment(rawValue: result.stderr))
        #expect(result.stdout == "canonical coderouter\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("falls back to cr and preserves its arguments and exit status")
    func crFallbackPreservesArgumentsAndExitStatus() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cr-alias-\(UUID().uuidString)", isDirectory: true)
        let argsURL = root.appendingPathComponent("args.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf '<%s>\\n' "$@" > "$CR_ARGS_FILE"
            printf 'cr fallback\\n'
            exit 23
            """,
            at: root.appendingPathComponent("cr", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["cr", "login", "--device-auth"],
            environment: [
                "PATH": root.path,
                "CR_ARGS_FILE": argsURL.path,
                "CMUX_SOCKET_PATH": makeSocketPath("missing"),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 23, Comment(rawValue: result.stderr))
        #expect(result.stdout == "cr fallback\n")
        #expect(result.stderr.isEmpty)
        #expect(
            try String(contentsOf: argsURL, encoding: .utf8)
                == "<login>\n<--device-auth>\n"
        )
    }

    @Test("localizes the alias help entry")
    func aliasHelpUsesRequestedLocalization() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let result = runCLI(
            cliPath: cliPath,
            arguments: ["--help"],
            environment: [
                "AppleLanguages": "(ja)",
                "AppleLocale": "ja_JP",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            result.stdout.contains("インストール済み CodeRouter CLI のエイリアス"),
            Comment(rawValue: result.stdout)
        )
        #expect(
            !result.stdout.contains("aliases for the installed CodeRouter CLI"),
            Comment(rawValue: result.stdout)
        )
    }

    @Test("does not leak cmux control environment to the child")
    func childEnvironmentExcludesCmuxControlValues() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-environment-\(UUID().uuidString)", isDirectory: true)
        let environmentURL = root.appendingPathComponent("environment.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            /usr/bin/env | /usr/bin/sort > "$CODEROUTER_ENV_FILE"
            printf 'environment captured\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "env"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_ENV_FILE": environmentURL.path,
                "CODEROUTER_TEST_MARKER": "preserved",
                "CMUX_SOCKET": "/tmp/cmux-private.sock",
                "CMUX_SOCKET_PATH": "/tmp/cmux-private-path.sock",
                "CMUX_SOCKET_CAPABILITY": "capability-secret",
                "CMUX_SOCKET_PASSWORD": "password-secret",
                "CMUX_AUTH_CREDENTIALS_FILE": "/tmp/cmux-credentials",
                "CMUX_WORKSPACE_ID": "workspace-secret",
                "CMUX_SURFACE_ID": "surface-secret",
                "CMUXD_UNIX_PATH": "/tmp/cmuxd-private.sock",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "environment captured\n")
        #expect(result.stderr.isEmpty)
        let childEnvironment = try String(contentsOf: environmentURL, encoding: .utf8)
        let childEnvironmentLines = childEnvironment.split(separator: "\n").map(String.init)
        #expect(
            !childEnvironmentLines.contains { line in
                line.hasPrefix("CMUX_") || line.hasPrefix("CMUXD_")
            },
            Comment(rawValue: childEnvironment)
        )
        #expect(childEnvironmentLines.contains("CODEROUTER_TEST_MARKER=preserved"))
        #expect(!childEnvironment.contains("capability-secret"))
        #expect(!childEnvironment.contains("password-secret"))
        #expect(!childEnvironment.contains("workspace-secret"))
        #expect(!childEnvironment.contains("surface-secret"))
    }

    @Test("keeps launch diagnostics internal")
    func launchFailureDoesNotExposePathOrSystemError() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-launch-failure-\(UUID().uuidString)", isDirectory: true)
        let executableURL = root.appendingPathComponent("coderouter", isDirectory: false)
        let debugLogURL = root.appendingPathComponent("debug.log", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        // An executable file without a recognized format makes execve fail after
        // PATH resolution, exercising the internal diagnostic path.
        try writeExecutable("not an executable format\n", at: executableURL)

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "launch"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": makeSocketPath("launch-failure"),
                "CMUX_DEBUG_LOG": debugLogURL.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 127, Comment(rawValue: result.stderr))
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Could not start the required CLI"))
        #expect(!result.stderr.contains(root.path))
        #expect(!result.stderr.contains("Exec format error"))

#if DEBUG
        let debugLog = try String(contentsOf: debugLogURL, encoding: .utf8)
        #expect(debugLog.contains("cli.coderouter.exec_failed"))
        #expect(debugLog.contains(executableURL.path))
        #expect(debugLog.contains("errno="))
#endif
    }

    @Test("reports an actionable error when neither executable exists")
    func missingExecutableIsActionable() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-missing-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath("missing")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "login"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_CAPABILITY": "missing-capability",
                "CMUX_SOCKET_PASSWORD": "missing-password",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut)
        #expect(result.status == 127, Comment(rawValue: result.stderr))
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Required CLI not found"))
        #expect(result.stderr.contains("Install the command"))
        #expect(!result.stderr.contains("CodeRouter"))
        #expect(!result.stderr.contains("coderouter"))
        #expect(!result.stderr.contains("PATH"))
        #expect(!result.stderr.contains(root.path))
        #expect(!result.stderr.contains(socketPath))
        #expect(!result.stderr.contains("missing-capability"))
        #expect(!result.stderr.contains("missing-password"))
    }

    private func runCLI(
        cliPath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        var childEnvironment = ProcessInfo.processInfo.environment
        for key in childEnvironment.keys where key.hasPrefix("CMUX_") || key.hasPrefix("CMUXD_") {
            childEnvironment.removeValue(forKey: key)
        }
        childEnvironment.merge(environment) { _, newValue in newValue }
        childEnvironment["AppleLanguages"] = childEnvironment["AppleLanguages"] ?? "(en)"
        childEnvironment["AppleLocale"] = childEnvironment["AppleLocale"] ?? "en_US"
        process.environment = childEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return ProcessResult(
                status: 127,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }
        if let standardInput, let stdinPipe,
           let data = standardInput.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
            try? stdinPipe.fileHandleForWriting.close()
        }
        let timedOut: Bool
        switch finished.wait(timeout: .now() + 5) {
        case .success:
            timedOut = false
        case .timedOut:
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func writeExecutable(_ contents: String, at url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(3))-\(shortID).sock"
    }
}
