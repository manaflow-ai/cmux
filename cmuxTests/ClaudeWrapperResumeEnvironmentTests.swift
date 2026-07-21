import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

@Suite struct ClaudeWrapperResumeEnvironmentTests {
    @Test(arguments: ["cmux-claude-wrapper", "cmux-codex-wrapper"])
    func computerUseWrappersIgnoreAmbientSocketAndStateOverrides(wrapperName: String) throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sandbox = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-cua-scope-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        let wrapperDir = sandbox.appendingPathComponent("wrappers", isDirectory: true)
        let binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        let homeDir = sandbox.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let sourceWrapper = repoRoot.appendingPathComponent("Resources/bin/\(wrapperName)")
        let wrapperURL = wrapperDir.appendingPathComponent(wrapperName)
        try fileManager.copyItem(at: sourceWrapper, to: wrapperURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
        try writeExecutable(
            wrapperDir.appendingPathComponent("cmux-cua-driver"),
            "#!/usr/bin/env bash\nexit 99\n"
        )

        let agentName = wrapperName.contains("claude") ? "claude" : "codex"
        let recordURL = sandbox.appendingPathComponent("record.txt")
        let agentURL = binDir.appendingPathComponent(agentName)
        try writeExecutable(
            agentURL,
            """
            #!/usr/bin/env bash
            printf '%s\n' "$@" > \(shellQuotedForTest(recordURL.path))
            """
        )
        let fakeCmuxURL = binDir.appendingPathComponent("cmux")
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

        let socketURL = sandbox.appendingPathComponent("cmux.sock")
        let socketFD = try bindUnixSocket(at: socketURL.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketURL.path)
        }

        let process = Process()
        process.executableURL = wrapperURL
        process.arguments = ["--resume", "agent-session-123"]
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "HOME": homeDir.path,
            "TMPDIR": sandbox.path,
            "CMUX_TAG": "cua healing!!",
            "CMUX_SURFACE_ID": UUID().uuidString,
            "CMUX_SOCKET_PATH": socketURL.path,
            "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
            "CMUX_CLAUDE_SKIP_DEFAULTS": "1",
            "CMUX_CUSTOM_CLAUDE_PATH": agentURL.path,
            "CMUX_CUSTOM_CODEX_PATH": agentURL.path,
            "CMUX_CUA_SOCKET_PATH": "/tmp/hostile-default/cua-driver.sock",
            "CMUX_CUA_STATE_DIR": "/tmp/hostile-default/state",
            "CUA_DRIVER_DAEMON_APP": "/Applications/CuaDriver.app",
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_RS_MCP_NO_RELAUNCH": "1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: wrapperName)

        let recorded = try String(contentsOf: recordURL, encoding: .utf8)
        let uid = getuid()
        #expect(recorded.contains("/tmp/cmux-cua-\(uid)/cua-healing/cua.sock"), Comment(rawValue: recorded))
        #expect(recorded.contains("/computer-use/runtime/cua-healing/state"), Comment(rawValue: recorded))
        #expect(recorded.contains("CUA_DRIVER_RS_MCP_FORCE_PROXY"), Comment(rawValue: recorded))
        #expect(recorded.contains("CUA_DRIVER_DAEMON_APP"), Comment(rawValue: recorded))
        #expect(recorded.contains("CUA_DRIVER_EMBEDDED"), Comment(rawValue: recorded))
        #expect(recorded.contains("CUA_DRIVER_RS_MCP_NO_RELAUNCH"), Comment(rawValue: recorded))
        let valueSeparator = wrapperName.contains("claude") ? "\":\"" : "=\""
        #expect(recorded.contains("CUA_DRIVER_DAEMON_APP\(valueSeparator)\""), Comment(rawValue: recorded))
        #expect(recorded.contains("CUA_DRIVER_EMBEDDED\(valueSeparator)0\""), Comment(rawValue: recorded))
        #expect(recorded.contains("CUA_DRIVER_RS_MCP_NO_RELAUNCH\(valueSeparator)0\""), Comment(rawValue: recorded))
        #expect(!recorded.contains("hostile-default"), Comment(rawValue: recorded))
        #expect(!recorded.contains("/Applications/CuaDriver.app"), Comment(rawValue: recorded))
    }

    @Test func bundledClaudeWrapperScrubsSessionIdentityAndPreservesTrustBypassOnResume() throws {
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
        let environmentPolicy = ClaudeSessionEnvironmentPolicy()
        let sessionIdentityKeys = environmentPolicy.inheritedSessionIdentityKeys.sorted()
        let trustBypassKeys = environmentPolicy.inheritedTrustBypassKeys.sorted()
        let observedKeys = sessionIdentityKeys + trustBypassKeys
        try writeExecutable(
            binDir.appendingPathComponent("claude", isDirectory: false),
            """
            #!/usr/bin/env bash
            {
              printf 'argv=%s\\n' "$*"
              for key in \(observedKeys.joined(separator: " ")) CLAUDE_CODE_USE_VERTEX; do
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
        var environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "HOME": homeDir.path,
            "TMPDIR": sandbox.path,
            "CMUX_SURFACE_ID": UUID().uuidString,
            "CMUX_SOCKET_PATH": socketURL.path,
            "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
            "CLAUDE_CODE_USE_VERTEX": "1",
        ]
        for key in observedKeys {
            environment[key] = "inherited-parent-value"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runWithBoundedWait(process, shellDescription: "cmux-claude-wrapper --resume")

        let recorded = try String(contentsOf: recordURL, encoding: .utf8)
        #expect(recorded.contains("--settings"), Comment(rawValue: recorded))
        #expect(recorded.contains("--resume claude-session-123"), Comment(rawValue: recorded))
        for key in sessionIdentityKeys {
            #expect(recorded.contains("\(key)=<unset>"), Comment(rawValue: recorded))
        }
        for key in trustBypassKeys {
            #expect(recorded.contains("\(key)=inherited-parent-value"), Comment(rawValue: recorded))
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
