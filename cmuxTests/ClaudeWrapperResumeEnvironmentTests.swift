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
        #expect(recorded.contains("CMUX_AGENT_HOOK_CAPTURED_AT="), Comment(rawValue: recorded))
        #expect(recorded.contains("hooks claude stop"), Comment(rawValue: recorded))
        #expect(recorded.contains("hooks claude pre-tool-use"), Comment(rawValue: recorded))
        #expect(recorded.contains("--resume claude-session-123"), Comment(rawValue: recorded))
        for key in sessionIdentityKeys {
            #expect(recorded.contains("\(key)=<unset>"), Comment(rawValue: recorded))
        }
        for key in trustBypassKeys {
            #expect(recorded.contains("\(key)=inherited-parent-value"), Comment(rawValue: recorded))
        }
        #expect(recorded.contains("CLAUDE_CODE_USE_VERTEX=1"), Comment(rawValue: recorded))
    }

    @Test func claudeFallbackHookTimesIncreaseWithoutWaitingForLegacyClockLock() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let wrapperURL = repoRoot.appendingPathComponent("Resources/bin/cmux-claude-wrapper", isDirectory: false)
        let sandbox = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-claude-hook-time-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        let binDir = sandbox.appendingPathComponent("bin", isDirectory: true)
        let toolBin = sandbox.appendingPathComponent("hook-tools", isDirectory: true)
        let homeDir = sandbox.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: toolBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let socketURL = sandbox.appendingPathComponent("cmux.sock", isDirectory: false)
        let socketFD = try bindUnixSocket(at: socketURL.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketURL.path)
        }

        let argvURL = sandbox.appendingPathComponent("claude-argv.bin", isDirectory: false)
        try writeExecutable(
            binDir.appendingPathComponent("claude", isDirectory: false),
            """
            #!/usr/bin/env bash
            : "${CMUX_TEST_ARGV_PATH:?}"
            printf '%s\\0' "$@" > "$CMUX_TEST_ARGV_PATH"
            """
        )
        let capturedAtURL = sandbox.appendingPathComponent("captured-at.txt", isDirectory: false)
        let fakeCmuxURL = binDir.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutable(
            fakeCmuxURL,
            """
            #!/bin/sh
            if [ "${1:-}" = "--socket" ] && [ "${3:-}" = "ping" ]; then
              exit 0
            fi
            printf '%s\\n' "${CMUX_AGENT_HOOK_CAPTURED_AT:-}" >> "${CMUX_TEST_CAPTURED_AT:?}"
            """
        )

        let wrapper = Process()
        wrapper.executableURL = wrapperURL
        wrapper.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "HOME": homeDir.path,
            "TMPDIR": sandbox.path,
            "CMUX_SURFACE_ID": UUID().uuidString,
            "CMUX_SOCKET_PATH": socketURL.path,
            "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
            "CMUX_TEST_ARGV_PATH": argvURL.path,
            "CMUX_TEST_CAPTURED_AT": capturedAtURL.path,
        ]
        wrapper.standardInput = FileHandle.nullDevice
        wrapper.standardOutput = FileHandle.nullDevice
        wrapper.standardError = FileHandle.nullDevice
        try runWithBoundedWait(wrapper, shellDescription: "cmux-claude-wrapper settings capture")

        let argv = try Data(contentsOf: argvURL)
            .split(separator: 0)
            .compactMap { String(data: Data($0), encoding: .utf8) }
        let settingsIndex = try #require(argv.firstIndex(of: "--settings"))
        let settings = try #require(argv.indices.contains(settingsIndex + 1) ? argv[settingsIndex + 1] : nil)
        let settingsObject = try #require(
            JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any]
        )
        let hooks = try #require(settingsObject["hooks"] as? [String: Any])
        let preToolUseMatchers = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let cronCreatePreToolUse = try #require(
            preToolUseMatchers.first { ($0["matcher"] as? String) == "CronCreate" }
        )
        let cronCreateHooks = try #require(cronCreatePreToolUse["hooks"] as? [[String: Any]])
        let cronCreateGuard = try #require(cronCreateHooks.first {
            ($0["command"] as? String)?.contains("hooks claude cron-create-guard") == true
        })
        #expect(
            cronCreateGuard["async"] as? Bool != true,
            "CronCreate must wait for cmux to reject unsupported durable cron requests"
        )
        let ordinaryPreToolUse = try #require(
            preToolUseMatchers.first { ($0["matcher"] as? String) == "" }
        )
        let ordinaryPreToolUseHooks = try #require(ordinaryPreToolUse["hooks"] as? [[String: Any]])
        let statusHook = try #require(ordinaryPreToolUseHooks.first {
            ($0["command"] as? String)?.contains("hooks claude pre-tool-use") == true
        })
        #expect(
            statusHook["async"] as? Bool == true,
            "Ordinary tools must not wait for cmux's status bookkeeping"
        )
        let stopMatchers = try #require(hooks["Stop"] as? [[String: Any]])
        let stopHooks = try #require(stopMatchers.first?["hooks"] as? [[String: Any]])
        let command = try #require(stopHooks.first?["command"] as? String)
        try verifyAgentHookClockSamplesOnlyAfterLockAcquisition(
            commandBody: command,
            root: sandbox.appendingPathComponent("clock-lock-order", isDirectory: true)
        )

        for (tool, target) in [
            ("chmod", "/bin/chmod"),
            ("mkdir", "/bin/mkdir"),
            ("mktemp", "/usr/bin/mktemp"),
            ("mv", "/bin/mv"),
            ("printenv", "/usr/bin/printenv"),
            ("rm", "/bin/rm"),
            ("rmdir", "/bin/rmdir"),
            ("sleep", "/bin/sleep"),
        ] {
            try fileManager.createSymbolicLink(
                at: toolBin.appendingPathComponent(tool, isDirectory: false),
                withDestinationURL: URL(fileURLWithPath: target)
            )
        }
        let fakeDateURL = toolBin.appendingPathComponent("date", isDirectory: false)
        try writeExecutable(fakeDateURL, "#!/bin/sh\nprintf '1699999999\\n'\n")
        let monotonicClockDirectory = sandbox.appendingPathComponent("cmux-agent-hook-clock-v2", isDirectory: true)
        let monotonicClockState = monotonicClockDirectory.appendingPathComponent("state", isDirectory: false)
        let seededMicros: Int64 = 1_700_000_000_123_456
        try fileManager.createDirectory(at: monotonicClockDirectory, withIntermediateDirectories: false)
        try "\(seededMicros)\n".write(to: monotonicClockState, atomically: true, encoding: .utf8)
        let clockStateURL = sandbox.appendingPathComponent("cmux-agent-hook-time.state", isDirectory: false)
        let clockStateVictimURL = sandbox.appendingPathComponent("clock-state-victim.txt", isDirectory: false)
        try "1700000000 0\n".write(to: clockStateVictimURL, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: clockStateURL, withDestinationURL: clockStateVictimURL)
        let legacyLockURL = sandbox.appendingPathComponent("cmux-agent-hook-time.lock", isDirectory: true)
        try fileManager.createDirectory(at: legacyLockURL, withIntermediateDirectories: false)
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: legacyLockURL.appendingPathComponent("owner"),
            atomically: true,
            encoding: .utf8
        )
        try "1699999999\n".write(
            to: legacyLockURL.appendingPathComponent("started"),
            atomically: true,
            encoding: .utf8
        )

        let hook = Process()
        hook.executableURL = URL(fileURLWithPath: "/bin/sh")
        hook.arguments = ["-c", Array(repeating: command, count: 4).joined(separator: "; ")]
        hook.environment = [
            "PATH": toolBin.path,
            "TMPDIR": sandbox.path,
            "CMUX_AGENT_HOOK_DATE_BIN": fakeDateURL.path,
            "CMUX_CLAUDE_HOOK_CMUX_BIN": fakeCmuxURL.path,
            "CMUX_TEST_CAPTURED_AT": capturedAtURL.path,
        ]
        hook.standardInput = FileHandle.nullDevice
        hook.standardOutput = FileHandle.nullDevice
        hook.standardError = FileHandle.nullDevice
        try runWithBoundedWait(hook, shellDescription: "Claude fallback hook timestamps", timeout: 1)

        #expect(try String(contentsOf: clockStateVictimURL, encoding: .utf8) == "1700000000 0\n")
        #expect(try clockStateURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(fileManager.fileExists(atPath: legacyLockURL.path))

        let rawTimes = try String(contentsOf: capturedAtURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(rawTimes.count == 4)
        let times = try rawTimes.map { try #require(Double($0)) }
        #expect(times.allSatisfy { $0.isFinite && $0 > 0 })
        let maximumAcceptedCaptureTime = Date().timeIntervalSince1970 + 5 * 60
        #expect(
            times.allSatisfy { $0 <= maximumAcceptedCaptureTime },
            "A poisoned future clock state must not become the emitted ordering watermark"
        )
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(earlier < later, Comment(rawValue: rawTimes.joined(separator: ",")))
        }

        try fileManager.removeItem(at: monotonicClockDirectory)
        let attackerClockDirectory = sandbox.appendingPathComponent("attacker-clock", isDirectory: true)
        let attackerClockState = attackerClockDirectory.appendingPathComponent("state", isDirectory: false)
        try fileManager.createDirectory(at: attackerClockDirectory, withIntermediateDirectories: false)
        try "\(seededMicros)\n".write(to: attackerClockState, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: monotonicClockDirectory,
            withDestinationURL: attackerClockDirectory
        )

        let untrustedClockHook = Process()
        untrustedClockHook.executableURL = URL(fileURLWithPath: "/bin/sh")
        untrustedClockHook.arguments = ["-c", command]
        untrustedClockHook.environment = [
            "PATH": toolBin.path,
            "TMPDIR": sandbox.path,
            "CMUX_AGENT_HOOK_DATE_BIN": fakeDateURL.path,
            "CMUX_CLAUDE_HOOK_CMUX_BIN": fakeCmuxURL.path,
            "CMUX_TEST_CAPTURED_AT": capturedAtURL.path,
        ]
        untrustedClockHook.standardInput = FileHandle.nullDevice
        untrustedClockHook.standardOutput = FileHandle.nullDevice
        untrustedClockHook.standardError = FileHandle.nullDevice
        try runWithBoundedWait(untrustedClockHook, shellDescription: "Claude untrusted clock fallback", timeout: 1)

        let capturedTimes = try String(contentsOf: capturedAtURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(capturedTimes.count == 5)
        #expect(capturedTimes.last == "1699999999.000000", Comment(rawValue: capturedTimes.joined(separator: ",")))
        #expect(try String(contentsOf: attackerClockState, encoding: .utf8) == "\(seededMicros)\n")
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
