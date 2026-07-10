import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ShellIntegrationSendTransportTests {
    /// The assertion needs the harness to host a unix-socket loop for spawned
    /// children at all: on some CI app-host contexts a plain `/usr/bin/nc`
    /// child delivers nothing to a listener owned by the test process (the
    /// integration sources cleanly and nc runs; the environment eats the
    /// connect). Probe that pure baseline, with no shell integration
    /// involved, so the regression test runs on every developer machine and
    /// reports as skipped, not failed, where the harness cannot host it.
    private static func childProcessUnixSocketLoopWorks() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/nc") else { return false }
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-stp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("b.sock").path
        guard let listener = try? UnixLineListener(path: socketPath) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "print -r -- baseline | /usr/bin/nc -w 1 -U '\(socketPath)'"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return listener.waitForLine(timeout: 5) == "baseline"
    }

    /// End-to-end contract for `_cmux_send`: sourcing the bundled integration
    /// in a fresh zsh and sending one payload must deliver that payload to a
    /// unix-socket listener. This transport carries the whole hook channel
    /// (report_tty, ports_kick, report_shell_state, git/PR reports); it broke
    /// silently on machines where PATH `nc` is GNU netcat without unix-socket
    /// support, so delivery must not depend on PATH resolution.
    @Test(.enabled(if: childProcessUnixSocketLoopWorks(), "harness cannot host a child-process unix-socket loop"))
    func sendDeliversPayloadToUnixSocketListener() throws {
        let script = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                named: "cmux-zsh-integration.zsh"
            ),
            "cmux-zsh-integration.zsh must ship in the app bundle"
        )
        // Deliberately short root: unix socket paths must fit
        // sockaddr_un.sun_path (104 bytes on Darwin), and the default
        // temporaryDirectory under /var/folders is long enough to overflow it.
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-st-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

        // Output goes to files, not pipes: an unread pipe can deadlock the
        // child, and the file contents become the failure diagnostics.
        let logURL = dir.appendingPathComponent("run.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.environment = [
            "CMUX_SOCKET_PATH": socketPath,
            "PATH": "\(shimDir.path):/usr/bin:/bin",
            "HOME": dir.path,
        ]
        process.arguments = [
            "-f", "-c",
            """
            source '\(scriptFile.path)'
            print -r -- "diag: usrbin_nc_executable=$([[ -x /usr/bin/nc ]] && echo 1 || echo 0)"
            print -r -- "diag: path_nc=$(whence -p nc 2>/dev/null)"
            _cmux_send 'transport probe'
            print -r -- "diag: send_rc=$?"
            """,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()

        let delivered = listener.waitForLine(timeout: 10)
        let diagnostics = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<no log>"
        #expect(
            delivered == "transport probe",
            "The shell integration's socket send must deliver its payload to the listener. exit=\(process.terminationStatus) log:\n\(diagnostics.suffix(1200))"
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
