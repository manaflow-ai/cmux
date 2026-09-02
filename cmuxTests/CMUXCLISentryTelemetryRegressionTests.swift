import Darwin
import Foundation
import Testing

private final class CMUXCLISentryTelemetryBundleToken {}

@Suite struct CMUXCLISentryTelemetryRegressionTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    @Test func staleSocketConnectRefusalDoesNotCaptureSentryTelemetry() throws {
        let cliPath = try bundledCLIPath()
        let root = URL(
            fileURLWithPath: "/tmp/cmux-sr-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("cmux.sock", isDirectory: false).path
        try createStaleSocketFile(at: socketPath)
        defer { unlink(socketPath) }

        let probePath = root.appendingPathComponent("sentry-probe.txt", isDirectory: false).path
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: sentryProbeEnvironment(socketPath: socketPath, probePath: probePath),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.lowercased().contains("connection refused"), Comment(rawValue: result.stdout))
        #expect(
            !FileManager.default.fileExists(atPath: probePath),
            Comment(rawValue: (try? String(contentsOfFile: probePath, encoding: .utf8)) ?? result.stdout)
        )
    }

    @Test func missingSocketDoesNotCaptureSentryTelemetry() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("missing.sock", isDirectory: false).path
        let probePath = root.appendingPathComponent("sentry-probe.txt", isDirectory: false).path
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: sentryProbeEnvironment(socketPath: socketPath, probePath: probePath),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.lowercased().contains("socket not found"), Comment(rawValue: result.stdout))
        #expect(
            !FileManager.default.fileExists(atPath: probePath),
            Comment(rawValue: (try? String(contentsOfFile: probePath, encoding: .utf8)) ?? result.stdout)
        )
    }

    @Test func unexpectedSocketTelemetryStoresWithoutBlockingForSentryFlush() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = "127.0.0.1:\(try unusedRelayPort())"
        let captureProbePath = root.appendingPathComponent("sentry-capture-probe.txt", isDirectory: false).path
        let storeProbePath = root.appendingPathComponent("sentry-store-probe.txt", isDirectory: false).path
        var environment = sentryProbeEnvironment(socketPath: socketPath, probePath: captureProbePath)
        environment["CMUX_CLI_SENTRY_STORE_PROBE_PATH"] = storeProbePath

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 2
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("Missing relay auth metadata"), Comment(rawValue: result.stdout))
        #expect(
            FileManager.default.fileExists(atPath: captureProbePath),
            Comment(rawValue: "Unexpected relay auth failures should still be captured as telemetry-worthy errors. Output: \(result.stdout)")
        )
        #expect(
            FileManager.default.fileExists(atPath: storeProbePath),
            Comment(rawValue: "Unexpected relay auth failures should be stored durably without synchronously flushing Sentry. Output: \(result.stdout)")
        )
    }

    @Test func structuredProtocolCodeControlsSentryCapture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-structured-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unavailableProbe = root.appendingPathComponent("unavailable-probe.txt").path
        let unavailableResult = try runStructuredErrorProbe(
            code: "unavailable",
            probePath: unavailableProbe,
            root: root
        )
        #expect(!unavailableResult.timedOut, Comment(rawValue: unavailableResult.stdout))
        #expect(unavailableResult.status != 0, Comment(rawValue: unavailableResult.stdout))
        #expect(unavailableResult.stdout.lowercased().contains("unavailable"), Comment(rawValue: unavailableResult.stdout))
        #expect(!FileManager.default.fileExists(atPath: unavailableProbe))

        let actionableProbe = root.appendingPathComponent("actionable-probe.txt").path
        let actionableResult = try runStructuredErrorProbe(
            code: "internal_error",
            probePath: actionableProbe,
            root: root
        )
        #expect(!actionableResult.timedOut, Comment(rawValue: actionableResult.stdout))
        #expect(actionableResult.status != 0, Comment(rawValue: actionableResult.stdout))
        #expect(
            actionableResult.stdout.contains("internal_error: TabManager not available"),
            Comment(rawValue: actionableResult.stdout)
        )
        #expect(FileManager.default.fileExists(atPath: actionableProbe))
    }

    @Test func routineProtocolOutcomesDoNotCaptureSentryTelemetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-routine-outcomes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for code in ["invalid_params", "not_found", "protected"] {
            let probePath = root.appendingPathComponent("\(code)-probe.txt").path
            let result = try runStructuredErrorProbe(
                code: code,
                probePath: probePath,
                root: root
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status != 0, Comment(rawValue: result.stdout))
            #expect(result.stdout.lowercased().contains(code), Comment(rawValue: result.stdout))
            #expect(
                !FileManager.default.fileExists(atPath: probePath),
                Comment(rawValue: "Routine protocol outcome \(code) must not create Sentry telemetry. Output: \(result.stdout)")
            )
        }
    }

    @Test func localPiSurfaceUnavailableSentinelDoesNotCaptureSentryTelemetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-pi-unavailable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let probePath = root.appendingPathComponent("pi-unavailable-probe.txt").path
        let result = try runPiSurfaceUnavailableProbe(
            surfaceID: surfaceID,
            probePath: probePath,
            root: root
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 69, Comment(rawValue: result.stdout))
        #expect(result.stdout.lowercased().contains("surface not found"), Comment(rawValue: result.stdout))
        #expect(
            !FileManager.default.fileExists(atPath: probePath),
            Comment(rawValue: "Pi's local surface-unavailable sentinel must not create Sentry telemetry. Output: \(result.stdout)")
        )
    }

    @Test func expectedAgentHookFailureDoesNotConsumeActionableThrottleSlot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-agent-hook-throttle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "sentry-hook-shared-\(UUID().uuidString)"
        let expectedProbe = root.appendingPathComponent("expected.txt").path
        let expectedResult = try runAgentHookErrorProbe(
            message: "TabManager not available",
            probePath: expectedProbe,
            root: root,
            sessionID: sessionID
        )
        #expect(!expectedResult.timedOut, Comment(rawValue: expectedResult.stdout))
        #expect(!FileManager.default.fileExists(atPath: expectedProbe))

        let actionableProbe = root.appendingPathComponent("actionable.txt").path
        let actionableResult = try runAgentHookErrorProbe(
            message: "remote proxy failed: TabManager not available",
            probePath: actionableProbe,
            root: root,
            sessionID: sessionID
        )
        #expect(!actionableResult.timedOut, Comment(rawValue: actionableResult.stdout))
        #expect(
            FileManager.default.fileExists(atPath: actionableProbe),
            Comment(rawValue: "An actionable failure after expected noise must remain reportable. Output: \(actionableResult.stdout)")
        )
    }

    @Test func agentHookLifecycleClassificationKeepsActionableFailures() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-agent-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectedProbe = root.appendingPathComponent("expected-agent-hook.txt").path
        let expectedResult = try runAgentHookErrorProbe(
            message: "TabManager not available",
            probePath: expectedProbe,
            root: root
        )
        #expect(!expectedResult.timedOut, Comment(rawValue: expectedResult.stdout))
        #expect(!FileManager.default.fileExists(atPath: expectedProbe))

        let actionableProbe = root.appendingPathComponent("actionable-agent-hook.txt").path
        let actionableResult = try runAgentHookErrorProbe(
            message: "remote proxy failed: TabManager not available",
            probePath: actionableProbe,
            root: root
        )
        #expect(!actionableResult.timedOut, Comment(rawValue: actionableResult.stdout))
        #expect(FileManager.default.fileExists(atPath: actionableProbe))
    }

    @Test func foreignBundleIdentityDoesNotCaptureSentryTelemetry() throws {
        // The cmux repo is public and rebranded forks have shipped with the
        // cmux CLI DSN intact (Sentry issue CMUXTERM-MACOS-1RZF: ~11k
        // "mosaic_cli" events). A build whose identity is not a cmux bundle
        // must not emit CLI Sentry telemetry, even for capture-worthy errors.
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-sentry-foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = "127.0.0.1:\(try unusedRelayPort())"
        let captureProbePath = root.appendingPathComponent("sentry-capture-probe.txt", isDirectory: false).path
        let storeProbePath = root.appendingPathComponent("sentry-store-probe.txt", isDirectory: false).path
        var environment = sentryProbeEnvironment(socketPath: socketPath, probePath: captureProbePath)
        environment["CMUX_CLI_SENTRY_STORE_PROBE_PATH"] = storeProbePath
        environment["CMUX_BUNDLE_ID"] = "mosaic.com.emergent.app"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 2
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("Missing relay auth metadata"), Comment(rawValue: result.stdout))
        #expect(
            !FileManager.default.fileExists(atPath: captureProbePath),
            Comment(rawValue: "A non-cmux build identity must not capture CLI Sentry telemetry. Output: \(result.stdout)")
        )
        #expect(
            !FileManager.default.fileExists(atPath: storeProbePath),
            Comment(rawValue: "A non-cmux build identity must not store CLI Sentry envelopes. Output: \(result.stdout)")
        )
    }

    @Test func commandTimeoutTelemetryIsFingerprintedAndThrottledPerStage() throws {
        let cliPath = try bundledCLIPath()
        let root = URL(
            fileURLWithPath: "/tmp/cmux-st-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A bound, listening socket that never accepts or replies: connect and
        // write succeed, the response read times out.
        let socketPath = root.appendingPathComponent("cmux.sock", isDirectory: false).path
        let listenerFD = try muteListeningSocketDescriptor(at: socketPath)
        defer {
            close(listenerFD)
            unlink(socketPath)
        }

        func runPing(captureProbePath: String, storeProbePath: String) -> ProcessRunResult {
            var environment = sentryProbeEnvironment(socketPath: socketPath, probePath: captureProbePath)
            environment["CMUX_CLI_SENTRY_STORE_PROBE_PATH"] = storeProbePath
            // The throttle claim state defaults to the real user home
            // (expandingTildeInPath ignores the HOME override), so pin it
            // inside the test root: both runs must share one state file
            // without touching or depending on the machine's own state.
            environment["CMUX_CLAUDE_HOOK_STATE_PATH"] = root
                .appendingPathComponent("claude-hook-sessions.json", isDirectory: false).path
            return runProcess(
                executablePath: cliPath,
                arguments: ["ping"],
                environment: environment,
                timeout: 10
            )
        }

        let firstCaptureProbe = root.appendingPathComponent("capture-1.txt", isDirectory: false).path
        let firstStoreProbe = root.appendingPathComponent("store-1.txt", isDirectory: false).path
        let first = runPing(captureProbePath: firstCaptureProbe, storeProbePath: firstStoreProbe)

        #expect(!first.timedOut, Comment(rawValue: first.stdout))
        #expect(first.status != 0, Comment(rawValue: first.stdout))
        #expect(first.stdout.contains("Command timed out"), Comment(rawValue: first.stdout))
        #expect(
            FileManager.default.fileExists(atPath: firstCaptureProbe),
            Comment(rawValue: "The first timed-out command per stage must stay reportable. Output: \(first.stdout)")
        )
        let firstStorePayload = (try? String(contentsOfFile: firstStoreProbe, encoding: .utf8)) ?? "<missing>"
        #expect(
            firstStorePayload.contains("fingerprint=cmux-cli|socket_command|command-timed-out"),
            Comment(rawValue: "Timed-out commands need their own stage-scoped Sentry fingerprint. Store probe: \(firstStorePayload)")
        )

        let secondCaptureProbe = root.appendingPathComponent("capture-2.txt", isDirectory: false).path
        let secondStoreProbe = root.appendingPathComponent("store-2.txt", isDirectory: false).path
        let second = runPing(captureProbePath: secondCaptureProbe, storeProbePath: secondStoreProbe)

        #expect(!second.timedOut, Comment(rawValue: second.stdout))
        #expect(second.status != 0, Comment(rawValue: second.stdout))
        #expect(second.stdout.contains("Command timed out"), Comment(rawValue: second.stdout))
        #expect(
            !FileManager.default.fileExists(atPath: secondCaptureProbe),
            Comment(rawValue: "A repeat timed-out command inside the throttle window must be deduplicated, not re-captured. Output: \(second.stdout)")
        )
        #expect(
            !FileManager.default.fileExists(atPath: secondStoreProbe),
            Comment(rawValue: "A throttled timed-out command must not store a Sentry envelope. Output: \(second.stdout)")
        )
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: CMUXCLISentryTelemetryBundleToken.self)
    }

    private func runStructuredErrorProbe(
        code: String,
        probePath: String,
        root: URL
    ) throws -> ProcessRunResult {
        try runMockSocketProcess(
            arguments: ["capabilities"],
            probePath: probePath,
            root: root
        ) { line in
            guard let requestData = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                  let id = request["id"] as? String else {
                return nil
            }
            let response: [String: Any] = [
                "id": id,
                "ok": false,
                "error": [
                    "code": code,
                    "message": "TabManager not available"
                ]
            ]
            return try? String(
                data: JSONSerialization.data(withJSONObject: response),
                encoding: .utf8
            )
        }
    }

    private func runPiSurfaceUnavailableProbe(
        surfaceID: String,
        probePath: String,
        root: URL
    ) throws -> ProcessRunResult {
        let inputData = try JSONSerialization.data(withJSONObject: [
            "session_id": "pi-sentry-\(UUID().uuidString)",
            "hook_event_name": "PostToolUse",
            "cwd": root.path,
        ])
        var environmentOverrides = [
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "0",
        ]
        environmentOverrides["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = probePath

        return try runMockSocketProcess(
            arguments: [
                "hooks", "pi", "post-tool-use",
                "--surface", surfaceID,
            ],
            probePath: probePath,
            root: root,
            stdinText: String(decoding: inputData, as: UTF8.self),
            environmentOverrides: environmentOverrides
        ) { line in
            guard let request = try? JSONSerialization.jsonObject(
                with: Data(line.utf8),
                options: []
            ) as? [String: Any],
                  let id = request["id"] as? String else {
                return nil
            }
            let response: [String: Any] = [
                "id": id,
                "ok": false,
                "error": [
                    "code": "not_found",
                    "message": "No live delivery target",
                ],
            ]
            return try? String(
                data: JSONSerialization.data(withJSONObject: response),
                encoding: .utf8
            )
        }
    }

    private func runAgentHookErrorProbe(
        message: String,
        probePath: String,
        root: URL,
        sessionID: String? = nil
    ) throws -> ProcessRunResult {
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let resolvedSessionID = sessionID ?? "sentry-hook-\(UUID().uuidString)"
        let inputData = try JSONSerialization.data(withJSONObject: [
            "session_id": resolvedSessionID,
            "hook_event_name": "Stop",
            "cwd": root.path,
            "last_assistant_message": "done"
        ])
        let input = String(decoding: inputData, as: UTF8.self)

        var environmentOverrides = [
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "0",
        ]
        environmentOverrides["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = probePath

        return try runMockSocketProcess(
            arguments: [
                "hooks", "codex", "stop",
                "--workspace", workspaceID,
                "--surface", surfaceID,
            ],
            probePath: probePath,
            root: root,
            stdinText: input,
            environmentOverrides: environmentOverrides
        ) { line in
            if line.hasPrefix("notify_target_async ") {
                return "ERROR: \(message)"
            }
            guard let request = try? JSONSerialization.jsonObject(
                with: Data(line.utf8),
                options: []
            ) as? [String: Any],
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return "OK"
            }
            switch method {
            case "surface.list":
                return try? String(
                    data: JSONSerialization.data(withJSONObject: [
                        "id": id,
                        "ok": true,
                        "result": [
                            "surfaces": [[
                                "id": surfaceID,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true,
                            ]]
                        ]
                    ]),
                    encoding: .utf8
                )
            default:
                return try? String(
                    data: JSONSerialization.data(withJSONObject: [
                        "id": id,
                        "ok": true,
                        "result": [:] as [String: Any],
                    ]),
                    encoding: .utf8
                )
            }
        }
    }

    private func runMockSocketProcess(
        arguments: [String],
        probePath: String,
        root: URL,
        stdinText: String? = nil,
        environmentOverrides: [String: String] = [:],
        respond: @escaping @Sendable (String) -> String?
    ) throws -> ProcessRunResult {
        let socketPath = "/tmp/cmux-structured-\(UUID().uuidString.prefix(8)).sock"
        let listenerFD = try bindUnixSocket(at: socketPath)
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD, respond: respond)
            },
            onListenerClosed: {}
        )
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = probePath
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "1"
        environment["HOME"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        environment.merge(environmentOverrides, uniquingKeysWith: { _, new in new })
        return runProcess(
            executablePath: try bundledCLIPath(),
            arguments: arguments,
            environment: environment,
            timeout: 5,
            stdinText: stdinText
        )
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            let errorCode = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        return fd
    }

    private func sentryProbeEnvironment(socketPath: String, probePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = probePath
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"
        let home = URL(fileURLWithPath: probePath).deletingLastPathComponent().path
        environment["HOME"] = home
        environment["CFFIXED_USER_HOME"] = home
        return environment
    }

    private func unusedRelayPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket failed")
        }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw posixError("bind failed")
        }
        guard listen(fd, 1) == 0 else {
            throw posixError("listen failed")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                getsockname(fd, socketPointer, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw posixError("getsockname failed")
        }

        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func createStaleSocketFile(at path: String) throws {
        close(try boundUnixSocketDescriptor(at: path))
    }

    private func muteListeningSocketDescriptor(at path: String) throws -> Int32 {
        let fd = try boundUnixSocketDescriptor(at: path)
        guard listen(fd, 8) == 0 else {
            let error = posixError("listen failed")
            close(fd)
            throw error
        }
        return fd
    }

    private func boundUnixSocketDescriptor(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket failed")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = posixError("bind failed")
            close(fd)
            throw error
        }
        return fd
    }

    private func posixError(_ message: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"]
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        stdinText: String? = nil
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stdinPipe = stdinText.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        if let stdinText, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(stdinText.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
