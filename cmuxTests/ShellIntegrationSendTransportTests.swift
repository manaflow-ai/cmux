import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ShellIntegrationSendTransportTests {
    /// End-to-end contract for `_cmux_send`: sourcing the bundled integration
    /// in a fresh zsh and sending one payload must deliver that payload to a
    /// unix-socket listener. This transport carries the whole hook channel
    /// (report_tty, ports_kick, report_shell_state, git/PR reports); it broke
    /// silently on machines where PATH `nc` is GNU netcat without unix-socket
    /// support, so delivery must not depend on PATH resolution.
    @Test func sendDeliversPayloadToUnixSocketListener() throws {
        let script = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                named: "cmux-zsh-integration.zsh"
            ),
            "cmux-zsh-integration.zsh must ship in the app bundle"
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-send-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptFile = dir.appendingPathComponent("integration.zsh")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        let socketPath = dir.appendingPathComponent("t.sock").path

        // Reproduce the regression: a PATH-first `nc` without unix-socket
        // support (GNU netcat's shape) that fails every invocation. The
        // transport must deliver anyway by pinning the system client.
        let shimDir = dir.appendingPathComponent("shims", isDirectory: true)
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        let shim = shimDir.appendingPathComponent("nc")
        try "#!/bin/sh\nexit 1\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let listener = try UnixLineListener(path: socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = [
            "CMUX_SOCKET_PATH": socketPath,
            "PATH": "\(shimDir.path):/usr/bin:/bin",
            "HOME": dir.path,
        ]
        process.arguments = [
            "-f", "-c",
            "source '\(scriptFile.path)' >/dev/null 2>&1; _cmux_send 'transport probe'",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(
            listener.waitForLine(timeout: 10) == "transport probe",
            "The shell integration's socket send must deliver its payload to the listener."
        )
    }
}

/// Minimal blocking unix-socket listener: accepts one client, reads one line,
/// replies "OK" and closes so response-waiting clients (BSD `nc -N`) exit.
private final class UnixLineListener: @unchecked Sendable {
    private let serverFD: Int32
    private let received = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var line: String?

    init(path: String) throws {
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw POSIXError(.EMFILE) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        try path.withCString { cs in
            guard strlen(cs) <= maxLen else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.baseAddress!.copyMemory(from: cs, byteCount: Int(strlen(cs)) + 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, size)
            }
        }
        guard bound == 0, listen(serverFD, 4) == 0 else {
            close(serverFD)
            throw POSIXError(.EADDRINUSE)
        }
        let fd = serverFD
        DispatchQueue.global().async { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while !data.contains(0x0A) {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[0..<count])
            }
            _ = "OK\n".withCString { write(client, $0, 3) }
            close(client)
            guard let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.lock()
            self.line = text.split(separator: "\n").first.map(String.init)
            self.lock.unlock()
            self.received.signal()
        }
    }

    func waitForLine(timeout: TimeInterval) -> String? {
        _ = received.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return line
    }

    deinit { close(serverFD) }
}
