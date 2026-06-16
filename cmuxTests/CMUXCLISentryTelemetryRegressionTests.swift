import Darwin
import Foundation
import XCTest

final class CMUXCLISentryTelemetryRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    func testStaleSocketConnectRefusalDoesNotCaptureSentryTelemetry() throws {
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

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.lowercased().contains("connection refused"), result.stdout)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: probePath),
            (try? String(contentsOfFile: probePath, encoding: .utf8)) ?? result.stdout
        )
    }

    func testMissingSocketDoesNotCaptureSentryTelemetry() throws {
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

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.lowercased().contains("socket not found"), result.stdout)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: probePath),
            (try? String(contentsOfFile: probePath, encoding: .utf8)) ?? result.stdout
        )
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func sentryProbeEnvironment(socketPath: String, probePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = probePath
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"
        return environment
    }

    private func createStaleSocketFile(at path: String) throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "socket failed: \(String(cString: strerror(errno)))"]
            )
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
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "bind failed: \(String(cString: strerror(errno)))"]
            )
        }
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

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
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
