import Darwin
import Foundation
import Testing

private final class CLIVaultForkSelectorBundleToken {}

@Suite(.serialized)
struct CLIVaultForkSelectorTests {
    private final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func methods() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines.compactMap { line in
                guard let data = line.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return payload["method"] as? String
            }
        }

        func params(forMethod method: String) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      payload["method"] as? String == method else {
                    continue
                }
                return payload["params"] as? [String: Any]
            }
            return nil
        }
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test func forkRejectsCheckpointAndTurnTogether() throws {
        let (result, state) = try runVaultFork(selectorArguments: ["--checkpoint", "cp-1", "--turn", "2"])

        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(result.stderr.contains("not both"), "stderr: \(result.stderr)")
        #expect(!state.methods().contains("vault.fork"))
    }

    @Test func forkStillSendsASingleCheckpointSelector() throws {
        let (result, state) = try runVaultFork(selectorArguments: ["--checkpoint", "cp-1"])

        #expect(!result.timedOut)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        let params = try #require(state.params(forMethod: "vault.fork"))
        #expect(params["checkpoint"] as? String == "cp-1")
        #expect(params["turn"] == nil)
    }

    @Test func forkStillSendsASingleTurnSelector() throws {
        let (result, state) = try runVaultFork(selectorArguments: ["--turn", "2"])

        #expect(!result.timedOut)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        let params = try #require(state.params(forMethod: "vault.fork"))
        #expect(params["turn"] as? Int == 2)
        #expect(params["checkpoint"] == nil)
    }

    // MARK: Helpers

    private func runVaultFork(selectorArguments: [String]) throws -> (ProcessRunResult, ServerState) {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLIVaultForkSelectorBundleToken.self)
        let socketPath = Self.makeSocketPath("vfork")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        let state = ServerState()
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
                    state.record(line)
                    return Self.respond(to: line)
                }
            },
            onListenerClosed: {}
        )

        let result = Self.runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["vault", "fork", "--agent", "claude", "--session", "session-1"] + selectorArguments
        )
        return (result, state)
    }

    private static func respond(to line: String) -> String {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = payload["id"] else {
            return "OK"
        }
        var response: [String: Any] = ["id": id, "ok": true]
        if payload["method"] as? String == "vault.fork" {
            response["result"] = ["session_id": "forked-session"]
        } else {
            response["result"] = [String: Any]()
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
        return String(data: encoded, encoding: .utf8) ?? "{}"
    }

    private static func runCLI(cliPath: String, socketPath: String, arguments: [String]) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let timedOut = exitSignal.wait(timeout: .now() + 15) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
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
            throw POSIXError(.ENAMETOOLONG)
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
        guard bindResult == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }
}
