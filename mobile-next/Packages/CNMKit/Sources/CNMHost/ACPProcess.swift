#if os(macOS)
import CNMProtocol
import Foundation

/// A coding-agent harness speaking ACP (newline-delimited JSON-RPC 2.0) on
/// stdio. The host is the ACP client: it answers `fs/*` and forwards
/// `session/request_permission` to the phone.
final class ACPProcess: @unchecked Sendable {
    typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
    typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) -> Void

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()
    private var stderrTail = ""
    var onRequest: RequestHandler?
    var onNotification: NotificationHandler?
    var onExit: (@Sendable (Int32, String) -> Void)?

    init(command: [String], cwd: String, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.withLock {
                self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(4000))
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let tail = self.lock.withLock { self.stderrTail }
            self.failAll(RPCError(code: -32020, message: "Agent exited (\(process.terminationStatus))"))
            self.onExit?(process.terminationStatus, tail)
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }
    var stderrSummary: String { lock.withLock { stderrTail } }

    func request(_ method: String, _ params: JSONValue, timeout: Duration = .seconds(120)) async throws -> JSONValue {
        let id: Int = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.resolve(id, .failure(RPCError.timedOut)) }
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            write(message)
        }
    }

    func notify(_ method: String, _ params: JSONValue) {
        write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func write(_ message: JSONValue) {
        guard process.isRunning, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        // SIGPIPE is ignored process-wide (HostEnvironment), so a write racing
        // the agent's exit fails here instead of killing the host.
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines where !line.isEmpty {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONValue) {
        let id = message["id"]
        let method = message["method"]?.stringValue
        if let method {
            let params = message["params"] ?? .null
            if let id, id != .null {
                Task { [weak self] in
                    guard let self else { return }
                    var reply: JSONValue = ["jsonrpc": "2.0", "id": id]
                    do {
                        guard let handler = self.onRequest else { throw RPCError.methodNotFound }
                        reply = ["jsonrpc": "2.0", "id": id, "result": try await handler(method, params)]
                    } catch let error as RPCError {
                        reply = ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]
                    } catch {
                        reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string(error.localizedDescription)]]
                    }
                    self.write(reply)
                }
            } else {
                onNotification?(method, params)
            }
        } else if let id = id?.doubleValue.flatMap({ Int(exactly: $0) }) {
            if let error = message["error"] {
                resolve(id, .failure(RPCError(
                    code: error["code"]?.intValue ?? -32603,
                    message: error["message"]?.stringValue ?? "Agent error",
                    data: error["data"]
                )))
            } else {
                resolve(id, .success(message["result"] ?? .null))
            }
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSONValue, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let waiting: [CheckedContinuation<JSONValue, Error>] = lock.withLock {
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for continuation in waiting { continuation.resume(throwing: error) }
    }
}
#endif
