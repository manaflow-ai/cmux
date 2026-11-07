import Darwin
import Foundation
import Testing

/// `cmux vm run` remembers which machine served a directory in
/// `~/.cmuxterm/vm-run-bindings.json`. Several routers can run at once, so a
/// binding written while another router is mid-update must survive that update.
@Suite(.serialized)
struct CLIVMRunBindingStoreTests {
    @Test func bindingSurvivesAnotherRouterUpdatingTheStore() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-run-bindings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let storeURL = home.appendingPathComponent(".cmuxterm/vm-run-bindings.json", isDirectory: false)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-vm-bind-\(UUID().uuidString.prefix(8)).sock").path
        let listener = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listener)
            unlink(socketPath)
        }
        let connected = DispatchSemaphore(value: 0)
        let execReceived = DispatchSemaphore(value: 0)
        let server = Task.detached {
            Self.serveVMExec(listener: listener, connected: connected, execReceived: execReceived)
        }

        // Play another router mid-update: it holds the store lock and has read
        // the store, then writes back what it read plus its own binding.
        let lockFD = open(storeURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(lockFD >= 0)
        defer { close(lockFD) }
        try #require(flock(lockFD, LOCK_EX) == 0)
        let otherRouterSnapshot = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = home.path
        let childEnvironment = environment
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        let run = Task.detached {
            CLIHookProcessRunner.run(
                executablePath: cliPath,
                arguments: ["vm", "run", "--machine", "pool-1", "--", "true"],
                environment: childEnvironment,
                timeout: 30
            )
        }

        // `vm run` connects before it records its binding, and with `--machine`
        // it sends nothing until `vm.exec`, which follows the record. A router
        // that honors the lock is still waiting for it, so `vm.exec` cannot arrive.
        try #require(Self.wait(for: connected, seconds: 15) == .success, "vm run never connected")
        #expect(
            Self.wait(for: execReceived, seconds: 2) == .timedOut,
            "vm run recorded its binding while another router held the store lock"
        )
        var otherRouterStore = otherRouterSnapshot
        otherRouterStore["other-work"] = ["machine": "pool-2", "updatedAtUnix": Int(Date().timeIntervalSince1970)]
        try JSONSerialization.data(withJSONObject: otherRouterStore).write(to: storeURL, options: .atomic)
        _ = flock(lockFD, LOCK_UN)

        let result = await run.value
        _ = await server.value
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let store = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: [String: Any]]
        )
        #expect(
            store.values.compactMap { $0["machine"] as? String }.sorted() == ["pool-1", "pool-2"],
            "both routers' bindings must survive: \(store)"
        )
    }

    /// Blocking waits are unavailable from async contexts, so wrap one.
    private static func wait(for semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + seconds)
    }

    /// Answers `vm.exec` (and any other v2 request) on the first connection.
    private static func serveVMExec(listener: Int32, connected: DispatchSemaphore, execReceived: DispatchSemaphore) {
        var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&readiness, 1, 30_000) > 0 else { return }
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        connected.signal()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let request = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let id = request["id"] as? String else { continue }
                if request["method"] as? String == "vm.exec" { execReceived.signal() }
                let reply: [String: Any] = ["id": id, "ok": true, "result": ["exit_code": 0, "stdout": "", "stderr": ""]]
                guard var response = try? JSONSerialization.data(withJSONObject: reply) else { continue }
                response.append(0x0A)
                response.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = Darwin.write(client, base, raw.count)
                }
            }
        }
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let buffer = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, source, capacity - 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        return fd
    }
}
