import Darwin
import Foundation
import XCTest

// Shared test-support helpers for the `CMUXOpenCommandTests` suite: process
// spawning, unix-socket mock cmux servers, v2 protocol payload helpers, and
// diff-viewer asset fixtures. The suite's test methods live in
// CMUXOpenCommandTests.swift and CMUXOpenDiffViewerFirstPaintTests.swift.
extension CMUXOpenCommandTests {
    struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    final class MockSocketServerState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var commands: [String] = []

        func append(_ command: String) {
            lock.lock()
            commands.append(command)
            lock.unlock()
        }
    }

    final class AsyncValueBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Value {
            lock.lock()
            let value = self.value
            lock.unlock()
            return value
        }
    }

    func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    }

    func writeTestDiffViewerAssets(resourcesURL: URL, appMain: String) throws {
        let diffViewerURL = resourcesURL
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("diff-viewer", isDirectory: true)
        let appURL = resourcesURL
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("diff-viewer-app", isDirectory: true)
        let workerPoolURL = diffViewerURL.appendingPathComponent("worker-pool", isDirectory: true)
        try FileManager.default.createDirectory(at: workerPoolURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try "export const diffsFixture = true;\n".write(
            to: diffViewerURL.appendingPathComponent("diffs.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "export const treesFixture = true;\n".write(
            to: diffViewerURL.appendingPathComponent("trees.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "export const workerPoolFixture = true;\n".write(
            to: workerPoolURL.appendingPathComponent("worker-pool.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "self.cmuxWorkerFixture = true;\n".write(
            to: workerPoolURL.appendingPathComponent("worker-portable.js", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try appMain.write(
            to: appURL.appendingPathComponent("main.mjs", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        currentDirectoryURL: URL? = nil,
        stdinText: String? = nil
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe?
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }
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
        if let stdinText, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(stdinText.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: timedOut ? 124 : process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    func readLine(from handle: FileHandle, timeout: TimeInterval) throws -> String {
        let finished = DispatchSemaphore(value: 0)
        let dataBox = AsyncValueBox(Data())
        DispatchQueue.global(qos: .userInitiated).async {
            var line = Data()
            while line.count < 1024 {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty || byte == Data([0x0a]) {
                    break
                }
                line.append(byte)
            }
            dataBox.set(line)
            finished.signal()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "cmux.tests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "timed out reading process line",
            ])
        }
        return String(data: dataBox.get(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func fetchData(from url: URL, timeout: TimeInterval) throws -> (data: Data, statusCode: Int) {
        let finished = DispatchSemaphore(value: 0)
        let resultBox = AsyncValueBox<(Data?, Int?, Error?)>((nil, nil, nil))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: url) { data, response, error in
            resultBox.set((data, (response as? HTTPURLResponse)?.statusCode, error))
            finished.signal()
        }
        task.resume()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw NSError(domain: "cmux.tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "timed out fetching \(url.absoluteString)",
            ])
        }
        session.invalidateAndCancel()

        let (data, statusCode, error) = resultBox.get()
        if let error {
            throw error
        }
        return (data ?? Data(), statusCode ?? 0)
    }

    func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1)
        }
    }

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func bindUnixSocket(at path: String) throws -> Int32 {
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

    func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
            .path
    }

    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli open mock socket handled")
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
        return handled
    }

    func startTopMockServer(
        listenerFD: Int32,
        payload: [String: Any],
        assertParams: (([String: Any]) -> Void)? = nil
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: MockSocketServerState()) { line in
            guard let request = Self.v2Payload(from: line),
                  let id = request["id"] as? String,
                  request["method"] as? String == "system.top" else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            assertParams?(request["params"] as? [String: Any] ?? [:])
            return Self.v2Response(id: id, ok: true, result: payload)
        }
    }

    func topNode(
        ref: String,
        cpu: Double,
        rss: Int,
        processCount: Int,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var result = extra
        result["ref"] = ref
        result["resources"] = topResources(cpu: cpu, rss: rss, processCount: processCount)
        return result
    }

    func topTag(
        key: String,
        cpu: Double,
        rss: Int,
        processCount: Int
    ) -> [String: Any] {
        [
            "key": key,
            "resources": topResources(cpu: cpu, rss: rss, processCount: processCount),
        ]
    }

    func topResources(cpu: Double, rss: Int, processCount: Int) -> [String: Any] {
        [
            "cpu_percent": cpu,
            "resident_bytes": rss,
            "process_count": processCount,
        ]
    }

    func outputLines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }

    static func v2Payload(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    static func v2Response(
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
