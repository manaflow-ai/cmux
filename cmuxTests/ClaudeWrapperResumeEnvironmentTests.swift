import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

@Suite struct ClaudeWrapperResumeEnvironmentTests {
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

    @Test func bundledClaudeWrapperElectsOneNativeAutoUpdaterLeader() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let wrapperURL = repoRoot.appendingPathComponent("Resources/bin/cmux-claude-wrapper", isDirectory: false)
        #expect(
            fileManager.isExecutableFile(atPath: wrapperURL.path),
            "Bundled cmux-claude-wrapper must exist and be executable for updater coordination coverage"
        )
        guard fileManager.isExecutableFile(atPath: wrapperURL.path) else { return }

        let sandbox = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-updater-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        let binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        let homeDir = sandbox.appendingPathComponent("home", isDirectory: true)
        let nativeBinDir = homeDir.appendingPathComponent(".local/bin", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nativeBinDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let socketURL = sandbox.appendingPathComponent("cmux.sock", isDirectory: false)
        let socketFD = try bindUnixSocket(at: socketURL.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketURL.path)
        }

        try writeExecutable(
            nativeBinDir.appendingPathComponent("claude", isDirectory: false),
            """
            #!/usr/bin/env bash
            {
              printf 'argv=%s\\n' "$*"
              printf 'disableAutoUpdater=%s\\n' "${DISABLE_AUTOUPDATER-<unset>}"
              printf 'forcePluginUpdates=%s\\n' "${FORCE_AUTOUPDATE_PLUGINS-<unset>}"
              printf 'launchKind=%s\\n' "${CMUX_AGENT_LAUNCH_KIND-<unset>}"
              printf 'nodeOptions=%s\\n' "${NODE_OPTIONS-<unset>}"
            } > "${CMUX_TEST_RECORD:?}"
            if [[ -n "${CMUX_TEST_RELEASE:-}" ]]; then
              while [[ ! -e "$CMUX_TEST_RELEASE" ]]; do
                sleep 0.05
              done
            fi
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

        func wrapperProcess(recordURL: URL, releaseURL: URL? = nil) -> Process {
            let process = Process()
            process.executableURL = wrapperURL
            var environment = [
                "PATH": "\(nativeBinDir.path):\(binDir.path):/usr/bin:/bin",
                "HOME": homeDir.path,
                "TMPDIR": sandbox.path,
                "CMUX_SURFACE_ID": UUID().uuidString,
                "CMUX_SOCKET_PATH": socketURL.path,
                "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
                "CMUX_TEST_RECORD": recordURL.path,
            ]
            if let releaseURL {
                environment["CMUX_TEST_RELEASE"] = releaseURL.path
            }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }

        let leaderRecordURL = sandbox.appendingPathComponent("leader.txt", isDirectory: false)
        let followerRecordURL = sandbox.appendingPathComponent("follower.txt", isDirectory: false)
        let successorRecordURL = sandbox.appendingPathComponent("successor.txt", isDirectory: false)
        let releaseURL = sandbox.appendingPathComponent("release-leader", isDirectory: false)

        let leader = wrapperProcess(recordURL: leaderRecordURL, releaseURL: releaseURL)
        try leader.run()
        defer {
            try? Data().write(to: releaseURL)
            if leader.isRunning {
                leader.terminate()
            }
        }
        try waitForFile(leaderRecordURL, description: "updater leader environment")

        let leaderRecord = try String(contentsOf: leaderRecordURL, encoding: .utf8)
        #expect(leaderRecord.contains("disableAutoUpdater=<unset>"), Comment(rawValue: leaderRecord))
        #expect(leaderRecord.contains("--settings"), Comment(rawValue: leaderRecord))
        #expect(leaderRecord.contains("launchKind=claude"), Comment(rawValue: leaderRecord))
        #expect(leaderRecord.contains("--max-old-space-size=4096"), Comment(rawValue: leaderRecord))

        let follower = wrapperProcess(recordURL: followerRecordURL)
        try runWithBoundedWait(follower, shellDescription: "second cmux-claude-wrapper launch")
        let followerRecord = try String(contentsOf: followerRecordURL, encoding: .utf8)
        #expect(followerRecord.contains("disableAutoUpdater=1"), Comment(rawValue: followerRecord))
        #expect(followerRecord.contains("forcePluginUpdates=1"), Comment(rawValue: followerRecord))
        #expect(followerRecord.contains("--settings"), Comment(rawValue: followerRecord))
        #expect(followerRecord.contains("launchKind=claude"), Comment(rawValue: followerRecord))
        #expect(followerRecord.contains("--max-old-space-size=4096"), Comment(rawValue: followerRecord))

        try Data().write(to: releaseURL)
        try waitForExit(leader, description: "updater leader")

        let successor = wrapperProcess(recordURL: successorRecordURL)
        try runWithBoundedWait(successor, shellDescription: "successor cmux-claude-wrapper launch")
        let successorRecord = try String(contentsOf: successorRecordURL, encoding: .utf8)
        #expect(successorRecord.contains("disableAutoUpdater=<unset>"), Comment(rawValue: successorRecord))
        #expect(successorRecord.contains("forcePluginUpdates=<unset>"), Comment(rawValue: successorRecord))
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

    private func waitForFile(
        _ url: URL,
        description: String,
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TestFailure("\(description) was not written within \(Int(timeout))s")
        }
    }

    private func waitForExit(
        _ process: Process,
        description: String,
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw TestFailure("\(description) did not exit within \(Int(timeout))s")
        }
        guard process.terminationStatus == 0 else {
            throw TestFailure("\(description) exited with status \(process.terminationStatus)")
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
