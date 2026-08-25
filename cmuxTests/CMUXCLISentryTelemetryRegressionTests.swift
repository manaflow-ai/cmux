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
        // A complete protocol reply is intentionally outside the transport
        // capture gate; Sentry policy precedence is covered by the package
        // tests, while this process test verifies the structured code survives
        // CLI formatting.
        #expect(actionableResult.stdout.lowercased().contains("internal_error"), Comment(rawValue: actionableResult.stdout))
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: CMUXCLISentryTelemetryBundleToken.self)
    }

    private func runStructuredErrorProbe(
        code: String,
        probePath: String,
        root: URL
    ) throws -> ProcessRunResult {
        let socketPath = root.appendingPathComponent("\(code).sock").path
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
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
            },
            onListenerClosed: {}
        )

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = probePath
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "1"
        environment["HOME"] = root.path
        return runProcess(
            executablePath: try bundledCLIPath(),
            arguments: ["capabilities"],
            environment: environment,
            timeout: 5
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
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
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
