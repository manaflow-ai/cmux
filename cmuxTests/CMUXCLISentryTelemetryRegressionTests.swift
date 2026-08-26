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

    private func runAgentHookErrorProbe(
        message: String,
        probePath: String,
        root: URL
    ) throws -> ProcessRunResult {
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let sessionID = "sentry-hook-\(UUID().uuidString)"
        let inputData = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionID,
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
            arguments: ["hooks", "codex", "stop"],
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
        var stopPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stopPipe) == 0 else {
            Darwin.close(listenerFD)
            unlink(socketPath)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let stopReadFD = stopPipe[0]
        let stopWriteFD = stopPipe[1]
        let serverDone = DispatchSemaphore(value: 0)
        let serverThread = Thread {
            defer { serverDone.signal() }
            while true {
                var descriptors = [
                    pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: stopReadFD, events: Int16(POLLIN), revents: 0),
                ]
                let ready = Darwin.poll(&descriptors, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if descriptors[1].revents & Int16(POLLIN) != 0 {
                    return
                }
                guard descriptors[0].revents & Int16(POLLIN) != 0 else {
                    if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                        return
                    }
                    continue
                }
                var address = sockaddr_un()
                var addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                        Darwin.accept(listenerFD, socketPointer, &addressLength)
                    }
                }
                guard clientFD >= 0 else { continue }
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD, respond: respond)
            }
        }
        serverThread.start()
        defer {
            var stopByte: UInt8 = 1
            _ = Darwin.write(stopWriteFD, &stopByte, 1)
            if serverDone.wait(timeout: .now() + 5) == .timedOut {
                Darwin.close(listenerFD)
                _ = serverDone.wait(timeout: .now() + 1)
            }
            Darwin.close(stopReadFD)
            Darwin.close(stopWriteFD)
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
        environment["HOME"] = URL(fileURLWithPath: probePath).deletingLastPathComponent().path
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
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket failed")
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
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
            throw posixError("bind failed")
        }
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
