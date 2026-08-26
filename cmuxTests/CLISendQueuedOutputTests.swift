import Darwin
import Foundation
import Testing

// Regression coverage for issue #9769: `cmux send` to a surface whose PTY has
// not spawned yet is queued server-side, and the reply carries
// `queued: true`. The CLI's human-readable output dropped that flag and
// printed a bare `OK surface:N workspace:M`, indistinguishable from a
// delivered send — so queued-then-starved input looked like success.
@Suite(.serialized)
struct CLISendQueuedOutputTests {
    @Test func sendPrintsQueuedMarkerWhenDeliveryIsQueued() throws {
        let result = try runSendAgainstMockServer(queuedReply: true)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(result.stdout.contains("OK"), Comment(rawValue: result.stdout))
        #expect(result.stdout.contains(Self.surfaceRef), Comment(rawValue: result.stdout))
        #expect(
            result.stdout.contains("queued"),
            Comment(rawValue: "A queued send must say so instead of printing plain OK (#9769). stdout: \(result.stdout)")
        )
    }

    @Test func sendPrintsPlainOKWhenDeliveredToLiveSurface() throws {
        let result = try runSendAgainstMockServer(queuedReply: false)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(result.stdout == "OK \(Self.surfaceRef) \(Self.workspaceRef)\n", Comment(rawValue: result.stdout))
    }

    private static let surfaceRef = "surface:11"
    private static let workspaceRef = "workspace:7"

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class CLISendQueuedOutputBundleToken {}

    private func runSendAgainstMockServer(queuedReply: Bool) throws -> ProcessRunResult {
        let socketPath = Self.makeSocketPath("send-q")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { handled.signal() }
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                guard let payload = Self.jsonObject(line),
                      let id = payload["id"] as? String,
                      let method = payload["method"] as? String,
                      method == "surface.send_text" else {
                    return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected_method"])
                }
                var result: [String: Any] = [
                    "surface_ref": Self.surfaceRef,
                    "workspace_ref": Self.workspaceRef,
                ]
                if queuedReply { result["queued"] = true }
                return Self.v2Response(id: id, ok: true, result: result)
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        // Pin the child CLI to English so the queued-marker assertion is
        // locale-independent.
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"

        // Generous bounds: the tolerant full-suite pass runs this alongside
        // dozens of parallel suites on a loaded app host, where CLI process
        // startup alone can exceed a few seconds.
        let result = Self.runProcess(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLISendQueuedOutputBundleToken.self),
            arguments: ["send", "--surface", Self.surfaceRef, "echo issue9769"],
            environment: environment,
            timeout: 30
        )
        guard handled.wait(timeout: .now() + 30) == .success else {
            throw NSError(
                domain: "cmux.tests",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "Mock CLI socket server did not complete"]
            )
        }
        return ProcessRunResult(
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut
        )
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG), userInfo: [
                NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)",
            ])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
