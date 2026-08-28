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
