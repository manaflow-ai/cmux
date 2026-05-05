import XCTest
import Darwin
import CMUXNodeOptions

final class ClaudeWrapperNodeOptionsRestoreModuleTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
    }

    func testNodeOptionsRequirePathRoundTripsApostrophes() {
        let path = "/Users/oconnor's/cmux/node-options/restore-node-options.cjs"
        let nodeOptions = "--require=\(NodeOptionsSupport.requirePath(path)) --trace-warnings"

        XCTAssertEqual(
            NodeOptionsSupport.tokens(nodeOptions),
            ["--require=\(path)", "--trace-warnings"]
        )
    }

    func testNodeOptionsTokenizationPreservesUnquotedApostrophes() {
        let nodeOptions = "--require=/Users/oconnor's/preload.cjs --trace-warnings"

        XCTAssertEqual(
            NodeOptionsSupport.tokens(nodeOptions),
            ["--require=/Users/oconnor's/preload.cjs", "--trace-warnings"]
        )
        XCTAssertEqual(
            NodeOptionsSupport.joinedTokens(NodeOptionsSupport.tokens(nodeOptions)),
            nodeOptions
        )
    }

    func testRestoreModulePathDetectionRequiresManagedTrailingComponents() {
        XCTAssertTrue(
            NodeOptionsSupport.isCmuxRestoreModulePath(
                "/Users/example/Library/Application Support/cmux/node-options/restore-node-options.cjs"
            )
        )
        XCTAssertTrue(
            NodeOptionsSupport.isCmuxRestoreModulePath(
                "/var/folders/example/T/cmux-claude-node-options/restore-node-options.cjs"
            )
        )
        XCTAssertFalse(
            NodeOptionsSupport.isCmuxRestoreModulePath(
                "/tmp/cmux/node-options/archive/restore-node-options.cjs"
            )
        )
    }

    func testRestoreModuleIsRecreatedUnderApplicationSupportAfterDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-node-options-\(UUID().uuidString)", isDirectory: true)
        let wrapperDir = root.appendingPathComponent("wrapper-bin", isDirectory: true)
        let realDir = root.appendingPathComponent("real-bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let tmpDir = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceWrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/claude", isDirectory: false)
        let wrapper = wrapperDir.appendingPathComponent("claude", isDirectory: false)
        try FileManager.default.copyItem(at: sourceWrapper, to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let realClaude = realDir.appendingPathComponent("claude", isDirectory: false)
        try writeExecutable(
            """
            #!/usr/bin/env bash
            set -euo pipefail
            printf '%s\\n' "${NODE_OPTIONS-__UNSET__}" >> "$FAKE_NODE_OPTIONS_LOG"
            """,
            to: realClaude
        )

        let fakeCmux = wrapperDir.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutable(
            """
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "${1:-}" == "--socket" ]]; then
              shift 2
            fi
            if [[ "${1:-}" == "ping" ]]; then
              exit 0
            fi
            exit 0
            """,
            to: fakeCmux
        )

        let socketPath = root.appendingPathComponent("cmux.sock", isDirectory: false).path
        let socketFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath)
        }

        let nodeOptionsLog = root.appendingPathComponent("node-options.log", isDirectory: false)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            wrapperDir.path,
            realDir.path,
            environment["PATH"] ?? "/usr/bin:/bin"
        ].joined(separator: ":")
        environment["HOME"] = home.path
        environment["TMPDIR"] = tmpDir.path
        environment["CMUX_SURFACE_ID"] = "surface:test"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCmux.path
        environment["FAKE_NODE_OPTIONS_LOG"] = nodeOptionsLog.path
        environment.removeValue(forKey: "NODE_OPTIONS")

        let first = runWrapper(wrapper, environment: environment)
        XCTAssertFalse(first.timedOut, first.stderr)
        XCTAssertEqual(first.status, 0, first.stderr)
        let firstRestorePath = try restoreModulePath(from: try lastLine(in: nodeOptionsLog))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstRestorePath))

        let appSupportRoot = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
        XCTAssertTrue(
            path(firstRestorePath, isDescendantOf: appSupportRoot),
            "restore module should be in Application Support, got \(firstRestorePath)"
        )
        XCTAssertFalse(
            path(firstRestorePath, isDescendantOf: tmpDir),
            "restore module should not be in TMPDIR, got \(firstRestorePath)"
        )

        try FileManager.default.removeItem(atPath: firstRestorePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRestorePath))

        let second = runWrapper(wrapper, environment: environment)
        XCTAssertFalse(second.timedOut, second.stderr)
        XCTAssertEqual(second.status, 0, second.stderr)
        let secondRestorePath = try restoreModulePath(from: try lastLine(in: nodeOptionsLog))
        XCTAssertEqual(secondRestorePath, firstRestorePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRestorePath))
    }

    private func writeExecutable(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func restoreModulePath(from nodeOptions: String) throws -> String {
        let tokens = NodeOptionsSupport.tokens(nodeOptions)
        let requireToken = try XCTUnwrap(tokens.first { $0.hasPrefix("--require=") })
        return String(requireToken.dropFirst("--require=".count))
    }

    private func lastLine(in url: URL) throws -> String {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(content.split(separator: "\n").last.map(String.init))
    }

    private func path(_ path: String, isDescendantOf root: URL) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedRoot = root.standardizedFileURL.path
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "socket(AF_UNIX) failed"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
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
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "bind(\(path)) failed"]
            )
        }
        guard Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "listen(\(path)) failed"]
            )
        }
        return fd
    }

    private func runWrapper(_ wrapper: URL, environment: [String: String], timeout: TimeInterval = 5) -> ProcessRunResult {
        let process = Process()
        process.executableURL = wrapper
        process.arguments = ["hello"]
        process.environment = environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let exitSignal = DispatchSemaphore(value: 0)
        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stderr: "\(error)", timedOut: false)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}
