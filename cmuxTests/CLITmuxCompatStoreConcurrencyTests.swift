import Darwin
import Foundation
import Testing

/// Exercises the on-disk tmux compatibility store through separate CLI
/// processes, which is the boundary where concurrent writers can overwrite one
/// another.
@Suite(.serialized)
struct CLITmuxCompatStoreConcurrencyTests {
    private static let writerCount = 20

    @Test func concurrentSetBufferCallsRetainEveryBuffer() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-store-concurrency-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let storeURL = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("tmux-compat-store.json", isDirectory: false)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A non-empty store widens the decode/encode window and keeps this a
        // deterministic repro of a read-modify-write race, rather than a test
        // that happens to depend on process startup ordering.
        let seed = String(repeating: "seed", count: 32_768)
        let initialStore: [String: Any] = ["buffers": ["seed": seed]]
        let initialData = try JSONSerialization.data(withJSONObject: initialStore, options: [])
        try initialData.write(to: storeURL, options: .atomic)

        // Keep the socket name short: macOS limits sockaddr_un.sun_path to
        // 104 bytes, while FileManager.default.temporaryDirectory paths can be long.
        let socketPath = "/tmp/cmux-11262-\(UUID().uuidString.prefix(8)).sock"
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverDone = Self.startClientDrain(listenerFD: listenerFD, expectedClients: Self.writerCount)

        let environment = [
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_SOCKET_PASSWORD": "",
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        let resultLock = NSLock()
        var results: [ProcessRunResult] = []
        DispatchQueue.concurrentPerform(iterations: Self.writerCount) { index in
            let result = Self.runProcess(
                executablePath: cliPath,
                arguments: [
                    "set-buffer",
                    "--name", "buf-\(index)",
                    "--",
                    "payload-\(index)",
                ],
                environment: environment,
                timeout: 30
            )
            resultLock.lock()
            results.append(result)
            resultLock.unlock()
        }

        #expect(serverDone.wait(timeout: .now() + 30) == .success)
        #expect(results.count == Self.writerCount)
        #expect(results.allSatisfy { $0.status == 0 && !$0.timedOut }, Comment(rawValue: results.map(\.stderr).joined()))

        let persistedData = try Data(contentsOf: storeURL)
        let persistedObject = try #require(
            JSONSerialization.jsonObject(with: persistedData, options: []) as? [String: Any]
        )
        let buffers = try #require(persistedObject["buffers"] as? [String: String])
        #expect(buffers["seed"] == seed)
        #expect(buffers.count == Self.writerCount + 1)
        for index in 0..<Self.writerCount {
            #expect(buffers["buf-\(index)"] == "payload-\(index)")
        }
    }

    @Test func malformedStoreIsNotReplacedBySetBuffer() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-store-malformed-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let storeURL = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("tmux-compat-store.json", isDirectory: false)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let malformed = Data("{not-json".utf8)
        try malformed.write(to: storeURL, options: .atomic)
        let socketPath = "/tmp/cmux-11262-\(UUID().uuidString.prefix(8)).sock"
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverDone = Self.startClientDrain(listenerFD: listenerFD, expectedClients: 1)
        let result = Self.runProcess(
            executablePath: cliPath,
            arguments: ["set-buffer", "--name", "buf", "--", "payload"],
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_PASSWORD": "",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            timeout: 30
        )
        #expect(serverDone.wait(timeout: .now() + 30) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status != 0)
        #expect(result.stderr.hasPrefix("Error:"), Comment(rawValue: result.stderr))
        #expect(try Data(contentsOf: storeURL) == malformed)
    }

    private struct ProcessRunResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
    }

    private final class BundleToken {}

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for (index, byte) in bytes.enumerated() {
                    buffer[index] = CChar(bitPattern: byte)
                }
                buffer[bytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        guard Darwin.listen(fd, 128) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private static func startClientDrain(listenerFD: Int32, expectedClients: Int) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            for _ in 0..<expectedClients {
                var descriptor = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&descriptor, 1, 30_000) > 0 else { return }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                guard clientFD >= 0 else { return }
                Darwin.close(clientFD)
            }
        }
        return done
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stderr: String(describing: error), timedOut: false)
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessRunResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
