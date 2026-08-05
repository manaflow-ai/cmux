import AppKit
import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentConversationTransferSourceTests {
    @Test(arguments: [RestorableAgentKind.rovodev, .antigravity])
    func localTranscriptSourceDoesNotRequireNativeForkCapability(
        kind: RestorableAgentKind
    ) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("history.jsonl")
        try Data(#"{"sessionId":"transfer-session","display":"continue"}"#.utf8)
            .write(to: transcript)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: "transfer-session",
            transcriptPath: transcript.path
        )
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)

        let transferSelection = workspace.agentConversationForkSelection(
            forPanelId: panelId,
            request: .init(targetHarness: .claude, destination: .right)
        )
        let nativeSelection = workspace.agentConversationForkSelection(
            forPanelId: panelId,
            request: .init(targetHarness: .current, destination: .right)
        )

        #expect(snapshot.forkCommand == nil)
        #expect(transferSelection?.snapshot.sessionId == snapshot.sessionId)
        #expect(transferSelection?.requiresNativeForkCapability == false)
        #expect(nativeSelection == nil)
        #expect(
            workspace.forkAgentConversationContextMenuAvailability(forPanelId: panelId)
                == .unsupported
        )
    }

    @Test
    func remoteTranscriptSourceDoesNotOfferCrossHarnessTransfer() throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .rovodev,
            sessionId: "remote-rovo",
            transcriptPath: "/tmp/remote-rovo.json"
        )
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)
        workspace.trackRemoteTerminalSurface(panelId)

        #expect(workspace.agentConversationTransferSnapshot(forPanelId: panelId) == nil)
        #expect(workspace.agentConversationForkSelection(
            forPanelId: panelId,
            request: .init(targetHarness: .claude, destination: .right)
        ) == nil)
    }

    @Test
    func commandPaletteHarnessChoicesLeaveCurrentHarnessToNativeCommands() throws {
        let targetHarnesses = AgentConversationForkRequest.TargetHarness.allCases.filter { $0 != .current }
        let harnessArgument = try #require(
            AgentConversationForkRequest.commandPaletteChoiceArguments(
                targetHarnesses: targetHarnesses
            ).first {
                $0.name == AgentConversationForkRequest.harnessArgumentName
            }
        )

        #expect(!harnessArgument.choices.contains { $0.value == "current" })
        #expect(Set(harnessArgument.choices.map(\.value)) == Set(targetHarnesses.map(\.rawValue)))
    }

    @Test
    func installedHarnessCatalogUsesProviderAndExecutableCapabilities() {
        let installedProviders: Set<AgentSessionProviderID> = [.codex, .opencode]
        let installedExecutables = Set(["gemini", "hermes"])

        let harnesses = AgentConversationForkRequest.TargetHarness.installedCases(
            providerInstalled: { installedProviders.contains($0) },
            executableInstalled: { names in !installedExecutables.isDisjoint(with: names) }
        )

        #expect(harnesses == [.codex, .opencode, .gemini, .hermesAgent])
    }

    @Test
    func advertisedHarnessChoiceFallsBackWhenNativeProbeIsRejected() async throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "rejected-native-session",
            launchCommand: AgentLaunchCommandSnapshot(
                processDetectedLauncher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--session",
                    "rejected-native-session",
                ],
                workingDirectory: nil,
                environment: ["HOME": home.path]
            )
        )
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)
        let liveAgentIndex = SharedLiveAgentIndex(
            forkSupportProvider: { _, _ in false },
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )
        await liveAgentIndex.refreshForkAvailabilityNow(
            workspaceId: workspace.id,
            panelId: panelId,
            fallbackSnapshot: snapshot
        )
        let targetHarnesses = AgentConversationForkRequest.TargetHarness.allCases.filter { $0 != .current }
        let harnessArgument = try #require(
            AgentConversationForkRequest.commandPaletteChoiceArguments(
                targetHarnesses: targetHarnesses
            ).first {
                $0.name == AgentConversationForkRequest.harnessArgumentName
            }
        )

        for choice in harnessArgument.choices {
            let target = try #require(
                AgentConversationForkRequest.TargetHarness(rawValue: choice.value)
            )
            let selection = workspace.agentConversationForkSelection(
                forPanelId: panelId,
                request: .init(targetHarness: target, destination: .right),
                liveAgentIndex: liveAgentIndex
            )
            #expect(selection != nil, "Advertised harness \(choice.value) must remain actionable")
            if target == .opencode {
                #expect(selection?.requiresNativeForkCapability == false)
            }
        }
    }

    @Test
    func actionableTargetsOfferSameHarnessWhenNativeProbeIsUnavailable() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "context-menu-transfer-session",
            launchCommand: AgentLaunchCommandSnapshot(
                processDetectedLauncher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--session",
                    "context-menu-transfer-session",
                ],
                workingDirectory: nil,
                environment: ["HOME": home.path]
            )
        )
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelID)

        let targets = workspace.actionableAgentConversationForkTargets(
            forPanelId: panelID,
            liveAgentIndex: .shared,
            targets: [.canonical(.opencode)]
        )

        #expect(targets.map(\.harness) == [.opencode])
    }

    @Test
    func installedTargetDiscoveryRetainsConfiguredProviderExecutable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("custom claude")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let targets = AgentConversationForkTargetDiscoverer(
            environment: ["HOME": root.path, "PATH": ""],
            defaultHomeDirectory: root.path,
            bundleResourcePath: nil,
            configuredExecutablePaths: [.claude: executable.path],
            includeStandardSearchDirectories: false
        ).discover()

        let target = try #require(targets.first)
        #expect(targets.count == 1)
        #expect(target.harness == .claude)
        #expect(target.executablePath == executable.path)
        #expect(target.runtimeSearchPath?.split(separator: ":").first == Substring(root.path))
    }

    @Test
    func installedTargetDiscoveryRetainsExecutableAliasPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("cbc")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let targets = AgentConversationForkTargetDiscoverer(
            environment: ["HOME": root.path, "PATH": bin.path],
            defaultHomeDirectory: root.path,
            bundleResourcePath: nil,
            configuredExecutablePaths: [:],
            includeStandardSearchDirectories: false
        ).discover()

        let target = try #require(targets.first)
        #expect(targets.count == 1)
        #expect(target.harness == .codebuddy)
        #expect(target.executablePath == executable.path)
        #expect(target.runtimeSearchPath?.split(separator: ":").first == Substring(bin.path))
    }

    @Test(arguments: ["qodercli", "kimi"])
    func installedTargetDiscoveryOmitsHarnessWithoutInteractiveSeed(
        executableName: String
    ) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(executableName)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let targets = AgentConversationForkTargetDiscoverer(
            environment: ["HOME": root.path, "PATH": root.path],
            defaultHomeDirectory: root.path,
            bundleResourcePath: nil,
            configuredExecutablePaths: [:],
            includeStandardSearchDirectories: false
        ).discover()

        #expect(targets.isEmpty)
    }

    @Test
    func resolvedTargetPathSurvivesIntoStartupCommand() throws {
        let target = AgentConversationForkTarget(
            harness: .claude,
            executablePath: "/tmp/Custom Tools/claude",
            runtimeSearchPath: "/tmp/Custom Tools:/usr/bin"
        )
        let command = try #require(target.startupCommand(handoffMessage: "User: keep context"))

        #expect(command.hasPrefix("/usr/bin/env 'PATH=/tmp/Custom Tools:/usr/bin' "))
        #expect(command.contains("'CMUX_CUSTOM_CLAUDE_PATH=/tmp/Custom Tools/claude'"))
        #expect(command.contains(AgentResumeArgv.claudeWrapperShellExecutableToken))
        #expect(command.contains("User: keep context"))
    }

    @Test
    func targetCatalogRefreshesInstalledExecutableChanges() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let discoverer = AgentConversationForkTargetDiscoverer(
            environment: ["HOME": root.path, "PATH": root.path],
            defaultHomeDirectory: root.path,
            bundleResourcePath: nil,
            configuredExecutablePaths: [:],
            includeStandardSearchDirectories: false
        )
        let catalog = AgentConversationForkTargetCatalog(
            minimumRefreshInterval: 0,
            discovery: { discoverer.discover() }
        )

        await catalog.refresh(force: true)
        let target = try #require(catalog.installedTargets.first)
        #expect(catalog.installedTargets.count == 1)
        #expect(target.harness == .codex)
        #expect(target.executablePath == executable.path)
        #expect(target.runtimeSearchPath?.split(separator: ":").first == Substring(root.path))

        try FileManager.default.removeItem(at: executable)
        await catalog.refresh(force: true)

        #expect(catalog.installedTargets.isEmpty)
    }

    @Test(arguments: [RestorableAgentKind.opencode, .hermesAgent])
    func providerWithoutCapturedStorageIdentityIsNotTransferable(
        kind: RestorableAgentKind
    ) throws {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: "uncaptured-provider-session"
        )
        let source = AgentConversationSource(snapshot: snapshot)
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: panelId)

        #expect(!source.hasDeterministicTranscriptSource)
        #expect(
            workspace.agentConversationForkSelection(
                forPanelId: panelId,
                request: .init(targetHarness: .claude, destination: .right)
            ) == nil
        )
    }

    @Test
    func inferredOpenCodeSessionIdentityIsNotTransferable() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspaceId = UUID()
        let panelId = UUID()
        let key = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "heuristic-latest-session",
            launchCommand: AgentLaunchCommandSnapshot(
                processDetectedLauncher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "--session",
                    "parent-session",
                    "--fork",
                ],
                workingDirectory: nil,
                environment: ["HOME": home.path]
            )
        )
        func loadedSnapshot(
            source: RestorableAgentSessionIndex.ProcessDetectedSessionIDSource
        ) throws -> SessionRestorableAgentSnapshot {
            let index = RestorableAgentSessionIndex.load(
                homeDirectory: home.path,
                fileManager: .default,
                registry: CmuxVaultAgentRegistry(registrations: []),
                detectedSnapshots: [
                    key: (
                        snapshot: detectedSnapshot,
                        updatedAt: 123,
                        processIDs: [4_321],
                        agentProcessIDs: [4_321],
                        sessionIDSource: source
                    ),
                ],
                processArgumentsProvider: { _ in nil },
                processPresenceProvider: { _ in .absent },
                processIdentityProvider: { _ in nil }
            )
            return try #require(index.snapshot(
                workspaceId: workspaceId,
                panelId: panelId
            ))
        }

        let inferredSnapshot = try loadedSnapshot(source: .inferredLatestSessionFile)
        let explicitSnapshot = try loadedSnapshot(source: .explicit)
        #expect(
            inferredSnapshot.sessionIDProvenance == .inferredLatestSessionFile
        )
        #expect(!AgentConversationSource(
            snapshot: inferredSnapshot
        ).hasDeterministicTranscriptSource)
        #expect(explicitSnapshot.sessionIDProvenance == .authoritative)
        #expect(AgentConversationSource(
            snapshot: explicitSnapshot
        ).hasDeterministicTranscriptSource)

        let workspace = Workspace()
        let focusedPanelId = try #require(workspace.focusedPanelId)
        workspace.setRestoredAgentSnapshotForTesting(
            inferredSnapshot,
            panelId: focusedPanelId
        )
        #expect(workspace.agentConversationForkSelection(
            forPanelId: focusedPanelId,
            request: .init(targetHarness: .claude, destination: .right)
        ) == nil)
    }

    @Test
    func legacyOpenCodeSnapshotWithoutProvenanceIsNotTransferable() throws {
        let currentSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "legacy-session",
            launchCommand: AgentLaunchCommandSnapshot(
                processDetectedLauncher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode", "--session", "legacy-session"],
                workingDirectory: nil,
                environment: ["HOME": "/tmp/legacy-opencode-home"]
            )
        )
        let encoded = try JSONEncoder().encode(currentSnapshot)
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "sessionIDProvenance")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacySnapshot = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: legacyData
        )

        #expect(legacySnapshot.sessionIDProvenance == nil)
        #expect(!AgentConversationSource(
            snapshot: legacySnapshot
        ).hasDeterministicTranscriptSource)
    }

    @Test(arguments: ["hermes", "hermes-agent"])
    func processDetectedHermesCapturesHomeWithoutReplayingIt(
        launcher: String
    ) throws {
        let command = AgentLaunchCommandSnapshot(
            processDetectedLauncher: launcher,
            executablePath: "/opt/homebrew/bin/hermes",
            arguments: ["/opt/homebrew/bin/hermes"],
            workingDirectory: nil,
            environment: ["HOME": "/tmp/captured-hermes-home"]
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "process-detected-hermes",
            launchCommand: command
        )
        let source = AgentConversationSource(snapshot: snapshot)
        let replayEnvironment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: command.environment ?? [:],
            kind: RestorableAgentKind.hermesAgent.rawValue
        )

        #expect(command.environment?["HOME"] == "/tmp/captured-hermes-home")
        #expect(
            source.hermesStateDatabaseURL?.path
                == "/tmp/captured-hermes-home/.hermes/state.db"
        )
        #expect(source.hasDeterministicTranscriptSource)
        #expect(replayEnvironment["HOME"] == nil)
    }

    @Test
    func hermesTransferUsesCapturedHermesHome() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.db")
        try makeHermesStateDatabase(at: databaseURL)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "captured-home-session",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes",
                executablePath: "/opt/homebrew/bin/hermes",
                arguments: ["/opt/homebrew/bin/hermes", "--resume", "captured-home-session"],
                workingDirectory: nil,
                environment: ["HERMES_HOME": directory.path],
                capturedAt: 123,
                source: "process"
            )
        )
        let source = AgentConversationSource(snapshot: snapshot)

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .right
        ).startupCommandOverride(sourceSnapshot: snapshot))

        #expect(source.hermesStateDatabaseURL == databaseURL)
        #expect(command.contains("custom Hermes home request"))
        #expect(command.contains("custom Hermes home response"))
    }

    @Test
    func hermesTransferBudgetsLatestDialogueAfterTrailingToolRows() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.db")
        try makeHermesStateDatabase(
            at: databaseURL,
            trailingToolRowCount: 1_001
        )

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .hermesAgent,
            sessionId: "captured-home-session",
            fileURL: nil,
            hermesStateDatabaseURL: databaseURL,
            retention: .transferOpeningUserAndLatest(
                turnLimit: 2,
                textByteLimit: 32 * 1_024
            )
        ))

        #expect(turns.map(\.text) == [
            "custom Hermes home request",
            "custom Hermes home response",
        ])
    }

    @Test
    func openCodeTransferUsesCapturedXDGDataHome() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataHome = directory.appendingPathComponent("custom-data", isDirectory: true)
        let databaseDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = databaseDirectory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(at: databaseURL)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "captured-opencode-session",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: nil,
                environment: [
                    "HOME": directory.appendingPathComponent("ignored-home").path,
                    "XDG_DATA_HOME": dataHome.path,
                ],
                capturedAt: 123,
                source: "process"
            )
        )
        let source = AgentConversationSource(snapshot: snapshot)

        let command = try #require(try await AgentConversationForkRequest(
            targetHarness: .claude,
            destination: .right
        ).startupCommandOverride(sourceSnapshot: snapshot))

        #expect(source.openCodeDatabasePath == databaseURL.path)
        #expect(command.contains("custom OpenCode home request"))
        #expect(command.contains("custom OpenCode home response"))
    }

    @Test
    func transferRetentionBoundsManyLargeConsecutiveTurnsBeforeCoalescing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("large-claude.jsonl")
        var records = [
            #"{"type":"user","message":{"role":"user","content":"opening request"}}"#
        ]
        records.append(contentsOf: (0..<220).map { index in
            let suffix = index == 219 ? "-LATEST-MARKER" : ""
            let text = "assistant-\(index)-" + String(repeating: "x", count: 4_096) + suffix
            return #"{"type":"assistant","message":{"role":"assistant","content":"\#(text)"}}"#
        })
        try records.joined(separator: "\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        let byteLimit = 32 * 1_024

        let turns = try await SessionTranscriptLoader.load(source: .init(
            agent: .claude,
            sessionId: "large-session",
            fileURL: transcript,
            retention: .transferOpeningUserAndLatest(
                turnLimit: 1_000,
                textByteLimit: byteLimit
            )
        ))

        #expect(turns.first?.text.contains("opening request") == true)
        #expect(turns.last?.text.contains("LATEST-MARKER") == true)
        #expect(turns.count == 2)
        #expect(turns.reduce(0) { $0 + $1.text.utf8.count } <= byteLimit)
    }

    @Test
    func smallCrossHarnessSeedUsesPrivateSelfDeletingLauncher() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = SessionRestorableAgentSnapshot(kind: .codex, sessionId: "small-session")
        let command = "claude 'small private transfer prompt'"

        let input = try #require(snapshot.customStartupInput(
            command: command,
            temporaryDirectory: directory
        ))
        let prefix = " /bin/zsh '"
        let scriptPath = String(input.dropFirst(prefix.count).dropLast(2))
        let contents = try String(contentsOfFile: scriptPath, encoding: .utf8)

        #expect(input.hasPrefix(prefix))
        #expect(!input.contains("small private transfer prompt"))
        #expect(contents.contains("rm -f -- \"$0\""))
        #expect(contents.contains(command))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-conversation-transfer-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHermesStateDatabase(
        at url: URL,
        trailingToolRowCount: Int = 0
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let trailingToolRows = (0..<trailingToolRowCount)
            .map { index in
                "('captured-home-session', 'tool', 'tool output \(index)', NULL, 'terminal', \(index + 3))"
            }
            .joined(separator: ",\n")
        let trailingToolInsert = trailingToolRows.isEmpty
            ? ""
            : """
            INSERT INTO messages (session_id, role, content, tool_calls, tool_name, timestamp)
            VALUES
            \(trailingToolRows);
            """
        let sql = """
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_calls TEXT,
          tool_name TEXT,
          timestamp REAL NOT NULL
        );
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('captured-home-session', 'user', 'custom Hermes home request', 1),
          ('captured-home-session', 'assistant', 'custom Hermes home response', 2);
        \(trailingToolInsert)
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }

    private func makeOpenCodeDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql = #"""
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO message VALUES ('m1', 'captured-opencode-session', 1, '{"role":"user"}');
        INSERT INTO message VALUES ('m2', 'captured-opencode-session', 2, '{"role":"assistant"}');
        INSERT INTO part VALUES ('p1', 'm1', 1, '{"type":"text","text":"custom OpenCode home request"}');
        INSERT INTO part VALUES ('p2', 'm2', 2, '{"type":"text","text":"custom OpenCode home response"}');
        """#
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }
}

private enum FixtureError: Error {
    case sqlite
}
