import XCTest
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Minimal authenticated-socket stand-in for routed alias tests. The real app
/// performs the same request over its local control socket. Keeping this test
/// server here lets the child-launch tests exercise the FD 3 boundary without
/// starting the full AppKit host.
private final class CLICoderouterMockHandoffServer: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var commands: [String] = []
        let handled = DispatchSemaphore(value: 0)
    }

    let path: String
    let lease = "crh_" + String(repeating: "H", count: 43)
    private let listenerFD: Int32
    private let state: State
    private let lifecycleLock = NSLock()
    private var stopped = false

    init(name: String) throws {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let path = "/tmp/cli-\(name.prefix(8))-\(shortID).sock"
        let listenerFD = try Self.bindUnixSocket(at: path)
        self.path = path
        self.listenerFD = listenerFD
        self.state = State()

        let response = #"{"id":"mock","ok":true,"result":{"teamId":"team_test","lease":"\#(lease)","expiresAt":"2099-01-01T00:00:00Z"}}"#
        let state = self.state
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer {
                    Darwin.close(clientFD)
                    state.handled.signal()
                }
                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                    state.lock.lock()
                    state.commands.append(line)
                    state.lock.unlock()
                    return response
                }
            },
            onListenerClosed: {
                state.handled.signal()
            }
        )
    }

    func waitForRequest(timeout: TimeInterval = 5) -> Bool {
        state.handled.wait(timeout: .now() + timeout) == .success
    }

    func commandSnapshot() -> [String] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.commands
    }

    func stop() {
        lifecycleLock.lock()
        guard !stopped else {
            lifecycleLock.unlock()
            return
        }
        stopped = true
        lifecycleLock.unlock()
        CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
        Darwin.close(listenerFD)
        unlink(path)
    }

    deinit { stop() }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to create handoff socket",
            ])
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG), userInfo: nil)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for (index, byte) in bytes.enumerated() {
                    buffer[index] = CChar(bitPattern: byte)
                }
                buffer[bytes.count] = 0
            }
        }
#if os(macOS)
        address.sun_len = UInt8(min(MemoryLayout<sockaddr_un>.size, 255))
#endif
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let bindError = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(bindError), userInfo: nil)
        }
        _ = chmod(path, 0o600)
        return fd
    }
}

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
        let handoffServer = try CLICoderouterMockHandoffServer(name: "argv")
        defer { handoffServer.stop() }
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
            IFS= read -r lease <&3
            printf '<handoff=%s>\\n' "$lease" >> "$CODEROUTER_ARGS_FILE"
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
                "--help",
            ],
            environment: [
                "PATH": root.path,
                "CODEROUTER_ARGS_FILE": argsURL.path,
                "CODEROUTER_STDIN_FILE": stdinURL.path,
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: "interactive login input\n"
        )

        #expect(handoffServer.waitForRequest(), "The routed alias must mint through the socket")
        #expect(handoffServer.commandSnapshot().contains { $0.contains("coderouter.handoff") })
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
                <--help>
                <handoff=\(handoffServer.lease)>
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

    @Test("capabilities stays credential-free when cmux is absent")
    func capabilitiesDoesNotTouchControlSocket() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-capabilities-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf 'capabilities-ok\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "capabilities", "--json"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": makeSocketPath("missing"),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "capabilities-ok\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("closes inherited descriptors at the CodeRouter boundary")
    func closesInheritedDescriptorBeyondHandoffFD() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-fd-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let sentinelFD = Darwin.open("/dev/null", O_RDONLY)
        #expect(sentinelFD >= 0)
        guard sentinelFD >= 0 else { return }
        defer { Darwin.close(sentinelFD) }
        let descriptorFlags = fcntl(sentinelFD, F_GETFD)
        #expect(descriptorFlags >= 0)
        _ = fcntl(sentinelFD, F_SETFD, descriptorFlags & ~FD_CLOEXEC)

        try writeExecutable(
            """
            #!/bin/sh
            if [ -e "/dev/fd/$CODEROUTER_SENTINEL_FD" ]; then
              printf 'sentinel-open\\n'
            else
              printf 'sentinel-closed\\n'
            fi
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_SENTINEL_FD": String(sentinelFD),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "sentinel-closed\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("falls back to cr and preserves its arguments and exit status")
    func crFallbackPreservesArgumentsAndExitStatus() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "fallback")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cr-alias-\(UUID().uuidString)", isDirectory: true)
        let argsURL = root.appendingPathComponent("args.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            IFS= read -r _lease <&3
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
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(handoffServer.waitForRequest(), "The fallback alias must mint through the socket")
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
            // Use the credential-free top-level provider version form so this
            // environment-boundary test does not need a live cmux socket.
            arguments: ["coderouter", "--version"],
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
                "STACK_ACCESS_TOKEN": "stack-access-secret",
                "STACK_REFRESH_TOKEN": "stack-refresh-secret",
                "OPENAI_API_KEY": "openai-secret",
                "GITHUB_PAT": "github-pat-secret",
                "GITHUB_TOKEN": "github-token-secret",
                "CUSTOM_SECRET_TOKEN": "custom-secret-token",
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
        #expect(!childEnvironment.contains("stack-access-secret"))
        #expect(!childEnvironment.contains("stack-refresh-secret"))
        #expect(!childEnvironment.contains("openai-secret"))
        #expect(!childEnvironment.contains("github-pat-secret"))
        #expect(!childEnvironment.contains("github-token-secret"))
        #expect(!childEnvironment.contains("custom-secret-token"))
    }

    @Test("keeps launch diagnostics internal")
    func launchFailureDoesNotExposePathOrSystemError() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "failure")
        defer { handoffServer.stop() }
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
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_DEBUG_LOG": debugLogURL.path,
            ]
        )

        #expect(handoffServer.waitForRequest(), "The launch failure must occur after handoff")
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
