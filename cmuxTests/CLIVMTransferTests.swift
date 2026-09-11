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

        // ~19 chunks at the CLI's 64 KiB push chunk size (argv-bound; see
        // vmTransferPushChunkBytes).
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

    private static func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
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
        try FileManager.default.createDirectory(
            at: isolatedHome.appendingPathComponent(".cmuxterm"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: isolatedHome) }
        // Only pool-1 was provisioned by the router. "impostor" carries the same
        // display label but is a user machine — it must never be drafted.
        try Self.writeJSON(["machines": ["pool-1"]], to: isolatedHome.appendingPathComponent(".cmuxterm/vm-run-pool.json"))

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
                        ["id": "impostor", "displayName": "agent-pool", "status": "running", "provider": "freestyle", "image": "cmuxd-ws:tooling-20260509f"],
                        ["id": "pool-1", "displayName": "agent-pool", "status": "running", "provider": "freestyle", "image": "cmuxd-ws:tooling-20260509f"],
                        ["id": "user-vm", "displayName": "my precious", "status": "running", "provider": "freestyle", "image": "cmuxd-ws:tooling-20260509f"],
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
        XCTAssertFalse(
            state.snapshot().contains { $0.contains(#""method":"vm.stats""#) && $0.contains("impostor") },
            "a user machine merely labeled agent-pool must not even be load-scored"
        )
    }

    /// Pruning a pool id whose machine is gone must not also drop an id that a
    /// concurrent `vm run` recorded after this process took its `vm.list`
    /// snapshot. The mock plays the other process: while answering `vm.list` it
    /// records `pool-2` in the store, and the list it returns predates that machine.
    func testVMRunPrunePreservesMachineRecordedAfterListSnapshot() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-run-prune-race")
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
        let poolStore = isolatedHome.appendingPathComponent(".cmuxterm/vm-run-pool.json")
        // pool-1 is alive; gone-1 was deleted by the user and must be pruned.
        try Self.writeJSON(["machines": ["gone-1", "pool-1"]], to: poolStore)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            switch method {
            case "vm.list":
                // The concurrent router finished provisioning pool-2 and recorded it
                // while this list was in flight; the list itself does not carry it yet.
                try? Self.writeJSON(["machines": ["gone-1", "pool-1", "pool-2"]], to: poolStore)
                return self.v2Response(id: id, ok: true, result: [
                    "vms": [
                        ["id": "pool-1", "displayName": "agent-pool", "status": "running", "provider": "blaxel", "image": "blaxel/base-image:latest"],
                        ["id": "user-vm", "displayName": "my precious", "status": "running", "provider": "blaxel", "image": "blaxel/base-image:latest"],
                    ],
                ])
            case "vm.stats":
                return self.v2Response(id: id, ok: true, result: ["id": "pool-1", "state": "awake", "cpu_percent": 4.0])
            case "vm.exec":
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
        XCTAssertFalse(
            state.snapshot().contains { $0.contains(#""method":"vm.create""#) },
            "pool-1 is idle; nothing should be provisioned"
        )
        let poolData = try Data(contentsOf: poolStore)
        let pool = try JSONSerialization.jsonObject(with: poolData) as? [String: Any]
        let machines = Set((pool?["machines"] as? [String]) ?? [])
        XCTAssertEqual(
            machines,
            ["pool-1", "pool-2"],
            "prune must drop only the id the snapshot saw as gone and keep the concurrently recorded one: \(machines)"
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
                let params = request["params"] as? [String: Any] ?? [:]
                XCTAssertNil(params["persistent_home"], "Freestyle does not support persistent home volumes")
                XCTAssertNil(params["per_machine_home"], "Freestyle does not support per-machine home volumes")
                return self.v2Response(id: id, ok: true, result: ["id": "fresh-1", "provider": "freestyle", "status": "creating", "image": "cmuxd-ws:tooling-20260509f"])
            case "vm.rename":
                return self.v2Response(id: id, ok: true, result: ["id": "fresh-1", "displayName": "agent-pool"])
            case "vm.status":
                return self.v2Response(id: id, ok: true, result: ["id": "fresh-1", "provider": "freestyle", "status": "running"])
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
        let poolData = try Data(contentsOf: isolatedHome.appendingPathComponent(".cmuxterm/vm-run-pool.json"))
        let pool = try JSONSerialization.jsonObject(with: poolData) as? [String: Any]
        XCTAssertEqual(pool?["machines"] as? [String], ["fresh-1"], "membership must be persisted, not inferred from the label")
    }

    /// Two routers provisioning at the same moment must both end up in the pool
    /// store; a plain load-modify-save would let the last writer drop the other id.
    func testVMRunConcurrentProvisionsKeepBothMachinesInPool() throws {
        let cliPath = try bundledCLIPath()
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-run-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        var sockets: [(path: String, fd: Int32, state: MockSocketServerState, handled: XCTestExpectation)] = []
        defer {
            for socket in sockets {
                Darwin.close(socket.fd)
                unlink(socket.path)
            }
        }
        for machine in ["fresh-a", "fresh-b"] {
            let socketPath = makeSocketPath("vm-run-race-\(machine)")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
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
                    // Hold the create open so both processes are provisioning at once.
                    Thread.sleep(forTimeInterval: 1.0)
                    return self.v2Response(id: id, ok: true, result: ["id": machine, "provider": "freestyle", "status": "running", "image": "cmuxd-ws:tooling-20260509f"])
                case "vm.rename":
                    return self.v2Response(id: id, ok: true, result: ["id": machine, "displayName": "agent-pool"])
                case "vm.status":
                    return self.v2Response(id: id, ok: true, result: ["id": machine, "provider": "freestyle", "status": "running"])
                case "vm.exec":
                    return self.vmExecOKResponse(id: id, stdout: "\(machine)\n")
                default:
                    return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
                }
            }
            sockets.append((socketPath, listenerFD, state, handled))
        }

        let group = DispatchGroup()
        let resultsLock = NSLock()
        var results: [ProcessRunResult] = []
        for socket in sockets {
            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_SOCKET_PATH"] = socket.path
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            environment["HOME"] = isolatedHome.path
            group.enter()
            DispatchQueue.global().async {
                let result = self.runProcess(
                    executablePath: cliPath,
                    arguments: ["vm", "run", "--new", "--", "hostname"],
                    environment: environment,
                    timeout: 60
                )
                resultsLock.lock()
                results.append(result)
                resultsLock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 90), .success, "both routers should finish")
        wait(for: sockets.map(\.handled), timeout: 30)
        for result in results {
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        }
        let poolData = try Data(contentsOf: isolatedHome.appendingPathComponent(".cmuxterm/vm-run-pool.json"))
        let pool = try JSONSerialization.jsonObject(with: poolData) as? [String: Any]
        XCTAssertEqual(
            Set((pool?["machines"] as? [String]) ?? []),
            ["fresh-a", "fresh-b"],
            "a concurrent create must not drop the other router's machine from the pool"
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
        // The binding's timestamp is a fixed instant far inside the TTL window
        // (2100-01-01), so freshness does not depend on the host clock.
        let workKey = Self.vmRunWorkKey(forDirectory: FileManager.default.currentDirectoryPath)
        try Self.writeJSON([workKey: ["machine": "pool-2", "updatedAtUnix": 4_102_444_800]], to: isolatedHome.appendingPathComponent(".cmuxterm/vm-run-bindings.json"))
        try Self.writeJSON(["machines": ["pool-1", "pool-2"]], to: isolatedHome.appendingPathComponent(".cmuxterm/vm-run-pool.json"))

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
                        ["id": "pool-1", "displayName": "agent-pool", "status": "running", "provider": "freestyle", "image": "cmuxd-ws:tooling-20260509f"],
                        ["id": "pool-2", "displayName": "agent-pool", "status": "standby", "provider": "freestyle", "image": "cmuxd-ws:tooling-20260509f"],
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
                "provider": "freestyle",
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

// MARK: - vm push --secret / --watch, vm agent --wait, vm self

/// The second wave of transfer verbs, against the same mock control socket: a secret
/// file rides `vm.file_put` (never `vm.exec`), `--watch` pushes again when the tree
/// changes, `vm agent --wait --output` polls the terminal to its exit and pages its
/// output, and `vm self` renders the reflection the app fetched.
extension CLINotifyProcessIntegrationRegressionTests {
    /// Every decoded v2 request the mock saw, in order.
    private final class VMTransferRequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []

        func append(_ request: [String: Any]) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func snapshot() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        var methods: [String] { snapshot().compactMap { $0["method"] as? String } }

        func params(ofFirst method: String) -> [String: Any]? {
            snapshot().first { ($0["method"] as? String) == method }?["params"] as? [String: Any]
        }

        func params(of method: String) -> [[String: Any]] {
            snapshot().filter { ($0["method"] as? String) == method }.compactMap { $0["params"] as? [String: Any] }
        }
    }

    /// A mock that routes every v2 method through `respond`; nil → "unexpected method".
    /// `respond` may inspect the running log (call counts drive multi-step answers).
    private func startVMTransferMethodMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMTransferRequestLog,
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any], _ log: VMTransferRequestLog) -> [String: Any]?
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard let result = respond(method, params, log) else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            return self.v2Response(id: id, ok: true, result: result)
        }
    }

    private func vmTransferEnvironment(socketPath: String, home: URL? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        if let home { environment["HOME"] = home.path }
        return environment
    }

    /// The bytes of the push in flight: reset by the staging truncate, fed by every
    /// chunk, digested for the finalize step — so the mock verifies each sync exactly
    /// as a machine would.
    private final class VMPushAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var finalized = 0

        func reset() {
            lock.lock()
            bytes = Data()
            lock.unlock()
        }

        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }

        /// The sha256sum-style report for the current push, counting it as finalized.
        func finalizeReport(name: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            finalized += 1
            return "\(CLINotifyProcessIntegrationRegressionTests.sha256Hex(bytes))  \(name)\n"
        }

        var finalizedCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return finalized
        }
    }

    private func vmTransferTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testVMPushSecretDeliversOverTheLinkNeverExec() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-push-secret")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMTransferRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmTransferTempDir("secret")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let secret = Data("//registry.npmjs.org/:_authToken=npm_secret_value\n".utf8)
        let localFile = tempDir.appendingPathComponent("npmrc")
        try secret.write(to: localFile)

        let serverHandled = startVMTransferMethodMock(listenerFD: listenerFD, state: state, log: log) { method, params, _ in
            guard method == "vm.file_put", let machine = params["id"] as? String,
                  let path = params["path"] as? String, let encoded = params["data_base64"] as? String,
                  let bytes = Data(base64Encoded: encoded) else { return nil }
            return ["machine": machine, "path": path, "mode": (params["mode"] as? String) ?? "600", "bytes": bytes.count, "transport": "link"]
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "push", "--secret", "brave-otter", localFile.path, ".npmrc", "--mode", "600"],
            environment: vmTransferEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        // One request, the link-backed method, the file's exact bytes — and no exec anywhere.
        XCTAssertEqual(log.methods, ["vm.file_put"], log.methods.description)
        let params = log.params(ofFirst: "vm.file_put")
        XCTAssertEqual(params?["id"] as? String, "brave-otter")
        XCTAssertEqual(params?["path"] as? String, ".npmrc")
        XCTAssertEqual(params?["mode"] as? String, "600")
        XCTAssertEqual((params?["data_base64"] as? String).flatMap { Data(base64Encoded: $0) }, secret)
        XCTAssertFalse(state.snapshot().contains { $0.contains(#""method":"vm.exec""#) }, "a secret must never ride vm.exec")
        XCTAssertTrue(result.stdout.contains("OK .npmrc (\(secret.count) bytes, mode 600) delivered over the link"), result.stdout)
        XCTAssertFalse(result.stdout.contains("npm_secret_value"), "the value must not be echoed: \(result.stdout)")
    }

    func testVMPushSecretRefusesDirectoriesAndWatchBeforeTouchingTheMachine() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-push-secret-dir")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmTransferTempDir("secret-dir")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Data("x".utf8).write(to: tempDir.appendingPathComponent("a.txt"))
        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
            self.v2Response(
                id: self.jsonObject(line)?["id"] as? String ?? "unknown",
                ok: false,
                error: ["code": "unexpected", "message": "Local validation must not reach the socket"]
            )
        }
        let environment = vmTransferEnvironment(socketPath: socketPath)

        let directory = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "push", "--secret", "brave-otter", tempDir.path, "work/secrets"],
            environment: environment,
            timeout: 30
        )
        XCTAssertNotEqual(directory.status, 0, directory.stdout)
        XCTAssertTrue(directory.stderr.contains("is a directory"), directory.stderr)

        let combined = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "push", "--secret", "--watch", "brave-otter", tempDir.appendingPathComponent("a.txt").path],
            environment: environment,
            timeout: 30
        )
        XCTAssertNotEqual(combined.status, 0, combined.stdout)
        XCTAssertTrue(combined.stderr.contains("does not combine with --watch"), combined.stderr)

        let badMode = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "push", "--secret", "brave-otter", tempDir.appendingPathComponent("a.txt").path, "--mode", "rw"],
            environment: environment,
            timeout: 30
        )
        XCTAssertNotEqual(badMode.status, 0, badMode.stdout)
        XCTAssertTrue(badMode.stderr.contains("--mode must be three or four octal digits"), badMode.stderr)

        XCTAssertTrue(state.snapshot().isEmpty, "local validation must not reach the socket: \(state.snapshot())")
    }

    func testVMPushWatchPushesAgainWhenAFileChanges() throws {
        try assertVMPushWatchPushesAgainWhenAFileChanges(jsonOutput: false)
    }

    func testVMPushJSONWatchReportsInitialAndSubsequentSyncs() throws {
        try assertVMPushWatchPushesAgainWhenAFileChanges(jsonOutput: true)
    }

    private func assertVMPushWatchPushesAgainWhenAFileChanges(jsonOutput: Bool) throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-push-watch")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let pushes = VMPushAccumulator()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmTransferTempDir("watch")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Data("one\n".utf8).write(to: tempDir.appendingPathComponent("one.txt"))
        // Excluded trees must neither be pushed nor wake the watcher.
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)

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
                pushes.reset()
                return self.vmExecOKResponse(id: id, stdout: "")
            }
            if command.contains("| base64 -d >>") {
                guard let start = command.range(of: "printf %s '"),
                      let end = command.range(of: "' | base64 -d >>"),
                      let decoded = Data(base64Encoded: String(command[start.upperBound..<end.lowerBound])) else {
                    return self.v2Response(id: id, ok: false, error: ["code": "bad_chunk", "message": "Unparseable chunk command"])
                }
                pushes.append(decoded)
                return self.vmExecOKResponse(id: id, stdout: "")
            }
            if command.contains("sha256sum") {
                // The watcher re-pushes the whole tree: every finalize is one sync, and
                // the digest must be the tarball's or the CLI refuses the transfer.
                return self.vmExecOKResponse(id: id, stdout: pushes.finalizeReport(name: "push.tgz"))
            }
            if command.hasPrefix("mkdir -p ") && command.contains("tar -xzf") {
                return self.vmExecOKResponse(id: id, stdout: "")
            }
            return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected command \(command)"])
        }

        // Mutate the tree once the first push has extracted and the watcher has taken
        // its baseline: a new file, then the excluded folder (which must not count).
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !state.snapshot().contains(where: { $0.contains("tar -xzf") }) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            Thread.sleep(forTimeInterval: 0.8)
            try? Data("ignored\n".utf8).write(to: tempDir.appendingPathComponent("node_modules/dep.js"))
            try? Data("two\n".utf8).write(to: tempDir.appendingPathComponent("two.txt"))
        }

        var environment = vmTransferEnvironment(socketPath: socketPath)
        environment["CMUX_VM_PUSH_WATCH_ROUNDS"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: (jsonOutput ? ["--json"] : []) + ["vm", "push", "brave-otter", tempDir.path, "work/app", "--watch", "--interval", "0.2"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, "watch did not end after one sync: \(result.stderr)")
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        if jsonOutput {
            let events = try result.stdout.split(separator: "\n").map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
            XCTAssertEqual(events.count, 2, result.stdout)
            XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["synced", "synced"])
            XCTAssertEqual(events.compactMap { $0["sync"] as? Int }, [0, 1])
            XCTAssertEqual(events.compactMap { $0["files"] as? Int }, [1, 2])
            XCTAssertFalse(result.stderr.contains("Pushed"), result.stderr)
        } else {
            XCTAssertTrue(result.stdout.contains("Pushed"), "the initial push reports like a one-shot push: \(result.stdout)")
            XCTAssertTrue(result.stdout.contains("synced 2 files at "), "the re-push names the tracked files: \(result.stdout)")
        }
        XCTAssertEqual(pushes.finalizedCount, 2, "one initial push plus one re-push")
        XCTAssertEqual(
            state.snapshot().filter { $0.contains("tar -xzf") }.count, 2,
            "each sync extracts on the machine"
        )
    }

    func testVMAgentWaitPollsExitAndPagesOutput() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-agent-wait")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMTransferRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let home = try vmTransferTempDir("agent-home")
        defer { try? FileManager.default.removeItem(at: home) }

        let serverHandled = startVMTransferMethodMock(listenerFD: listenerFD, state: state, log: log) { method, params, log in
            switch method {
            case "surface.new_terminal":
                return ["terminal_id": "term_a1", "remote_workspace_id": "ws_1", "surface_id": ""]
            case "vm.terminal_wait_exit":
                // Still running once, then a clean exit with code 3.
                if log.params(of: "vm.terminal_wait_exit").count == 1 {
                    return ["state": "pending", "lifecycle": "running", "machine": "vivid-newt", "terminal_id": "term_a1"]
                }
                return ["state": "exited", "outcome": ["kind": "exit", "code": 3], "machine": "vivid-newt", "terminal_id": "term_a1"]
            case "vm.terminal_output":
                let after = (params["after"] as? Int) ?? 0
                if after == 0 {
                    return ["text": "hello ", "start_offset": "0", "next_offset": "6", "complete": false]
                }
                return ["text": "world\n", "start_offset": after, "next_offset": after + 6, "complete": true]
            default:
                return nil
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--no-open", "--wait", "--output", "--", "fix the failing test"],
            environment: vmTransferEnvironment(socketPath: socketPath, home: home),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        // The agent's exit code passes through; stdout is exactly its output.
        XCTAssertEqual(result.status, 3, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, "hello world\n")
        XCTAssertTrue(result.stderr.contains("exited code=3"), result.stderr)
        XCTAssertTrue(result.stderr.contains("Started claude on vivid-newt"), "launch report moves to stderr with --output: \(result.stderr)")
        XCTAssertEqual(
            log.methods,
            ["surface.new_terminal", "vm.terminal_wait_exit", "vm.terminal_wait_exit", "vm.terminal_output", "vm.terminal_output"],
            log.methods.description
        )
        let newTerminal = log.params(ofFirst: "surface.new_terminal")
        XCTAssertEqual(newTerminal?["machine"] as? String, "vivid-newt")
        XCTAssertEqual(newTerminal?["open"] as? Bool, false)
        let waits = log.params(of: "vm.terminal_wait_exit")
        XCTAssertEqual(waits.first?["terminal_id"] as? String, "term_a1")
        XCTAssertEqual(waits.first?["timeout_ms"] as? Int, 30_000, "waits in ≤30 s slices")
        let outputs = log.params(of: "vm.terminal_output")
        XCTAssertEqual(outputs.map { $0["after"] as? Int }, [0, 6], "pages follow next_offset")
    }

    func testVMAgentWaitTimeoutLeavesTheAgentRunning() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-agent-wait-timeout")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMTransferRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let home = try vmTransferTempDir("agent-home-timeout")
        defer { try? FileManager.default.removeItem(at: home) }

        let serverHandled = startVMTransferMethodMock(listenerFD: listenerFD, state: state, log: log) { method, _, _ in
            switch method {
            case "surface.new_terminal":
                return ["terminal_id": "term_a1", "remote_workspace_id": "ws_1", "surface_id": ""]
            case "vm.terminal_wait_exit":
                // A real daemon holds the request up to timeout_ms; keep the poll honest.
                Thread.sleep(forTimeInterval: 0.3)
                return ["state": "pending", "lifecycle": "running"]
            default:
                return nil
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "agent", "--agent", "codex", "--machine", "vivid-newt", "--no-open", "--wait", "--timeout", "1", "--json", "--", "summarize work/app"],
            environment: vmTransferEnvironment(socketPath: socketPath, home: home),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 1, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("still running"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm open vivid-newt/ws_1/term_a1"), "the reattach address is in the timeout message: \(result.stderr)")
        // The JSON still describes the launch; nothing was closed or killed.
        let payload = try XCTUnwrap(jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(payload["exited"] as? Bool, false)
        XCTAssertEqual(payload["terminal_id"] as? String, "term_a1")
        XCTAssertFalse(log.methods.contains("vm.terminal_close"), log.methods.description)
        let waits = log.params(of: "vm.terminal_wait_exit")
        XCTAssertFalse(waits.isEmpty)
        let requestedBudgets = waits.compactMap { $0["timeout_ms"] as? Int }
        XCTAssertEqual(requestedBudgets.count, waits.count, "Every daemon wait must declare a budget")
        XCTAssertTrue(requestedBudgets.allSatisfy { (0...1_000).contains($0) }, "Daemon request budgets must fit the configured 1 s budget: \(waits)")
    }

    func testVMSelfRendersTheReflectionIndexAndPassesPathsThrough() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-self")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMTransferRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let index: [String: Any] = [
            "name": "brave-otter",
            "display_name": "Brave Otter",
            "vm_id": "vm_123",
            "status": "running",
            "owner": ["user_id": "user_1", "email": "owner@example.com", "display_name": "Owner"],
            "team_id": "team_9",
            "plan_id": "pro",
            "machines": [["id": "vm_123"], ["id": "vm_456"]],
            "paths": [["path": "/owner", "description": "who owns this machine"], ["path": "/peers", "description": "sibling machines"]],
        ]
        let serverHandled = startVMTransferMethodMock(listenerFD: listenerFD, state: state, log: log) { method, params, _ in
            guard method == "vm.reflection", let machine = params["id"] as? String else { return nil }
            let path = (params["path"] as? String) ?? ""
            switch path {
            case "":
                return ["machine": machine, "path": "", "http_status": 200, "reflection": index]
            case "peers":
                return ["machine": machine, "path": "peers", "http_status": 200, "reflection": ["peers": [["name": "vivid-newt", "route": "ws://[fd00::2]:1337/v1/link"]]]]
            default:
                return ["machine": machine, "path": path, "http_status": 404, "reflection": ["error": "not_found", "paths": [["path": "/owner"], ["path": "/peers"]]]]
            }
        }
        let environment = vmTransferEnvironment(socketPath: socketPath)

        let human = runProcess(executablePath: cliPath, arguments: ["vm", "self", "brave-otter"], environment: environment, timeout: 30)
        XCTAssertEqual(human.status, 0, "stdout=\(human.stdout) stderr=\(human.stderr)")
        XCTAssertEqual(human.stdout, """
        name\tbrave-otter
        machine\tvm_123\trunning
        owner\towner@example.com
        team\tteam_9\t2 machines
        plan\tpro
        paths\t/owner, /peers

        """)

        let raw = runProcess(executablePath: cliPath, arguments: ["vm", "self", "brave-otter", "--json"], environment: environment, timeout: 30)
        XCTAssertEqual(raw.status, 0, raw.stderr)
        let rawBody = try XCTUnwrap(jsonObject(raw.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(rawBody["vm_id"] as? String, "vm_123", "--json is the reflection body itself, not the socket envelope")
        XCTAssertNil(rawBody["http_status"])

        let peers = runProcess(executablePath: cliPath, arguments: ["vm", "self", "brave-otter", "/peers/"], environment: environment, timeout: 30)
        XCTAssertEqual(peers.status, 0, peers.stderr)
        XCTAssertTrue(peers.stdout.contains("vivid-newt"), peers.stdout)

        let missing = runProcess(executablePath: cliPath, arguments: ["vm", "self", "brave-otter", "nope"], environment: environment, timeout: 30)
        XCTAssertEqual(missing.status, 1, missing.stdout)
        XCTAssertTrue(missing.stderr.contains("no reflection path 'nope'"), missing.stderr)
        XCTAssertTrue(missing.stderr.contains("/owner, /peers"), missing.stderr)

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(log.params(of: "vm.reflection").map { $0["path"] as? String }, ["", "", "peers", "nope"], "slashes are trimmed before the app sees the path")
        XCTAssertEqual(log.params(ofFirst: "vm.reflection")?["id"] as? String, "brave-otter")
    }
}

// MARK: - vm snapshot ls / rm

extension CLINotifyProcessIntegrationRegressionTests {
    func testVMSnapshotLsListsRowsNewestFirstAndRawJSON() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-snap-ls")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let requests = VMTransferMockState()
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard method == "vm.snapshot_list", let machine = params["id"] as? String else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            // The mock alternates: a populated machine, then one with no snapshots, then
            // a provider without the operation (the app's 501 passthrough shape).
            switch requests.nextCount() {
            case 1:
                return self.v2Response(id: id, ok: true, result: [
                    "machine": machine,
                    "snapshots": [
                        ["id": "snap_new", "name": "before-upgrade", "created_at": "2026-09-08T10:00:00.000Z"],
                        ["id": "snap_old", "name": NSNull(), "created_at": "2026-09-01T09:30:00.000Z"],
                    ],
                ])
            case 2:
                return self.v2Response(id: id, ok: true, result: ["machine": machine, "snapshots": []])
            default:
                return self.v2Response(id: id, ok: false, error: [
                    "code": "vm_error",
                    "message": "The Cloud VM request failed.",
                    "data": ["http_status": 501, "backend_code": "vm_operation_unsupported"],
                ])
            }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let listed = runProcess(executablePath: cliPath, arguments: ["vm", "snapshot", "ls", "brave-otter"], environment: environment, timeout: 30)
        XCTAssertEqual(listed.status, 0, "stdout=\(listed.stdout) stderr=\(listed.stderr)")
        XCTAssertEqual(listed.stdout, "snap_new\t2026-09-08T10:00:00.000Z\tbefore-upgrade\nsnap_old\t2026-09-01T09:30:00.000Z\t-\n")

        let empty = runProcess(executablePath: cliPath, arguments: ["vm", "snapshot", "list", "brave-otter", "--json"], environment: environment, timeout: 30)
        XCTAssertEqual(empty.status, 0, empty.stderr)
        let payload = try XCTUnwrap(jsonObject(empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(payload["machine"] as? String, "brave-otter")
        XCTAssertEqual((payload["snapshots"] as? [Any])?.count, 0, "--json is the raw socket result")

        let unsupported = runProcess(executablePath: cliPath, arguments: ["vm", "snapshot", "ls", "brave-otter"], environment: environment, timeout: 30)
        XCTAssertNotEqual(unsupported.status, 0, unsupported.stdout)
        XCTAssertTrue(unsupported.stderr.contains("brave-otter's provider cannot list snapshots"), unsupported.stderr)

        wait(for: [serverHandled], timeout: 30)
        let listRequests = state.snapshot().filter { $0.contains(#""method":"vm.snapshot_list""#) }
        XCTAssertEqual(listRequests.count, 3, state.snapshot().description)
        XCTAssertTrue(listRequests.allSatisfy { $0.contains(#""id":"brave-otter""#) }, listRequests.description)
        XCTAssertFalse(state.snapshot().contains { $0.contains(#""method":"vm.snapshot""#) && !$0.contains("snapshot_list") }, "`snapshot ls` must never create a snapshot")
    }

    func testVMSnapshotRmDeletesAndWordsNotFound() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-snap-rm")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
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
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard method == "vm.snapshot_delete",
                  let machine = params["id"] as? String,
                  let snapshotID = params["snapshot_id"] as? String else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            if snapshotID == "snap_gone" {
                return self.v2Response(id: id, ok: false, error: [
                    "code": "vm_error",
                    "message": "The Cloud VM request failed.",
                    "data": ["http_status": 404, "backend_code": "vm_snapshot_not_found"],
                ])
            }
            return self.v2Response(id: id, ok: true, result: ["machine": machine, "snapshot_id": snapshotID, "deleted": true])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let deleted = runProcess(executablePath: cliPath, arguments: ["vm", "snapshot", "rm", "brave-otter", "snap_old"], environment: environment, timeout: 30)
        XCTAssertEqual(deleted.status, 0, "stdout=\(deleted.stdout) stderr=\(deleted.stderr)")
        XCTAssertEqual(deleted.stdout, "OK deleted snap_old from brave-otter\n")

        let json = runProcess(executablePath: cliPath, arguments: ["vm", "snapshot", "delete", "brave-otter", "snap_old", "--json"], environment: environment, timeout: 30)
        XCTAssertEqual(json.status, 0, json.stderr)
        let payload = try XCTUnwrap(jsonObject(json.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(payload["deleted"] as? Bool, true)
        XCTAssertEqual(payload["snapshot_id"] as? String, "snap_old")

        let missing = runProcess(executablePath: cliPath, arguments: ["vm", "snapshot", "rm", "brave-otter", "snap_gone"], environment: environment, timeout: 30)
        XCTAssertNotEqual(missing.status, 0, missing.stdout)
        XCTAssertTrue(missing.stderr.contains("no snapshot snap_gone on brave-otter"), missing.stderr)
        XCTAssertTrue(missing.stderr.contains("cmux vm snapshot ls brave-otter"), missing.stderr)

        // Arity is checked locally: a bare `snapshot rm <machine>` never reaches the socket.
        let short = runProcess(executablePath: cliPath, arguments: ["vm", "snapshot", "rm", "brave-otter"], environment: environment, timeout: 30)
        XCTAssertNotEqual(short.status, 0, short.stdout)
        XCTAssertTrue(short.stderr.contains("cmux vm snapshot rm <machine> <snapshot-id>"), short.stderr)

        wait(for: [serverHandled], timeout: 30)
        let deleteRequests = state.snapshot().filter { $0.contains(#""method":"vm.snapshot_delete""#) }
        XCTAssertEqual(deleteRequests.count, 3, state.snapshot().description)
        XCTAssertTrue(deleteRequests.allSatisfy { $0.contains(#""id":"brave-otter""#) }, deleteRequests.description)
    }
}
