import Foundation

/// Runs a program to completion and captures its output.
struct ProcessRunner: Sendable {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var truncated: Bool
        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var environment: [String: String]
    /// Output beyond this is drained and dropped (`truncated`).
    var maximumOutputBytes: Int

    init(extraEnvironment: [String: String] = [:], maximumOutputBytes: Int = 16 << 20) {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnvironment { env[k] = v }
        environment = env
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(_ executable: String, _ arguments: [String], cwd: String? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let limit = maximumOutputBytes
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let group = DispatchGroup()
                nonisolated(unsafe) var stdout = Data()
                nonisolated(unsafe) var stderr = Data()
                nonisolated(unsafe) var truncated = false
                group.enter()
                DispatchQueue.global().async {
                    (stdout, truncated) = Self.drain(out.fileHandleForReading, limit: limit)
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    (stderr, _) = Self.drain(err.fileHandleForReading, limit: 64 * 1024)
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: stdout, stderr: stderr, truncated: truncated))
            }
        }
    }

    private static func drain(_ handle: FileHandle, limit: Int) -> (Data, Bool) {
        var data = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count <= limit {
                data.append(chunk)
            } else {
                if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
                truncated = true
            }
        }
        return (data, truncated)
    }
}
