import XCTest

final class WorkspaceSSHFishShellTests: XCTestCase {
    private struct ProcessRunResult { let status: Int32; let stderr: String; let timedOut: Bool }

    private final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock(); private(set) var commands: [String] = []

        func append(_ command: String) { lock.lock(); commands.append(command); lock.unlock() }
    }

    @MainActor
    func testMultiplexedSSHForegroundAuthDoesNotDependOnLocalCommand() throws {
        let cliPath = try bundledCLIPath()
        let python3Path = try requireExecutable(["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"], name: "python3")
        let fishExecutable = try requireExecutable(["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish"], name: "fish")
        let socketPath = makeSocketPath("sshboot")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:8"
        let windowID = "22222222-2222-2222-2222-222222222222"
        let surfaceID = "33333333-3333-3333-3333-333333333333"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            switch method {
            case "workspace.create":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "window_id": windowID,
                        "surface_id": surfaceID,
                    ]
                )
            case "workspace.rename":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                let params = payload["params"] as? [String: Any] ?? [:]
                let autoConnect = (params["auto_connect"] as? Bool) ?? true
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": autoConnect ? "connecting" : "disconnected",
                        ],
                    ]
                )
            case "workspace.select":
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
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
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--name", "SSH Workspace",
                "--port", "2222",
                "--identity", "/Users/test/.ssh/id_ed25519",
                "--ssh-option", "ControlMaster=auto",
                "--ssh-option", "ControlPersist=600",
                "--ssh-option", "ControlPath=/tmp/cmux-ssh-%C",
                "--ssh-option", "StrictHostKeyChecking=accept-new",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        let createParams = try XCTUnwrap(requests.first { $0["method"] as? String == "workspace.create" }?["params"] as? [String: Any])
        let initialCommand = try XCTUnwrap(createParams["initial_command"] as? String)
        let configureParams = try XCTUnwrap(requests.first { $0["method"] as? String == "workspace.remote.configure" }?["params"] as? [String: Any])
        let foregroundAuthToken = try XCTUnwrap(configureParams["foreground_auth_token"] as? String)

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("cmux-ssh-bootstrap-\(UUID().uuidString)")
        let fakeBin = tempRoot.appendingPathComponent("bin")
        let fakeSSHLog = tempRoot.appendingPathComponent("fake-ssh.jsonl")
        let fakeSSHMasterMarker = tempRoot.appendingPathComponent("fake-ssh-master")
        let fakeSSH = fakeBin.appendingPathComponent("ssh")

        try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fakeSSHScript = """
        #!/bin/sh
        "$CMUX_TEST_PYTHON3" - "$@" <<'PY'
        import json
        import os
        import subprocess
        import sys

        args = sys.argv[1:]
        with open(os.environ["CMUX_FAKE_SSH_LOG"], "a", encoding="utf-8") as handle:
            handle.write(json.dumps(args) + "\\n")

        local_command = None
        for index, arg in enumerate(args):
            if arg == "-o" and index + 1 < len(args) and args[index + 1].startswith("LocalCommand="):
                local_command = args[index + 1].split("=", 1)[1]
                break

        master_marker = os.environ["CMUX_FAKE_SSH_MASTER_MARKER"]
        if local_command and not os.path.exists(master_marker):
            open(master_marker, "a", encoding="utf-8").close()
            local_command = local_command.replace("%%", "%")
            subprocess.run([os.environ["CMUX_TEST_LOCAL_SHELL"], "-c", local_command], check=False, env=os.environ.copy())
        PY
        cat >/dev/null
        exit 0
        """
        try fakeSSHScript.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

        var startupEnvironment = ProcessInfo.processInfo.environment
        startupEnvironment["HOME"] = tempRoot.path
        startupEnvironment["PATH"] = "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        startupEnvironment["CMUX_FAKE_SSH_LOG"] = fakeSSHLog.path
        startupEnvironment["CMUX_FAKE_SSH_MASTER_MARKER"] = fakeSSHMasterMarker.path
        startupEnvironment["CMUX_TEST_PYTHON3"] = python3Path
        startupEnvironment["CMUX_TEST_LOCAL_SHELL"] = fishExecutable
        startupEnvironment["CMUX_SOCKET_PATH"] = socketPath
        startupEnvironment["CMUX_WORKSPACE_ID"] = workspaceID
        startupEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        startupEnvironment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let foregroundAuthState = MockSocketServerState()
        let foregroundAuthHandled = startMockServer(
            listenerFD: listenerFD,
            state: foregroundAuthState,
            connectionCount: 2
        ) { line in
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "workspace.remote.foreground_auth_ready" else {
                return self.v2Response(
                    id: "unknown",
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected payload"]
                )
            }

            return self.v2Response(
                id: id,
                ok: true,
                result: [
                    "workspace_id": workspaceID,
                    "workspace_ref": workspaceRef,
                    "remote": [
                        "enabled": true,
                        "state": "connecting",
                    ],
                ]
            )
        }

        let startupResults = (0..<2).map { _ in
            runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", initialCommand],
                environment: startupEnvironment,
                timeout: 5
            )
        }

        wait(for: [foregroundAuthHandled], timeout: 5)
        for startupResult in startupResults {
            XCTAssertFalse(startupResult.timedOut, startupResult.stderr)
            XCTAssertEqual(startupResult.status, 0, startupResult.stderr)
        }

        let logLines = try String(contentsOf: fakeSSHLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let invocations = try logLines.map { line in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String])
        }
        let foregroundAuthInvocations = invocations.filter { $0.last == "true" }
        XCTAssertEqual(foregroundAuthInvocations.count, 2)
        XCTAssertFalse(
            invocations.contains(where: { invocation in
                invocation.contains(where: { $0.hasPrefix("LocalCommand=") })
            }),
            "Foreground auth must not depend on LocalCommand because OpenSSH suppresses it for multiplex followers: \(invocations)"
        )

        XCTAssertEqual(
            foregroundAuthState.commands.count,
            2,
            "Every workspace startup must report foreground auth even when a shared ControlMaster suppresses follower LocalCommand callbacks."
        )
        for command in foregroundAuthState.commands {
            let foregroundAuthPayloadData = try XCTUnwrap(command.data(using: .utf8))
            let foregroundAuthPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: foregroundAuthPayloadData, options: []) as? [String: Any]
            )
            XCTAssertEqual(foregroundAuthPayload["method"] as? String, "workspace.remote.foreground_auth_ready")
            let foregroundAuthParams = try XCTUnwrap(foregroundAuthPayload["params"] as? [String: Any])
            XCTAssertEqual(foregroundAuthParams["workspace_id"] as? String, workspaceID)
            XCTAssertEqual(foregroundAuthParams["foreground_auth_token"] as? String, foregroundAuthToken)
        }
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(6))-\(shortID).sock"
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    private func requireExecutable(_ candidates: [String], name: String) throws -> String {
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("\(name) is not installed") }
        return path
    }

    private func runProcess(
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
            return ProcessRunResult(
                status: -1,
                stderr: String(describing: error),
                timedOut: false
            )
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPathLength else { Darwin.close(fd); throw XCTSkip("Unix socket path too long for sockaddr_un: \(path)") }
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
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }

    private func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        handled.expectedFulfillmentCount = max(1, connectionCount)
        for _ in 0..<max(1, connectionCount) {
            DispatchQueue.global(qos: .userInitiated).async {
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                guard clientFD >= 0 else {
                    handled.fulfill()
                    return
                }
                defer {
                    Darwin.close(clientFD)
                    handled.fulfill()
                }

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
                        let response = handler(line) + "\n"
                        _ = response.withCString { ptr in
                            Darwin.write(clientFD, ptr, strlen(ptr))
                        }
                    }
                }
            }
        }
        return handled
    }

    private func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result {
            payload["result"] = result
        }
        if let error {
            payload["error"] = error
        }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}
