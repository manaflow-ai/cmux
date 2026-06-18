import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLIRemoteShellStartupPerformanceTests {
    private struct ProcessRunResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
        let duration: TimeInterval
    }

    private struct RunningProcess {
        let process: Process
        let stderrPipe: Pipe
        let start: Date
    }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let value = storage
            lock.unlock()
            return value
        }
    }

    @Test
    func generatedSSHStartupDoesNotBlockOnRelayRPCWarmup() throws {
        let startupCommand = try generatedSSHStartupCommandForShellPerformance()
        let root = try makeFakeRemoteShellRoot()
        defer { try? FileManager.default.removeItem(at: root.url) }
        let shellMarker = root.url.appendingPathComponent("remote-shell-started")
        let relayRPCGate = root.url.appendingPathComponent("relay-rpc-gate")

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.home.path
        environment["PATH"] = "\(root.bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["SHELL"] = root.bin.appendingPathComponent("sh").path
        environment["TERM"] = "xterm-256color"
        environment["CMUX_BUNDLED_CLI_PATH"] = root.bin.appendingPathComponent("cmux").path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-test.sock"
        environment["CMUX_WORKSPACE_ID"] = "workspace-cli-perf"
        environment["CMUX_SURFACE_ID"] = "surface-cli-perf"
        environment["CMUX_FAKE_SHELL_MARKER"] = shellMarker.path
        environment["CMUX_FAKE_RELAY_RPC_GATE"] = relayRPCGate.path

        let running = try launchProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", startupCommand],
            environment: environment
        )
        defer {
            if running.process.isRunning {
                running.process.terminate()
                _ = waitForProcess(running, timeout: 1)
            }
        }

        let shellStartedBeforeRelayRPCCompleted = waitForFile(shellMarker, timeout: 3)
        try Data().write(to: relayRPCGate)
        let result = waitForProcess(running, timeout: 5)

        #expect(
            shellStartedBeforeRelayRPCCompleted,
            "CLI SSH startup waited for relay RPC warmup before starting the remote shell"
        )
        #expect(!result.timedOut)
        #expect(result.status == 0)
    }

    private struct FakeRemoteShellRoot {
        let url: URL
        let home: URL
        let bin: URL
    }

    private func generatedSSHStartupCommandForShellPerformance() throws -> String {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-perf")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverDone = startMockServer(listenerFD: listenerFD, state: state)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh", "--no-focus",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/cmux-ssh-%C",
                "cmux-test-host",
            ],
            environment: environment,
            timeout: 5
        )
        _ = serverDone.wait(timeout: .now() + 5)

        #expect(!result.timedOut)
        #expect(result.status == 0)
        let requests = try state.snapshot().map(jsonObject)
        let configure = try #require(requests.first { ($0["method"] as? String) == "workspace.remote.configure" })
        let params = try #require(configure["params"] as? [String: Any])
        return try #require(params["terminal_startup_command"] as? String)
    }

    private func startMockServer(listenerFD: Int32, state: MockSocketServerState) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenerFD, $0, &clientAddrLen) }
            }
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }

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
                while let newline = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newline.lowerBound)
                    pending.removeSubrange(0...newline.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    state.append(line)
                    let response = Self.responsePayload(for: line) + "\n"
                    _ = response.withCString { Darwin.write(clientFD, $0, strlen($0)) }
                }
            }
        }
        return done
    }

    private static func responsePayload(for line: String) -> String {
        guard let payload = try? jsonObject(line),
              let id = payload["id"] as? String,
              let method = payload["method"] as? String else {
            return v2Response(id: "unknown", ok: false, error: ["code": "malformed_request"])
        }
        switch method {
        case "workspace.create":
            return v2Response(id: id, ok: true, result: ["workspace_id": "workspace-cli-perf"])
        case "workspace.remote.configure":
            return v2Response(
                id: id,
                ok: true,
                result: [
                    "workspace_id": "workspace-cli-perf",
                    "workspace_ref": "workspace:cli-perf",
                    "remote": ["enabled": true, "state": "connecting"],
                ]
            )
        default:
            return v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
        }
    }

    private func makeFakeRemoteShellRoot() throws -> FakeRemoteShellRoot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-cli-shell-perf-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(at: bin.appendingPathComponent("cmux"), contents: """
        #!/bin/sh
        if [ "$1" = "rpc" ] && [ -n "${CMUX_FAKE_RELAY_RPC_GATE:-}" ]; then
          while [ ! -f "$CMUX_FAKE_RELAY_RPC_GATE" ]; do sleep 0.05; done
        fi
        exit 0
        """)
        try writeExecutable(at: bin.appendingPathComponent("tty"), contents: "#!/bin/sh\nprintf '%s\\n' /dev/ttys997")
        try writeExecutable(at: bin.appendingPathComponent("sh"), contents: """
        #!/bin/sh
        if [ -n "${CMUX_FAKE_SHELL_MARKER:-}" ]; then printf started > "$CMUX_FAKE_SHELL_MARKER"; fi
        exit 0
        """)
        try writeExecutable(at: bin.appendingPathComponent("ssh"), contents: fakeSSHScript)
        return FakeRemoteShellRoot(url: root, home: home, bin: bin)
    }

    private var fakeSSHScript: String {
        """
        #!/bin/sh
        remote_command=
        last=
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ] && [ "$#" -gt 1 ]; then
            shift
            case "$1" in RemoteCommand=*) remote_command="${1#RemoteCommand=}" ;; esac
          elif [ "${1#RemoteCommand=}" != "$1" ]; then
            remote_command="${1#RemoteCommand=}"
          fi
          last="$1"
          shift
        done
        [ -n "$remote_command" ] && exec /bin/sh -c "$remote_command"
        case "$last" in /bin/sh\\ -c*) exec /bin/sh -c "$last" ;; esac
        exit 0
        """
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func bundledCLIPath() throws -> String {
        let appBundle = Bundle.main.bundleURL
        let direct = appBundle.appendingPathComponent("Contents/Resources/bin/cmux")
        if FileManager.default.isExecutableFile(atPath: direct.path) { return direct.path }
        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Bundled cmux CLI not found in \(appBundle.path)",
        ])
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cli-\(name)-\(shortID).sock").path
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count { buffer[index] = CChar(bitPattern: utf8[index]) }
                buffer[utf8.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func v2Response(id: String, ok: Bool, result: [String: Any]? = nil, error: [String: Any]? = nil) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func jsonObject(_ line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        return try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
    }

    private func jsonObject(_ line: String) throws -> [String: Any] {
        try Self.jsonObject(line)
    }

    private func launchProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> RunningProcess {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        let start = Date()
        try process.run()
        return RunningProcess(process: process, stderrPipe: stderrPipe, start: start)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func waitForProcess(_ running: RunningProcess, timeout: TimeInterval) -> ProcessRunResult {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            running.process.waitUntilExit()
            done.signal()
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            running.process.terminate()
            _ = done.wait(timeout: .now() + 1)
        }
        let stderr = String(data: running.stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: running.process.isRunning ? SIGKILL : running.process.terminationStatus,
            stderr: stderr,
            timedOut: timedOut,
            duration: Date().timeIntervalSince(running.start)
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        do {
            let running = try launchProcess(executablePath: executablePath, arguments: arguments, environment: environment)
            return waitForProcess(running, timeout: timeout)
        } catch {
            return ProcessRunResult(status: -1, stderr: String(describing: error), timedOut: false, duration: 0)
        }
    }
}
