import Darwin
import Foundation
import Testing

@Suite struct ClaudeWrapperResumeEnvironmentTests {
    @Test func bundledClaudeWrapperScrubsNestedSessionEnvironmentOnResume() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let wrapperURL = repoRoot.appendingPathComponent("Resources/bin/cmux-claude-wrapper", isDirectory: false)
        #expect(
            fileManager.isExecutableFile(atPath: wrapperURL.path),
            "Bundled cmux-claude-wrapper must exist and be executable for resume environment coverage"
        )
        guard fileManager.isExecutableFile(atPath: wrapperURL.path) else { return }

        let sandbox = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-resume-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        let binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        let homeDir = sandbox.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let socketURL = sandbox.appendingPathComponent("cmux.sock", isDirectory: false)
        let socketFD = try bindUnixSocket(at: socketURL.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketURL.path)
        }

        let recordURL = sandbox.appendingPathComponent("record.txt", isDirectory: false)
        try writeExecutable(
            binDir.appendingPathComponent("claude", isDirectory: false),
            """
            #!/usr/bin/env bash
            {
              printf 'argv=%s\\n' "$*"
              for key in CLAUDECODE CLAUDE_CODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_PARENT_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SSE_PORT CLAUDE_CODE_USE_VERTEX; do
                if value="$(printenv "$key")"; then
                  printf '%s=%s\\n' "$key" "$value"
                else
                  printf '%s=<unset>\\n' "$key"
                fi
              done
            } > \(shellQuotedForTest(recordURL.path))
            """
        )
        let fakeCmuxURL = binDir.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutable(
            fakeCmuxURL,
            """
            #!/usr/bin/env bash
            if [[ "${1:-}" == "--socket" && "${3:-}" == "ping" ]]; then
              exit 0
            fi
            exit 1
            """
        )

        let process = Process()
        process.executableURL = wrapperURL
        process.arguments = ["--resume", "claude-session-123"]
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "HOME": homeDir.path,
            "TMPDIR": sandbox.path,
            "CMUX_SURFACE_ID": UUID().uuidString,
            "CMUX_SOCKET_PATH": socketURL.path,
            "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
            "CLAUDECODE": "1",
            "CLAUDE_CODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "parent-child",
            "CLAUDE_CODE_PARENT_SESSION_ID": "parent-session",
            "CLAUDE_CODE_SESSION_ID": "parent-session",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_EXECPATH": "/opt/homebrew/bin/claude",
            "CLAUDE_CODE_SSE_PORT": "12345",
            "CLAUDE_CODE_USE_VERTEX": "1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: "cmux-claude-wrapper --resume")

        let recorded = try String(contentsOf: recordURL, encoding: .utf8)
        #expect(recorded.contains("--settings"), Comment(rawValue: recorded))
        #expect(recorded.contains("--resume claude-session-123"), Comment(rawValue: recorded))
        for key in [
            "CLAUDECODE",
            "CLAUDE_CODE",
            "CLAUDE_CODE_CHILD_SESSION",
            "CLAUDE_CODE_PARENT_SESSION_ID",
            "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_SSE_PORT",
        ] {
            #expect(recorded.contains("\(key)=<unset>"), Comment(rawValue: recorded))
        }
        #expect(recorded.contains("CLAUDE_CODE_USE_VERTEX=1"), Comment(rawValue: recorded))
    }

    private func runWithBoundedWait(
        _ process: Process,
        shellDescription: String,
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw TestFailure("\(shellDescription) did not exit within \(Int(timeout))s")
        }
        guard process.terminationStatus == 0 else {
            throw TestFailure("\(shellDescription) exited with status \(process.terminationStatus)")
        }
    }

    private func writeExecutable(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                let pathBuffer = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuffer, pointer, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        guard Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private func shellQuotedForTest(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
