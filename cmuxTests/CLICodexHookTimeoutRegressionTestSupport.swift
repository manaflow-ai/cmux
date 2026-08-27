import Dispatch
import Foundation
import Darwin
import Testing

struct InstalledHookEntry {
    let eventName: String
    let command: String
    let body: String
}

struct CodexHookProcessRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

func codexHookTestEnvironment(root: URL, codexHome: URL) -> [String: String] {
    [
        "HOME": root.path,
        "CFFIXED_USER_HOME": root.path,
        "CODEX_HOME": codexHome.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "CMUX_CLI_SENTRY_DISABLED": "1",
    ]
}

func codexHookEntries(in codexHome: URL) throws -> [InstalledHookEntry] {
    let hookURL = codexHome.appendingPathComponent("hooks.json", isDirectory: false)
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
    let hooks = try #require(json["hooks"] as? [String: Any])
    return try hooks.flatMap { eventName, values -> [InstalledHookEntry] in
        guard let groups = values as? [[String: Any]] else { return [] }
        return try groups
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { hook in
                guard let command = hook["command"] as? String else { return nil }
                let body: String
                if command.hasPrefix("/") {
                    body = (try? String(contentsOfFile: command, encoding: .utf8)) ?? command
                } else {
                    body = command
                }
                return InstalledHookEntry(eventName: eventName, command: command, body: body)
            }
    }
}

func makeCodexHookExecutableShellFile(at url: URL, lines: [String]) throws {
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

final class CodexHookCapturedSocketCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    func append(_ command: String) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let value = commands
        lock.unlock()
        return value
    }
}

func makeCodexHookSocketPath(_ name: String) -> String {
    let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    return URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cli-\(name.prefix(6))-\(shortID).sock")
        .path
}

func bindCodexHookUnixSocket(at path: String) throws -> Int32 {
    unlink(path)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw NSError(domain: "cmux.tests", code: Int(errno))
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
    let utf8 = Array(path.utf8)
    guard utf8.count < maxPathLength else {
        Darwin.close(fd)
        throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
            for index in 0..<utf8.count {
                buffer[index] = CChar(bitPattern: utf8[index])
            }
            buffer[utf8.count] = 0
        }
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
        let code = errno
        Darwin.close(fd)
        throw NSError(domain: "cmux.tests", code: Int(code))
    }
    return fd
}

func startCodexHookMockSocketServerAccepting(
    listenerFD: Int32,
    commands: CodexHookCapturedSocketCommands,
    surfaceId: String,
    connectionLimit: Int
) {
    // Accept and per-client loops block indefinitely; keep them off the
    // libdispatch pool so parallel suites cannot starve each other.
    CLITestProcessRunner.detachBlockingThread(name: "cmux-test-codex-mock-accept") {
        var accepted = 0
        while accepted < connectionLimit {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            accepted += 1
            CLITestProcessRunner.detachBlockingThread(name: "cmux-test-codex-mock-client") {
                handleCodexHookMockSocketClient(fd: clientFD, commands: commands, surfaceId: surfaceId)
            }
        }
    }
}

func handleCodexHookMockSocketClient(
    fd clientFD: Int32,
    commands: CodexHookCapturedSocketCommands,
    surfaceId: String
) {
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
        while let newlineRange = pending.firstRange(of: Data([0x0A])) {
            let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
            pending.removeSubrange(0...newlineRange.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            commands.append(line)
            let response = codexHookMockSocketResponse(for: line, surfaceId: surfaceId) + "\n"
            _ = response.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
        }
    }
}

func codexHookMockSocketResponse(for line: String, surfaceId: String) -> String {
    guard let payload = codexHookJSONObject(line),
          let id = payload["id"] as? String else {
        return "OK"
    }
    if payload["method"] as? String == "surface.list" {
        return codexHookV2Response(
            id: id,
            ok: true,
            result: ["surfaces": [["id": surfaceId, "ref": surfaceId, "focused": true]]]
        )
    }
    return codexHookV2Response(id: id, ok: true, result: [:])
}

func codexHookV2Response(
    id: String,
    ok: Bool,
    result: [String: Any]? = nil
) -> String {
    var payload: [String: Any] = ["id": id, "ok": ok]
    if let result { payload["result"] = result }
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
}

func codexHookJSONObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
}

func runCodexHookProcess(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    standardInput: String? = nil,
    timeout: TimeInterval
) -> CodexHookProcessRunResult {
    // Runs on dedicated threads (CLITestProcessRunner) so a saturated
    // libdispatch pool during parallel Swift Testing cannot hide the exit.
    let outcome = CLITestProcessRunner.run(
        executablePath: executablePath,
        arguments: arguments,
        environment: environment,
        standardInput: standardInput,
        timeout: timeout
    )
    return CodexHookProcessRunResult(
        status: outcome.status,
        stdout: outcome.stdout,
        stderr: outcome.stderr,
        timedOut: outcome.timedOut
    )
}

func waitForFile(_ url: URL, containing expected: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let content = try? String(contentsOf: url, encoding: .utf8), content.contains(expected) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}

/// Polls `condition` while blocking the calling thread with `Thread.sleep`.
///
/// Use it only for conditions a background thread satisfies, such as a socket
/// accumulator or a file a child process writes. It runs no run loop, so on the
/// main thread it starves main-queue and main-actor work and the condition can
/// never become true. Main-thread waits belong in the per-file XCTWaiter
/// helpers, which pump the main queue between polls.
func waitForConditionBlocking(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.02,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: pollInterval)
    }
    return condition()
}
