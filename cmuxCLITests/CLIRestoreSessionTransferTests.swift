import Darwin
import Foundation
import Testing

/// `cmux restore-session --from` / `--export` against a mock v2 socket: the
/// CLI must send the right transfer request, never launch the app, and
/// surface the app's validation errors.
@Suite(.serialized)
final class CLIRestoreSessionTransferTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLines: [String] = []

        func append(_ line: String) {
            lock.lock()
            storedLines.append(line)
            lock.unlock()
        }

        var payloads: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return storedLines.compactMap { CLIRestoreSessionTransferTests.v2Payload(from: $0) }
        }
    }

    @Test func fromChannelSendsSessionImportWithSource() throws {
        let (result, payloads) = try runAgainstMockServer(
            label: "from-ch",
            arguments: ["restore-session", "--from", "nightly"],
            reply: ["restored": true, "source_path": "/support/session-com.cmuxterm.app.nightly.json", "window_count": 2]
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK /support/session-com.cmuxterm.app.nightly.json\n")
        #expect(payloads.map { $0["method"] as? String } == ["session.import"])
        let params = payloads.first?["params"] as? [String: Any]
        #expect(params?["source"] as? String == "nightly")
        #expect(params?["path"] == nil)
    }

    @Test func fromRelativePathSendsAbsolutePath() throws {
        let (result, payloads) = try runAgainstMockServer(
            label: "from-path",
            arguments: ["restore-session", "--from=exports/moved-session.json"],
            reply: [
                "restored": true,
                "source_path": "/x/exports/moved-session.json",
                "window_count": 1,
                "trusted": false,
                "held_back_resume_count": 2,
                "dropped_remote_workspace_count": 0,
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first == "OK /x/exports/moved-session.json")
        #expect(lines.count == 2, Comment(rawValue: result.stdout))
        #expect(lines.last?.contains("Held back automatic resume in 2 terminals") == true, Comment(rawValue: result.stdout))
        #expect(lines.last?.contains("cmux restore --surface") == true, Comment(rawValue: result.stdout))
        let params = payloads.first?["params"] as? [String: Any]
        let path = try #require(params?["path"] as? String)
        #expect(path.hasPrefix("/"))
        #expect(path.hasSuffix("/exports/moved-session.json"))
        #expect(params?["source"] == nil)
    }

    @Test func exportSendsSessionExportWithForce() throws {
        let (result, payloads) = try runAgainstMockServer(
            label: "export",
            arguments: ["restore-session", "--export", "/tmp/cmux-session-export.json", "--force"],
            reply: ["exported": true, "path": "/tmp/cmux-session-export.json", "source_path": "/support/session.json"]
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "OK /tmp/cmux-session-export.json\n")
        #expect(payloads.map { $0["method"] as? String } == ["session.export"])
        let params = payloads.first?["params"] as? [String: Any]
        #expect(params?["path"] as? String == "/tmp/cmux-session-export.json")
        #expect(params?["force"] as? Bool == true)
    }

    @Test func importValidationErrorIsReported() throws {
        let (result, _) = try runAgainstMockServer(
            label: "from-err",
            arguments: ["restore-session", "--from", "/tmp/newer.json"],
            error: ["code": "unsupported", "message": "/tmp/newer.json was saved by a newer cmux"]
        )

        #expect(result.status != 0)
        #expect(result.stderr.contains("was saved by a newer cmux"), Comment(rawValue: result.stderr))
    }

    @Test(arguments: [
        (["restore-session", "--from", "nightly", "--export", "/tmp/x.json"], "not both"),
        (["restore-session", "--force"], "--force only applies to --export"),
        (["restore-session", "--from"], "--from requires a value"),
    ])
    func conflictingFlagsFailBeforeConnecting(arguments: [String], expected: String) throws {
        let result = runCLI(socketPath: makeSocketPath("noconn"), arguments: arguments)

        #expect(result.status != 0)
        #expect(result.stderr.contains(expected), Comment(rawValue: result.stderr))
    }

    @Test func transferDoesNotLaunchCmuxWhenItIsNotRunning() throws {
        let result = runCLI(
            socketPath: makeSocketPath("absent"),
            arguments: ["restore-session", "--from", "stable"]
        )

        #expect(result.status != 0)
        #expect(result.stderr.contains("cmux is not running"), Comment(rawValue: result.stderr))
    }

    // MARK: - Harness

    private func runAgainstMockServer(
        label: String,
        arguments: [String],
        reply: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) throws -> (ProcessRunResult, [[String: Any]]) {
        let socketPath = makeSocketPath(label)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restore-session-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: workDirectory)
        }
        let state = MockSocketServerState()
        let replyData = try JSONSerialization.data(withJSONObject: reply ?? [:])
        let errorData = try JSONSerialization.data(withJSONObject: error ?? [:])
        let isError = error != nil
        let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
            let id = Self.v2Payload(from: line)?["id"] as? String ?? "unknown"
            let result = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any]
            let error = (try? JSONSerialization.jsonObject(with: errorData)) as? [String: Any]
            return isError
                ? Self.v2Response(id: id, ok: false, error: error)
                : Self.v2Response(id: id, ok: true, result: result)
        }

        let result = runCLI(socketPath: socketPath, arguments: arguments, currentDirectory: workDirectory)

        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return (result, state.payloads)
    }

    private func runCLI(
        socketPath: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        // Belt and braces: if the CLI ever tried to launch cmux here, it
        // would run this no-op instead of opening an app.
        environment["CMUX_TEST_OPEN_TOOL_PATH"] = "/usr/bin/false"
        let cliPath: String
        do {
            cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
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

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }
        return fd
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-rs-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> DispatchSemaphore {
        let handled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.signal()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.signal()
            }
            guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }

            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                pending.append(buffer, count: count)
                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.append(line)
                    guard writeAllToFixtureSocket(handler(line) + "\n", fd: clientFD) else { return }
                }
            }
        }
        return handled
    }

    fileprivate static func v2Payload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
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
}
