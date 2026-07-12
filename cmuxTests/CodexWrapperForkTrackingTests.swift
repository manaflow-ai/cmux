import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct CodexWrapperForkTrackingTests {
    @Test func resumedSessionForkRoutesThroughWrapperAndKeepsChildTracking() throws {
        let fileManager = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let wrapperURL = repoRoot.appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        #expect(
            fileManager.isExecutableFile(atPath: wrapperURL.path),
            "Bundled cmux-codex-wrapper must exist and be executable for fork tracking coverage"
        )
        guard fileManager.isExecutableFile(atPath: wrapperURL.path) else { return }

        let sandbox = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-codex-fork-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        let binDirectory = sandbox.appendingPathComponent("bin", isDirectory: true)
        let homeDirectory = sandbox.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let socketURL = sandbox.appendingPathComponent("cmux.sock", isDirectory: false)
        let socketDescriptor = try bindUnixSocket(at: socketURL.path)
        defer {
            Darwin.close(socketDescriptor)
            unlink(socketURL.path)
        }

        let argumentsURL = sandbox.appendingPathComponent("codex-arguments.bin", isDirectory: false)
        let environmentURL = sandbox.appendingPathComponent("codex-environment.txt", isDirectory: false)
        let realCodexURL = binDirectory.appendingPathComponent("custom-codex", isDirectory: false)
        try writeExecutable(
            realCodexURL,
            """
            #!/usr/bin/env bash
            printf '%s\\0' "$@" > "$TEST_CODEX_ARGUMENTS_FILE"
            {
              printf 'surface=%s\\n' "${CMUX_SURFACE_ID:-<unset>}"
              printf 'workspace=%s\\n' "${CMUX_WORKSPACE_ID:-<unset>}"
              printf 'launch_kind=%s\\n' "${CMUX_AGENT_LAUNCH_KIND:-<unset>}"
              printf 'launch_executable=%s\\n' "${CMUX_AGENT_LAUNCH_EXECUTABLE:-<unset>}"
              printf 'launch_argv_b64=%s\\n' "${CMUX_AGENT_LAUNCH_ARGV_B64:-<unset>}"
            } > "$TEST_CODEX_ENVIRONMENT_FILE"
            """
        )

        let fakeCmuxURL = binDirectory.appendingPathComponent("cmux", isDirectory: false)
        try writeExecutable(
            fakeCmuxURL,
            """
            #!/usr/bin/env bash
            if [[ "${1:-}" == "--socket" && "${3:-}" == "ping" ]]; then
              exit 0
            fi
            if [[ "${3:-}" == "hooks" && "${4:-}" == "codex" && "${5:-}" == "inject-args" ]]; then
              printf '%s\\0' '--enable' 'hooks' '--dangerously-bypass-hook-trust' '-c' 'hooks.SessionStart=test'
              exit 0
            fi
            exit 1
            """
        )

        let parentSessionID = "019f4f0d-38ed-7ec3-948b-49a9f58984f6"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: parentSessionID,
            workingDirectory: sandbox.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: realCodexURL.path,
                arguments: [realCodexURL.path, "resume", parentSessionID, "--model", "gpt-5.4"],
                workingDirectory: sandbox.path,
                environment: nil,
                capturedAt: 123,
                source: "environment"
            )
        )
        let forkCommand = try #require(snapshot.forkCommand)

        let surfaceID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", forkCommand]
        process.environment = [
            "PATH": "\(binDirectory.path):/usr/bin:/bin",
            "HOME": homeDirectory.path,
            "TMPDIR": sandbox.path,
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SOCKET_PATH": socketURL.path,
            "CMUX_BUNDLED_CLI_PATH": fakeCmuxURL.path,
            "CMUX_CODEX_WRAPPER_SHIM": wrapperURL.path,
            "TEST_CODEX_ARGUMENTS_FILE": argumentsURL.path,
            "TEST_CODEX_ENVIRONMENT_FILE": environmentURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let launchedArguments = try nulSeparatedStrings(in: argumentsURL)
        #expect(launchedArguments == [
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.SessionStart=test",
            "fork",
            parentSessionID,
            "--model",
            "gpt-5.4",
        ])

        let environment = try keyValueLines(in: environmentURL)
        #expect(environment["surface"] == surfaceID)
        #expect(environment["workspace"] == workspaceID)
        #expect(environment["launch_kind"] == "codex")
        #expect(environment["launch_executable"] == realCodexURL.path)
        let launchArguments = try decodeNulSeparatedBase64(environment["launch_argv_b64"])
        #expect(launchArguments == [realCodexURL.path, "fork", parentSessionID, "--model", "gpt-5.4"])
    }

    private func writeExecutable(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func nulSeparatedStrings(in url: URL) throws -> [String] {
        try decodeNulSeparatedData(Data(contentsOf: url))
    }

    private func decodeNulSeparatedBase64(_ value: String?) throws -> [String] {
        let value = try #require(value)
        let data = try #require(Data(base64Encoded: value))
        return try decodeNulSeparatedData(data)
    }

    private func decodeNulSeparatedData(_ data: Data) throws -> [String] {
        try data.split(separator: 0).map { bytes in
            try #require(String(data: Data(bytes), encoding: .utf8))
        }
    }

    private func keyValueLines(in url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: contents.split(separator: "\n").compactMap { line in
            guard let separator = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<separator]), String(line[line.index(after: separator)...]))
        })
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maximumPathLength else {
            Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                let pathBuffer = UnsafeMutableRawPointer(pathPointer).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuffer, pointer, maximumPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(descriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        guard Darwin.listen(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return descriptor
    }
}
