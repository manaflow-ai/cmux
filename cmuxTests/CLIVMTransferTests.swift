import CryptoKit
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// End-to-end coverage for `cmux vm push` / `cmux vm pull` / `cmux vm wait`:
/// the real CLI binary runs against a mock control socket that plays the app's
/// side of the `vm.exec` / `vm.status` protocol, so the tests exercise argument
/// parsing, chunked base64 framing, and digest verification exactly as an agent
/// would hit them.
extension CLINotifyProcessIntegrationRegressionTests {
    /// Thread-safe byte accumulator for chunks arriving on mock-server threads.
    final class VMTransferMockState: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var counter = 0

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        func bytes() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func nextCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            counter += 1
            return counter
        }
    }

    private func vmExecOKResponse(id: String, stdout: String) -> String {
        v2Response(id: id, ok: true, result: ["exit_code": 0, "stdout": stdout, "stderr": ""])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testVMPushFileStreamsChunksAndVerifiesDigest() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-push")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let received = VMTransferMockState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        // Three chunks at the CLI's 512 KiB chunk size.
        var payload = Data(count: 1_200_000)
        payload.withUnsafeMutableBytes { buffer in
            for index in buffer.indices {
                buffer[index] = UInt8((index &* 31) & 0xFF)
            }
        }
        let expectedDigest = Self.sha256Hex(payload)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-push-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let localFile = tempDir.appendingPathComponent("payload.bin")
        try payload.write(to: localFile)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "vm.exec",
                  let params = request["params"] as? [String: Any],
                  let command = params["command"] as? String else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            if command.hasPrefix(": > ") {
                return self.vmExecOKResponse(id: id, stdout: "")
            }
            if command.contains("| base64 -d >>") {
                guard let start = command.range(of: "printf %s '"),
                      let end = command.range(of: "' | base64 -d >>") else {
                    return self.v2Response(id: id, ok: false, error: ["code": "bad_chunk", "message": "Unparseable chunk command"])
                }
                let encoded = String(command[start.upperBound..<end.lowerBound])
                guard let decoded = Data(base64Encoded: encoded) else {
                    return self.v2Response(id: id, ok: false, error: ["code": "bad_base64", "message": "Chunk was not base64"])
                }
                received.append(decoded)
                return self.vmExecOKResponse(id: id, stdout: "")
            }
            if command.hasPrefix("mv ") {
                let digest = Self.sha256Hex(received.bytes())
                return self.vmExecOKResponse(id: id, stdout: "\(digest)  payload.bin\n")
            }
            return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected command \(command)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "push", "brave-otter", localFile.path, "payload.bin"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Pushed"), result.stdout)
        XCTAssertEqual(received.bytes(), payload, "reassembled remote bytes must match the pushed file")
        XCTAssertEqual(Self.sha256Hex(received.bytes()), expectedDigest)
    }

    func testVMPushFailsOnDigestMismatch() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-push-corrupt")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-push-corrupt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let localFile = tempDir.appendingPathComponent("payload.bin")
        try Data("hello agent".utf8).write(to: localFile)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard let params = request["params"] as? [String: Any],
                  let command = params["command"] as? String else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "missing command"])
            }
            if command.hasPrefix("mv ") {
                // A machine reporting the wrong digest must fail the push.
                let bogus = String(repeating: "0", count: 64)
                return self.vmExecOKResponse(id: id, stdout: "\(bogus)  payload.bin\n")
            }
            return self.vmExecOKResponse(id: id, stdout: "")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "push", "brave-otter", localFile.path, "payload.bin"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, "digest mismatch must exit non-zero; stdout=\(result.stdout)")
        XCTAssertTrue(result.stderr.contains("Digest mismatch"), result.stderr)
    }

    func testVMPullFileReassemblesChunksAndWritesLocalFile() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-pull")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        // Two chunks at the CLI's 512 KiB chunk size.
        var remoteData = Data(count: 700_000)
        remoteData.withUnsafeMutableBytes { buffer in
            for index in buffer.indices {
                buffer[index] = UInt8((index &* 17) & 0xFF)
            }
        }
        let remoteDigest = Self.sha256Hex(remoteData)
        let chunkBytes = 512 * 1024

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-pull-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let localFile = tempDir.appendingPathComponent("report.bin")

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard let params = request["params"] as? [String: Any],
                  let command = params["command"] as? String else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "missing command"])
            }
            if command.hasPrefix("p=") {
                return self.vmExecOKResponse(id: id, stdout: "CMUX_FILE\n")
            }
            if command.hasPrefix("wc -c < ") {
                return self.vmExecOKResponse(id: id, stdout: "\(remoteData.count)\n\(remoteDigest)  report.bin\n")
            }
            if command.hasPrefix("dd if=") {
                guard let skipRange = command.range(of: "skip=") else {
                    return self.v2Response(id: id, ok: false, error: ["code": "bad_dd", "message": command])
                }
                let tail = command[skipRange.upperBound...]
                let skip = Int(tail.prefix(while: { $0.isNumber })) ?? 0
                let start = min(skip * chunkBytes, remoteData.count)
                let end = min(start + chunkBytes, remoteData.count)
                let encoded = remoteData.subdata(in: start..<end).base64EncodedString()
                // Real `base64` wraps output; the CLI must tolerate embedded newlines.
                var wrapped = ""
                var index = encoded.startIndex
                while index < encoded.endIndex {
                    let next = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
                    wrapped += encoded[index..<next]
                    wrapped += "\n"
                    index = next
                }
                return self.vmExecOKResponse(id: id, stdout: wrapped)
            }
            return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected command \(command)"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "pull", "brave-otter", "work/report.bin", localFile.path],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Pulled"), result.stdout)
        let pulled = try Data(contentsOf: localFile)
        XCTAssertEqual(pulled, remoteData, "pulled bytes must match the machine's file")
    }

    private static func vmRunWorkKey(forDirectory path: String) -> String {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func testVMRunReusesIdlePoolMachine() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-run-reuse")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-run-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "vm.list":
                return self.v2Response(id: id, ok: true, result: [
                    "vms": [
                        ["id": "pool-1", "displayName": "agent-pool", "status": "running", "provider": "blaxel", "image": "blaxel/base-image:latest"],
                        ["id": "user-vm", "displayName": "my precious", "status": "running", "provider": "blaxel", "image": "blaxel/base-image:latest"],
                    ],
                ])
            case "vm.stats":
                return self.v2Response(id: id, ok: true, result: ["id": "pool-1", "state": "awake", "cpu_percent": 4.0])
            case "vm.exec":
                let params = request["params"] as? [String: Any]
                let vmID = (params?["id"] as? String) ?? "?"
                guard vmID == "pool-1" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "wrong_machine", "message": "routed to \(vmID)"])
                }
                return self.vmExecOKResponse(id: id, stdout: "routed\n")
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = isolatedHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "run", "--", "echo", "routed"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, "routed\n")
        XCTAssertTrue(result.stderr.contains("pool-1"), "router should say which machine it used: \(result.stderr)")
        XCTAssertFalse(
            state.snapshot().contains { $0.contains(#""method":"vm.create""#) },
            "an idle pool machine must be reused, not a new one created"
        )
    }

    func testVMRunProvisionsPoolMachineWhenPoolEmpty() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-run-create")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-run-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "vm.list":
                return self.v2Response(id: id, ok: true, result: ["vms": []])
            case "vm.create":
                return self.v2Response(id: id, ok: true, result: ["id": "fresh-1", "provider": "blaxel", "status": "creating", "image": "blaxel/base-image:latest"])
            case "vm.rename":
                return self.v2Response(id: id, ok: true, result: ["id": "fresh-1", "displayName": "agent-pool"])
            case "vm.status":
                return self.v2Response(id: id, ok: true, result: ["id": "fresh-1", "provider": "blaxel", "status": "running"])
            case "vm.exec":
                let params = request["params"] as? [String: Any]
                let vmID = (params?["id"] as? String) ?? "?"
                guard vmID == "fresh-1" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "wrong_machine", "message": "routed to \(vmID)"])
                }
                return self.vmExecOKResponse(id: id, stdout: "fresh\n")
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = isolatedHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "run", "--", "echo", "fresh"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, "fresh\n")
        let commands = state.snapshot()
        XCTAssertTrue(commands.contains { $0.contains(#""method":"vm.create""#) })
        XCTAssertTrue(
            commands.contains { $0.contains(#""method":"vm.rename""#) && $0.contains("agent-pool") },
            "a provisioned machine must be labeled into the pool"
        )
    }

    func testVMRunPrefersStickyBoundMachine() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-run-sticky")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-run-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: isolatedHome.appendingPathComponent(".cmuxterm"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        // Bind the current directory's work to pool-2 even though pool-1 is idle.
        let workKey = Self.vmRunWorkKey(forDirectory: FileManager.default.currentDirectoryPath)
        let bindings = [workKey: ["machine": "pool-2", "updatedAtUnix": Int(Date().timeIntervalSince1970)]]
        let bindingsData = try JSONSerialization.data(withJSONObject: bindings)
        try bindingsData.write(to: isolatedHome.appendingPathComponent(".cmuxterm/vm-run-bindings.json"))

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "vm.list":
                return self.v2Response(id: id, ok: true, result: [
                    "vms": [
                        ["id": "pool-1", "displayName": "agent-pool", "status": "running", "provider": "blaxel", "image": "blaxel/base-image:latest"],
                        ["id": "pool-2", "displayName": "agent-pool", "status": "standby", "provider": "blaxel", "image": "blaxel/base-image:latest"],
                    ],
                ])
            case "vm.exec":
                let params = request["params"] as? [String: Any]
                let vmID = (params?["id"] as? String) ?? "?"
                guard vmID == "pool-2" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "wrong_machine", "message": "sticky binding ignored; routed to \(vmID)"])
                }
                return self.vmExecOKResponse(id: id, stdout: "warm\n")
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = isolatedHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "run", "--", "echo", "warm"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, "warm\n")
        XCTAssertFalse(
            state.snapshot().contains { $0.contains(#""method":"vm.stats""#) },
            "a sticky binding should route without load-scoring the pool"
        )
    }

    func testVMWaitPollsStatusUntilReady() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-wait")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let pollCounter = VMTransferMockState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            guard method == "vm.status" else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            let call = pollCounter.nextCount()
            let status = call < 2 ? "creating" : "running"
            return self.v2Response(id: id, ok: true, result: [
                "id": "brave-otter",
                "provider": "blaxel",
                "status": status,
            ])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "wait", "brave-otter", "--timeout", "30"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("ready"), result.stdout)
        XCTAssertTrue(
            state.snapshot().filter { $0.contains(#""method":"vm.status""#) }.count >= 2,
            "wait must poll status more than once before ready"
        )
    }
}
