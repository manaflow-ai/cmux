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

@Suite("Hermes first-class support")
struct HermesFirstClassSupportTests {
    private struct StateRow {
        let id: String
        let cwd: String?
        let source: String
        let startedAt: Double
        let endedAt: Double?

        init(
            _ id: String,
            cwd: String?,
            source: String = "cli",
            startedAt: Double = 10,
            endedAt: Double? = nil
        ) {
            self.id = id
            self.cwd = cwd
            self.source = source
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    @Test("A bare Hermes process does not claim an uncorrelated active state.db session")
    func bareProcessRejectsUncorrelatedActiveSession() throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("ended-newer", cwd: repo.path, startedAt: 30, endedAt: 40),
                StateRow("live-session", cwd: repo.path, source: "tui", startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_520, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_520: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--tui"],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.isEmpty)
    }

    @Test("The installed Python Hermes launcher remains live and restores through cmux")
    func installedPythonLauncherRemainsRestorable() throws {
        let fixture = try makeFixture { [StateRow("python-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pythonExecutable = fixture.hermesHome
            .appendingPathComponent("hermes-agent/venv/bin/python", isDirectory: false)
            .path
        let hermesEntrypoint = fixture.hermesHome
            .appendingPathComponent("hermes-agent/hermes", isDirectory: false)
            .path
        let process = hermesProcess(
            pid: 9_527,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID,
            name: "Python",
            path: pythonExecutable
        )

        let liveProcess = CmuxTopProcessArguments(
            arguments: [pythonExecutable, hermesEntrypoint, "--resume", "python-session", "--tui"],
            environment: hermesEnvironment(fixture)
        )
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [process.pid: liveProcess]
        )

        let snapshot = try #require(detected.values.first?.snapshot)
        #expect(snapshot.kind == .hermesAgent)
        #expect(snapshot.sessionId == "python-session")
        #expect(snapshot.launchCommand?.executablePath == "hermes")
        #expect(snapshot.launchCommand?.arguments == ["hermes", "--resume", "python-session", "--tui"])
        #expect(snapshot.resumeStartupInput() == " cmux restore hermes-agent python-session\n")
        #expect(CachedAgentProcessIdentityValidator().currentProcess(liveProcess, matches: snapshot))
    }

    @Test(
        "Python-backed Hermes management commands are detected but never restored",
        arguments: ["gateway", "doctor", "update"]
    )
    func installedPythonManagementCommandsAreNotRestorable(command: String) throws {
        let fixture = try makeFixture { [StateRow("management-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pythonExecutable = fixture.hermesHome
            .appendingPathComponent("hermes-agent/venv/bin/python", isDirectory: false)
            .path
        let hermesEntrypoint = fixture.hermesHome
            .appendingPathComponent("hermes-agent/hermes", isDirectory: false)
            .path
        let process = hermesProcess(
            pid: 9_528,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID,
            name: "Python",
            path: pythonExecutable
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [pythonExecutable, hermesEntrypoint, command],
            environment: hermesEnvironment(fixture)
        )
        let observed = VaultObservedAgentProcess(
            processName: process.name,
            processPath: process.path,
            arguments: liveProcess.arguments,
            environment: liveProcess.environment
        )
        let registration = CmuxVaultAgentRegistration.builtInHermes

        #expect(registration.detect.matches(observed))
        #expect(registration.processDetectedSnapshotIsRestorable(for: observed) == false)
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [process.pid: liveProcess]
        )
        #expect(detected.isEmpty)
    }

    @Test(
        "Hermes one-shot commands are detected but never restored",
        arguments: [
            ["-z", "report status"],
            ["-zreport status"],
            ["--oneshot", "report status"],
            ["--oneshot=report status"],
            ["chat", "-q", "report status"],
            ["chat", "-qreport status"],
            ["chat", "--query", "report status"],
            ["chat", "--query=report status"],
        ]
    )
    func oneShotCommandsAreNotRestorable(arguments: [String]) throws {
        let fixture = try makeFixture { [StateRow("one-shot-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = hermesProcess(
            pid: 9_529,
            workspaceID: fixture.workspaceID,
            panelID: fixture.panelID
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [fixture.hermesExecutable] + arguments,
            environment: hermesEnvironment(fixture)
        )
        let observed = VaultObservedAgentProcess(
            processName: process.name,
            processPath: process.path,
            arguments: liveProcess.arguments,
            environment: liveProcess.environment
        )
        let registration = CmuxVaultAgentRegistration.builtInHermes

        #expect(registration.detect.matches(observed))
        #expect(registration.processDetectedSnapshotIsRestorable(for: observed) == false)
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [process],
            argumentsByPID: [process.pid: liveProcess]
        )
        #expect(detected.isEmpty)
    }

    @Test("A hook-owned Python Hermes process remains live without state.db inference")
    func hookOwnedPythonProcessRemainsLive() throws {
        let fixture = try makeFixture { [StateRow("hook-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processID = 9_530
        let identity = AgentPIDProcessIdentity(pid: pid_t(processID), startSeconds: 100, startMicroseconds: 200)
        let pythonExecutable = fixture.hermesHome
            .appendingPathComponent("hermes-agent/venv/bin/python", isDirectory: false)
            .path
        let hermesEntrypoint = fixture.hermesHome
            .appendingPathComponent("hermes-agent/hermes", isDirectory: false)
            .path
        try writeHermesHookStore(
            fixture: fixture,
            sessionID: "hook-session",
            processID: processID,
            identity: identity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--tui"]
        )
        let liveProcess = CmuxTopProcessArguments(
            arguments: [pythonExecutable, hermesEntrypoint, "--tui"],
            environment: hermesEnvironment(fixture).merging([
                "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                "CMUX_SURFACE_ID": fixture.panelID.uuidString,
            ]) { _, incoming in incoming }
        )

        let index = try loadHookBackedHermesIndex(
            fixture: fixture,
            processID: processID,
            identity: identity,
            liveProcess: liveProcess
        )
        let entry = try #require(index.entry(workspaceId: fixture.workspaceID, panelId: fixture.panelID))

        #expect(entry.snapshot.sessionId == "hook-session")
        #expect(entry.processLiveness == .running)
        #expect(entry.agentProcessIDs == [processID])
    }

    @Test("Quit-time save revalidates a cached Hermes process against the current snapshot")
    func quitTimeSaveRevalidatesCachedHermesProcess() throws {
        let fixture = try makeFixture { [StateRow("cached-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processID = Int(Int32.max) - 9_530
        let identity = AgentPIDProcessIdentity(pid: pid_t(processID), startSeconds: 300, startMicroseconds: 400)
        try writeHermesHookStore(
            fixture: fixture,
            sessionID: "cached-session",
            processID: processID,
            identity: identity,
            executablePath: fixture.hermesExecutable,
            arguments: [fixture.hermesExecutable, "--resume", "cached-session"]
        )
        let cached = try loadHookBackedHermesIndex(
            fixture: fixture,
            processID: processID,
            identity: identity,
            liveProcess: CmuxTopProcessArguments(
                arguments: [fixture.hermesExecutable, "--resume", "cached-session"],
                environment: hermesEnvironment(fixture).merging([
                    "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                    "CMUX_SURFACE_ID": fixture.panelID.uuidString,
                ]) { _, incoming in incoming }
            )
        )
        #expect(cached.entry(workspaceId: fixture.workspaceID, panelId: fixture.panelID)?.processLiveness == .running)

        let resumeIndexes = ProcessDetectedResumeIndexes.loadSynchronously(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            cachedRestorableAgentIndex: cached
        )
        let revalidated = try #require(
            resumeIndexes.restorableAgentIndex.entry(
                workspaceId: fixture.workspaceID,
                panelId: fixture.panelID
            )
        )

        #expect(revalidated.processLiveness == .exited)
        #expect(revalidated.agentProcessIDs.isEmpty)
    }

    @Test(
        "Explicit Hermes resume flags win over ambiguous cwd lookup",
        arguments: [
            ["--resume", "explicit-session"],
            ["--resume=explicit-session"],
            ["-r", "explicit-session"],
            ["-r=explicit-session"],
        ]
    )
    func explicitResumeFlagsWin(arguments: [String]) throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("explicit-session", cwd: repo.path, startedAt: 10),
                StateRow("other-active-session", cwd: repo.path, startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let processArguments = [fixture.hermesExecutable] + arguments + ["--tui"]
        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_521, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_521: CmuxTopProcessArguments(
                    arguments: processArguments,
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.values.first?.snapshot.kind == .hermesAgent)
        #expect(detected.values.first?.snapshot.sessionId == "explicit-session")
    }

    @Test("A bare Hermes process fails closed when active state.db rows are ambiguous")
    func bareProcessRejectsAmbiguousActiveSessions() throws {
        let fixture = try makeFixture { repo in
            [
                StateRow("active-a", cwd: repo.path, startedAt: 10),
                StateRow("active-b", cwd: repo.path, startedAt: 20),
            ]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [hermesProcess(pid: 9_522, workspaceID: fixture.workspaceID, panelID: fixture.panelID)],
            argumentsByPID: [
                9_522: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.isEmpty)
    }

    @Test("Two bare Hermes panes in one cwd do not claim the same state.db session")
    func coLocatedBareProcessesDoNotShareOneSession() throws {
        let secondPanelID = UUID()
        let fixture = try makeFixture { [StateRow("only-active", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processes = [
            hermesProcess(pid: 9_523, workspaceID: fixture.workspaceID, panelID: fixture.panelID),
            hermesProcess(pid: 9_524, workspaceID: fixture.workspaceID, panelID: secondPanelID),
        ]
        let launch = CmuxTopProcessArguments(
            arguments: [fixture.hermesExecutable],
            environment: hermesEnvironment(fixture)
        )

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: processes,
            argumentsByPID: [9_523: launch, 9_524: launch]
        )

        #expect(detected.isEmpty)
    }

    @Test("An explicit Hermes owner prevents a bare pane from claiming the same state.db session")
    func explicitAndBareProcessesDoNotShareOneSession() throws {
        let explicitPanelID = UUID()
        let fixture = try makeFixture { [StateRow("explicit-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let detected = try detectedHermesSnapshots(
            fixture: fixture,
            processes: [
                hermesProcess(pid: 9_525, workspaceID: fixture.workspaceID, panelID: explicitPanelID),
                hermesProcess(pid: 9_526, workspaceID: fixture.workspaceID, panelID: fixture.panelID),
            ],
            argumentsByPID: [
                9_525: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--resume", "explicit-session"],
                    environment: hermesEnvironment(fixture)
                ),
                9_526: CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable],
                    environment: hermesEnvironment(fixture)
                ),
            ]
        )

        #expect(detected.count == 1)
        #expect(detected[.init(workspaceId: fixture.workspaceID, panelId: explicitPanelID)]?.snapshot.sessionId == "explicit-session")
        #expect(detected[.init(workspaceId: fixture.workspaceID, panelId: fixture.panelID)] == nil)
    }

    @Test("Session index entries preserve Hermes cwd for filtering and resume")
    func sessionIndexPreservesCwd() throws {
        let fixture = try makeFixture { [StateRow("indexed-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = SessionIndexStore.loadHermesAgentEntriesForTesting(
            stateDBPath: fixture.stateDB.path,
            cwdFilter: fixture.repo.path
        )
        let entry = try #require(outcome.entries.first)

        #expect(outcome.errors.isEmpty)
        #expect(entry.sessionId == "indexed-session")
        #expect(entry.cwd == fixture.repo.path)
    }

    @MainActor
    @Test("Indexed Hermes sessions form a visible Vault section")
    func indexedSessionsFormVisibleVaultSection() throws {
        let fixture = try makeFixture {
            [StateRow("visible-session", cwd: $0.path, startedAt: 42)]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outcome = SessionIndexStore.loadHermesAgentEntriesForTesting(
            stateDBPath: fixture.stateDB.path
        )
        let entry = try #require(outcome.entries.first)
        let defaults = UserDefaults.standard
        let groupingKey = "sessionIndex.grouping"
        let agentOrderKey = "sessionIndex.agentOrder"
        let previousGrouping = defaults.object(forKey: groupingKey)
        let previousAgentOrder = defaults.object(forKey: agentOrderKey)
        defer {
            restoreDefaultsValue(previousGrouping, key: groupingKey, defaults: defaults)
            restoreDefaultsValue(previousAgentOrder, key: agentOrderKey, defaults: defaults)
        }
        defaults.set(SessionGrouping.agent.rawValue, forKey: groupingKey)
        defaults.set([SessionAgent.hermesAgent.rawValue], forKey: agentOrderKey)

        let store = SessionIndexStore()
        store.replaceEntriesForTesting([entry])
        let section = try #require(store.sectionsForCurrentGrouping().first)

        #expect(section.key == .agent(.hermesAgent))
        #expect(section.title == "Hermes Agent")
        #expect(section.icon == .agent(.hermesAgent))
        #expect(section.entries.map(\.sessionId) == ["visible-session"])
        #expect(SessionAgent.hermesAgent.assetName == "AgentIcons/HermesAgent")
        #expect(CmuxVaultAgentRegistration.builtInHermes.iconAssetName == "AgentIcons/HermesAgent")
    }

    @Test("Hermes loads the official desktop icon from the compiled asset catalog")
    func officialDesktopIconAsset() throws {
        let assetName = try #require(SessionAgent.hermesAgent.assetName)
        let image = try #require(
            Bundle.main.image(forResource: assetName)
                ?? NSImage(named: NSImage.Name(assetName))
        )
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let rendered = try #require(
            image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        )

        #expect(rendered.width == 1_024)
        #expect(rendered.height == 1_024)
    }

    @Test("User-configured detectors take precedence over the built-in Hermes detector")
    func userDetectorTakesPrecedence() throws {
        let fixture = try makeFixture { [StateRow("built-in-session", cwd: $0.path)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builtInRegistry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        let builtInHermes = try #require(builtInRegistry.registration(id: "hermes-agent"))
        let custom = CmuxVaultAgentRegistration(
            id: "team-hermes",
            name: "Team Hermes",
            detect: CmuxVaultAgentDetectRule(processNames: ["hermes"]),
            sessionIdSource: .argvOption("--team-session"),
            resumeCommand: "{{executable}} --team-session {{sessionId}}"
        )
        let registry = CmuxVaultAgentRegistry(registrations: [builtInHermes, custom])
        let process = hermesProcess(pid: 9_525, workspaceID: fixture.workspaceID, panelID: fixture.panelID)

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 0),
                includesProcessDetails: true
            ),
            capturedAt: 42,
            processArgumentsProvider: { pid in
                guard pid == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [fixture.hermesExecutable, "--team-session", "team-session-1"],
                    environment: self.hermesEnvironment(fixture)
                )
            }
        )

        #expect(detected.values.first?.snapshot.kind == .custom("team-hermes"))
        #expect(detected.values.first?.snapshot.sessionId == "team-session-1")
    }

    @Test("Hermes hook install migrates consent to ambient per-launch dispatch")
    func hookInstallUsesAmbientDispatchAndConsent() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks")
        defer { try? FileManager.default.removeItem(at: root) }
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let pinnedCLI = root.appendingPathComponent("cmux pinned cli", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: pinnedCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinnedCLI.path)
        let socketPath = root.appendingPathComponent("cmux-debug-hermes-first-class.sock").path
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let allowlistURL = hermesHome.appendingPathComponent("shell-hooks-allowlist.json")
        let legacyCommand = #"sh -c 'cmux_cli=cmux; "$cmux_cli" hooks hermes-agent prompt-submit'"#
        let userCommand = "echo user-owned Hermes hook"
        let existingAllowlist = try JSONSerialization.data(
            withJSONObject: [
                "approvals": [
                    [
                        "event": "pre_llm_call",
                        "command": legacyCommand,
                        "approved_at": "2026-01-01T00:00:00Z",
                    ],
                    [
                        "event": "pre_tool_call",
                        "command": userCommand,
                        "scope": "user",
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try existingAllowlist.write(to: allowlistURL, options: .atomic)

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": pinnedCLI.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        let config = try String(
            contentsOf: hermesHome.appendingPathComponent("config.yaml"),
            encoding: .utf8
        )
        let allowlistData = try Data(
            contentsOf: allowlistURL
        )
        let allowlist = try #require(
            JSONSerialization.jsonObject(with: allowlistData) as? [String: Any]
        )
        let approvals = try #require(allowlist["approvals"] as? [[String: Any]])
        let commands = approvals.compactMap { $0["command"] as? String }
        let cmuxCommands = commands.filter {
            $0.contains("cmux-hermes-agent-hook-v2") || $0.contains("hooks hermes-agent ")
        }

        #expect(commands.count == approvals.count)
        #expect(commands.contains(userCommand))
        #expect(!commands.contains(legacyCommand))
        #expect(!cmuxCommands.isEmpty)
        #expect(cmuxCommands.allSatisfy { !$0.contains("cmux-hermes-agent-hook-v2") })
        #expect(cmuxCommands.allSatisfy { !$0.contains(pinnedCLI.path) })
        #expect(cmuxCommands.allSatisfy { !$0.contains(socketPath) })
        #expect(cmuxCommands.allSatisfy { $0.contains("CMUX_BUNDLED_CLI_PATH") })
        #expect(cmuxCommands.allSatisfy { $0.contains("CMUX_SOCKET_PATH") })
        #expect(!config.contains("cmux-hermes-agent-hook-v2"))
        #expect(!config.contains(pinnedCLI.path))
        #expect(!config.contains(socketPath))
        #expect(config.contains("CMUX_BUNDLED_CLI_PATH"))
        #expect(config.contains("CMUX_SOCKET_PATH"))
    }

    @Test("Hermes hook install creates a fresh home without a pinned cmux target")
    func hookInstallCreatesMissingHomeWithAmbientDispatch() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks-no-target")
        defer { try? FileManager.default.removeItem(at: root) }
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let configURL = hermesHome.appendingPathComponent("config.yaml")
        let allowlistURL = hermesHome.appendingPathComponent("shell-hooks-allowlist.json")

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: configURL.path))
        #expect(FileManager.default.fileExists(atPath: allowlistURL.path))
        let config = try String(contentsOf: configURL, encoding: .utf8)
        #expect(config.contains("CMUX_BUNDLED_CLI_PATH"))
        #expect(config.contains("CMUX_SOCKET_PATH"))
    }

    @Test("Hermes hook install reports directory creation failures accurately")
    func hookInstallReportsDirectoryCreationFailure() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks-create-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let blockedHermesHome = "/dev/null/cmux-hermes-hooks-\(UUID().uuidString)"

        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "hermes-agent", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": blockedHermesHome,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("could not create the hooks directory at \(blockedHermesHome)"))
        #expect(result.output.contains("Check the parent directory permissions and try again."))
        #expect(!result.output.contains("conflicting file"))
    }

    @Test("Hook setup skips an unroutable pinned agent and continues with ambient agents")
    func hookSetupContinuesAfterPinnedTargetFailure() throws {
        let root = try temporaryDirectory(prefix: "cmux-hermes-hooks-setup")
        defer { try? FileManager.default.removeItem(at: root) }
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        for name in ["grok", "hermes"] {
            let executable = binDirectory.appendingPathComponent(name, isDirectory: false)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: HermesFirstClassBundleToken.self)
        let result = try runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "setup", "--yes"],
            environment: [
                "HOME": root.path,
                "HERMES_HOME": hermesHome.path,
                "GROK_HOME": grokHome.path,
                "PATH": "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("grok"))
        #expect(result.output.contains("Open a cmux workspace and run this command again."))
        #expect(!result.output.contains("CMUX_SOCKET_PATH"))
        #expect(!result.output.contains("CMUX_TAG"))
        #expect(result.output.contains("hermes-agent:"))
        #expect(FileManager.default.fileExists(
            atPath: hermesHome.appendingPathComponent("config.yaml", isDirectory: false).path
        ))
    }

    private struct Fixture {
        let root: URL
        let hermesHome: URL
        let stateDB: URL
        let repo: URL
        let workspaceID: UUID
        let panelID: UUID
        let hermesExecutable: String
    }

    private func makeFixture(rows: (URL) -> [StateRow]) throws -> Fixture {
        let root = try temporaryDirectory(prefix: "cmux-hermes-first-class")
        let hermesHome = root.appendingPathComponent("hermes-home", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let stateDB = hermesHome.appendingPathComponent("state.db", isDirectory: false)
        try writeStateDB(at: stateDB, rows: rows(repo))
        return Fixture(
            root: root,
            hermesHome: hermesHome,
            stateDB: stateDB,
            repo: repo,
            workspaceID: UUID(),
            panelID: UUID(),
            hermesExecutable: "/usr/local/bin/hermes"
        )
    }

    private func detectedHermesSnapshots(
        fixture: Fixture,
        processes: [CmuxTopProcessInfo],
        argumentsByPID: [Int: CmuxTopProcessArguments]
    ) throws -> [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] {
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        _ = try #require(registry.registration(id: "hermes-agent"))
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: .default,
            processSnapshot: CmuxTopProcessSnapshot(
                processes: processes,
                sampledAt: Date(timeIntervalSince1970: 0),
                includesProcessDetails: true
            ),
            capturedAt: 42,
            processArgumentsProvider: { argumentsByPID[$0] }
        )
    }

    private func hermesProcess(
        pid: Int,
        workspaceID: UUID,
        panelID: UUID,
        name: String = "hermes",
        path: String = "/usr/local/bin/hermes"
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: panelID,
            cmuxAttributionReason: "cmux-test",
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }

    private func hermesEnvironment(_ fixture: Fixture) -> [String: String] {
        [
            "HERMES_HOME": fixture.hermesHome.path,
            "CMUX_AGENT_LAUNCH_CWD": fixture.repo.path,
            "PWD": fixture.repo.path,
        ]
    }

    private func writeHermesHookStore(
        fixture: Fixture,
        sessionID: String,
        processID: Int,
        identity: AgentPIDProcessIdentity,
        executablePath: String,
        arguments: [String]
    ) throws {
        let stateDirectory = fixture.root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    sessionID: [
                        "sessionId": sessionID,
                        "workspaceId": fixture.workspaceID.uuidString,
                        "surfaceId": fixture.panelID.uuidString,
                        "cwd": fixture.repo.path,
                        "pid": processID,
                        "pidStartSeconds": identity.startSeconds,
                        "pidStartMicroseconds": identity.startMicroseconds,
                        "isRestorable": true,
                        "updatedAt": 42,
                        "launchCommand": [
                            "launcher": "hermes-agent",
                            "executablePath": executablePath,
                            "arguments": arguments,
                            "workingDirectory": fixture.repo.path,
                            "environment": ["HERMES_HOME": fixture.hermesHome.path],
                            "capturedAt": 42,
                            "source": "environment",
                        ],
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: stateDirectory.appendingPathComponent("hermes-agent-hook-sessions.json", isDirectory: false),
            options: .atomic
        )
    }

    private func loadHookBackedHermesIndex(
        fixture: Fixture,
        processID: Int,
        identity: AgentPIDProcessIdentity,
        liveProcess: CmuxTopProcessArguments
    ) throws -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: fixture.root.path,
            environment: ["HOME": fixture.root.path],
            fileManager: .default
        )
        _ = try #require(registry.registration(id: "hermes-agent"))
        return RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: registry,
            detectedSnapshots: [:],
            processArgumentsProvider: { $0 == processID ? liveProcess : nil },
            processPresenceProvider: { $0 == processID ? .present : .absent },
            processIdentityProvider: { $0 == processID ? identity : nil }
        )
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func writeStateDB(at url: URL, rows: [StateRow]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw HermesFirstClassTestError.sqlite("open failed")
        }
        defer { sqlite3_close(database) }
        try execute(database, sql: """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          model TEXT,
          started_at REAL NOT NULL,
          ended_at REAL,
          title TEXT,
          cwd TEXT
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_name TEXT,
          tool_calls TEXT,
          timestamp REAL NOT NULL
        );
        """)
        for row in rows {
            try execute(
                database,
                sql: """
                INSERT INTO sessions (id, source, model, started_at, ended_at, title, cwd)
                VALUES (
                  \(sqlLiteral(row.id)),
                  \(sqlLiteral(row.source)),
                  'test-model',
                  \(row.startedAt),
                  \(row.endedAt.map { String($0) } ?? "NULL"),
                  \(sqlLiteral(row.id)),
                  \(row.cwd.map(sqlLiteral) ?? "NULL")
                );
                """
            )
        }
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error \(result)"
            sqlite3_free(error)
            throw HermesFirstClassTestError.sqlite(message)
        }
    }

    private func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

private final class HermesFirstClassBundleToken {}

private enum HermesFirstClassTestError: Error {
    case sqlite(String)
}
