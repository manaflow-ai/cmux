import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Process-detected launch commands
extension SocketListenerAcceptPolicyTests {
    func testProcessDetectedLaunchCommandFiltersEnvironmentAndOmitsCapturedAt() {
        let command = AgentLaunchCommandSnapshot(
            processDetectedLauncher: "opencode",
            executablePath: "/opt/homebrew/bin/opencode",
            arguments: ["/opt/homebrew/bin/opencode"],
            workingDirectory: "/tmp/repo",
            environment: [
                "OPENCODE_CONFIG_DIR": "/tmp/opencode config",
                "ANTHROPIC_BASE_URL": "https://api.example.test",
                "ANTHROPIC_API_KEY": "secret",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "PATH": "/tmp/bin:/usr/bin"
            ]
        )

        XCTAssertEqual(command.launcher, "opencode")
        XCTAssertEqual(command.environment?["OPENCODE_CONFIG_DIR"], "/tmp/opencode config")
        XCTAssertEqual(command.environment?["ANTHROPIC_BASE_URL"], "https://api.example.test")
        XCTAssertEqual(command.environment?["PATH"], "/tmp/bin:/usr/bin")
        XCTAssertNil(command.environment?["ANTHROPIC_API_KEY"])
        XCTAssertNil(command.environment?["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(command.capturedAt)
        XCTAssertEqual(command.source, "process")

        let nonOpenCodeCommand = AgentLaunchCommandSnapshot(
            processDetectedLauncher: "codex",
            executablePath: "codex",
            arguments: ["codex"],
            workingDirectory: nil,
            environment: ["CODEX_HOME": "/tmp/codex", "PATH": "/tmp/bin:/usr/bin"]
        )
        XCTAssertEqual(nonOpenCodeCommand.environment?["CODEX_HOME"], "/tmp/codex")
        XCTAssertNil(nonOpenCodeCommand.environment?["PATH"])

        let unsafeOnly = AgentLaunchCommandSnapshot(
            processDetectedLauncher: "opencode",
            executablePath: "opencode",
            arguments: ["opencode"],
            workingDirectory: nil,
            environment: ["ANTHROPIC_API_KEY": "secret"]
        )
        XCTAssertNil(unsafeOnly.environment)
        XCTAssertNil(unsafeOnly.capturedAt)
    }

    func testProcessDetectedOpenCodeRecognizesNodeWrapperAndNativeWorker() {
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/Users/lawrence/.bun/bin/opencode"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: ".opencode",
                processPath: "/Users/lawrence/.bun/install/global/node_modules/opencode-ai/bin/.opencode",
                arguments: ["/Users/lawrence/.bun/install/global/node_modules/opencode-ai/bin/.opencode"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "open-code",
                processPath: "/opt/homebrew/bin/open-code",
                arguments: ["open-code"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/opt/homebrew/bin/open-code"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/tmp/not-opencode-ai-helper"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: [
                    "node",
                    "/Users/lawrence/.bun/install/global/node_modules/opencode-ai/src/cli/cmd/tui/worker.js"
                ]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/Users/lawrence/.bun/bin/codex"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "tail",
                processPath: "/usr/bin/tail",
                arguments: ["tail", "-f", "/tmp/opencode"]
            )
        )
        XCTAssertFalse(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "/tmp/script.js", "/Users/lawrence/.bun/bin/opencode"]
            )
        )
        XCTAssertTrue(
            RestorableAgentSessionIndex.processLooksLikeOpenCode(
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                arguments: ["node", "--require", "/tmp/hook.js", "/Users/lawrence/.bun/bin/opencode"]
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeExecutablePathForProcess(
                arguments: ["node", "/Users/lawrence/.bun/bin/opencode"],
                environment: [:]
            ),
            "/Users/lawrence/.bun/bin/opencode"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeLaunchArgumentsForProcess(
                arguments: ["opencode", "run", "--session", "unsupported-session"],
                environment: [:]
            )
        )
    }

    func testProcessDetectedOpenCodeResolvesBareExecutableWithCapturedPath() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-path-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("opencode", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeExecutablePathForProcess(
                arguments: ["opencode"],
                environment: ["PATH": "\(bin.path):/usr/bin"]
            ),
            executable.path
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeExecutablePathForProcess(
                arguments: [".opencode"],
                environment: ["PATH": "\(bin.path):/usr/bin"]
            ),
            executable.path
        )
    }

    func testProcessDetectedOpenCodeWorkingDirectoryUsesProjectPositional() {
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeWorkingDirectoryForProcess(
                arguments: [
                    "opencode",
                    "--model",
                    "anthropic/claude-sonnet-4-6",
                    "/tmp/opencode-project"
                ],
                environment: ["PWD": "/tmp/shell-cwd"]
            ),
            "/tmp/opencode-project"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeWorkingDirectoryForProcess(
                arguments: [
                    "node",
                    "/Users/example/.bun/bin/opencode",
                    "../opencode-project"
                ],
                environment: ["PWD": "/tmp/shell-cwd/nested"]
            ),
            "/tmp/shell-cwd/opencode-project"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeWorkingDirectoryForProcess(
                arguments: ["opencode", "--session", "known-session"],
                environment: ["CMUX_AGENT_LAUNCH_CWD": "/tmp/hook-cwd", "PWD": "/tmp/shell-cwd"]
            ),
            "/tmp/hook-cwd"
        )
    }

    func testProcessDetectedOpenCodeLaunchArgumentsPreserveSafeForkContext() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-opencode-argv-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("opencode", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let arguments = try XCTUnwrap(RestorableAgentSessionIndex.openCodeLaunchArgumentsForProcess(
            arguments: [
                "node",
                "opencode",
                "--model",
                "anthropic/claude-sonnet-4-6",
                "--agent",
                "build",
                "--port",
                "4096",
                "--session",
                "old-session",
                "--prompt",
                "old prompt",
                "/tmp/opencode repo"
            ],
            environment: ["PATH": "\(bin.path):/usr/bin"]
        ))
        XCTAssertEqual(
            arguments,
            [
                executable.path,
                "--model",
                "anthropic/claude-sonnet-4-6",
                "--agent",
                "build",
                "--port",
                "4096",
                "/tmp/opencode repo"
            ]
        )

        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: "/tmp/opencode repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: executable.path,
                arguments: arguments,
                workingDirectory: "/tmp/opencode repo",
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )

        XCTAssertEqual(
            snapshot.forkCommand,
            "{ cd -- '/tmp/opencode repo' 2>/dev/null || [ ! -d '/tmp/opencode repo' ]; } && '\(executable.path)' '--session' 'opencode-session-123' '--fork' '--model' 'anthropic/claude-sonnet-4-6' '--agent' 'build' '--port' '4096' '/tmp/opencode repo'"
        )
    }

    func testProcessDetectedOpenCodeSessionFallbackAvoidsAmbiguousSameDirectoryPanels() {
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-explicit"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 2
            ),
            "ses-explicit"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-parent", "--fork"],
                latestSessionIdForSolePanel: "ses-child",
                sameWorkingDirectoryPanelCount: 1
            ),
            "ses-child"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--fork=ses-parent"],
                latestSessionIdForSolePanel: "ses-child",
                sameWorkingDirectoryPanelCount: 1
            ),
            "ses-child"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--fork=ses-parent"],
                latestSessionIdForSolePanel: "ses-parent",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-child", "--fork=ses-parent"],
                latestSessionIdForSolePanel: "ses-parent",
                sameWorkingDirectoryPanelCount: 1
            ),
            "ses-child"
        )
        XCTAssertEqual(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-child", "--fork=ses-parent"],
                latestSessionIdForSolePanel: nil,
                sameWorkingDirectoryPanelCount: 2
            ),
            "ses-child"
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-parent", "--fork"],
                latestSessionIdForSolePanel: nil,
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--session", "ses-parent", "--fork"],
                latestSessionIdForSolePanel: "ses-parent",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode", "--fork"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 1
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode"],
                latestSessionIdForSolePanel: "ses-latest",
                sameWorkingDirectoryPanelCount: 2
            )
        )
        XCTAssertNil(
            RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
                arguments: ["opencode"],
                latestSessionIdForSolePanel: nil,
                sameWorkingDirectoryPanelCount: 1
            )
        )
    }

    func testAntigravityProcessDetectionDoesNotTreatTrailingFlagAsConversationID() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let processId = 1_739_392_001
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: "agy",
                    path: "/usr/local/bin/agy",
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let registry = CmuxVaultAgentRegistry(registrations: [.builtInAntigravity])

        func detectedSnapshot(arguments: [String]) -> SessionRestorableAgentSnapshot? {
            RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: registry,
                fileManager: FileManager.default,
                processSnapshot: processSnapshot,
                capturedAt: 42,
                processArgumentsProvider: { requestedProcessId in
                    guard requestedProcessId == processId else { return nil }
                    return CmuxTopProcessArguments(
                        arguments: arguments,
                        environment: ["PWD": "/tmp/antigravity repo"]
                    )
                }
            )[panelKey]?.snapshot
        }

        XCTAssertNil(
            detectedSnapshot(arguments: ["/usr/local/bin/agy", "--conversation", "--sandbox", "danger-full-access"])
        )
        XCTAssertNil(
            detectedSnapshot(arguments: ["/usr/local/bin/agy", "--conversation=--sandbox"])
        )

        let validSnapshot = try XCTUnwrap(
            detectedSnapshot(arguments: ["/usr/local/bin/agy", "--conversation", "conversation-123", "--sandbox", "danger-full-access"])
        )
        XCTAssertEqual(validSnapshot.sessionId, "conversation-123")
        XCTAssertEqual(validSnapshot.workingDirectory, "/tmp/antigravity repo")
        XCTAssertEqual(validSnapshot.launchCommand?.launcher, "antigravity")
    }

}
