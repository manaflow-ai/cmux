import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Kimi restorable agent")
struct KimiRestorableAgentTests {
    @Test("Kimi is a codable registry-owned restorable kind")
    func registryOwnedKindRoundTrip() throws {
        let kind = try #require(RestorableAgentKind(rawValue: "kimi"))

        #expect(!RestorableAgentKind.allCases.contains(kind))
        #expect(kind.rawValue == "kimi")
        #expect(kind.displayName == "Kimi Code")
        #expect(kind.restoreMode == .resumeSession)
        #expect(kind.cwdNamespacing == .byDirectory)

        let encoded = try JSONEncoder().encode(kind)
        #expect(String(decoding: encoded, as: UTF8.self) == #""kimi""#)
        #expect(try JSONDecoder().decode(RestorableAgentKind.self, from: encoded) == kind)

        let registration = CmuxVaultAgentRegistration.builtInKimi
        #expect(registration.id == "kimi")
        #expect(registration.name == "Kimi Code")
        #expect(registration.detect.processNames == ["kimi", "kimi-cli", "kimi-code"])
        #expect(registration.sessionIdSource == .argvOption("--resume"))
        #expect(registration.resumeCommand == "{{executable}} --resume {{sessionId}}")
    }

    @Test("Built-in Kimi registry resume preserves safe launch options")
    func builtInRegistryResumeUsesKimiSanitizer() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("kimi"),
            sessionId: "kimi-session",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "kimi",
                executablePath: "/opt/kimi/bin/kimi",
                arguments: [
                    "/opt/kimi/bin/kimi",
                    "--model", "kimi-k2",
                    "--config-file", "/tmp/kimi.toml",
                    "--yolo",
                ],
                workingDirectory: nil,
                environment: nil,
                capturedAt: 123,
                source: "test"
            ),
            registration: .builtInKimi
        )

        #expect(
            snapshot.resumeCommand == "'/opt/kimi/bin/kimi' '--resume' 'kimi-session' '--model' 'kimi-k2' '--config-file' '/tmp/kimi.toml'"
        )
    }

    @Test("Customized Kimi registration with canonical template keeps executable ownership")
    func canonicalTemplateDoesNotOverrideCustomExecutable() {
        var registration = CmuxVaultAgentRegistration.builtInKimi
        registration.name = "Custom Kimi"
        registration.detect = CmuxVaultAgentDetectRule(processName: "custom-kimi")
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("kimi"),
            sessionId: "custom-session",
            workingDirectory: nil,
            launchCommand: nil,
            registration: registration
        )

        #expect(snapshot.resumeCommand == "'custom-kimi' '--resume' 'custom-session'")
    }

    @Test("Kimi's OS process title remains detectable")
    func processTitleDetection() {
        let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "Kimi Code",
            processPath: "/Users/example/.local/share/uv/tools/kimi-cli/bin/python",
            arguments: ["Kimi Code"],
            environment: [:]
        )

        #expect(definition?.id == "kimi")
    }

    @Test(
        "Kimi executable aliases use the shared foreground sanitizer",
        arguments: ["kimi-cli", "kimi-code"]
    )
    func foregroundExecutableAlias(_ executable: String) {
        #expect(
            TerminalForegroundCommandCapture.commandLine(
                fromArgv: [
                    "/Users/example/.local/bin/\(executable)",
                    "--resume", "stale-session",
                    "--model", "kimi-k2",
                ]
            ) == "/Users/example/.local/bin/\(executable) --model kimi-k2"
        )
    }

    @Test("Pre-existing custom Kimi Vault registrations remain decodable")
    func customVaultRegistrationStaysDecodable() throws {
        let registration = try JSONDecoder().decode(
            CmuxVaultAgentRegistration.self,
            from: Data("""
            {
              "id": "kimi",
              "name": "Custom Kimi",
              "sessionIdSource": "--resume",
              "resumeCommand": "custom-kimi --resume {{sessionId}}"
            }
            """.utf8)
        )

        #expect(registration.id == "kimi")
        #expect(registration.name == "Custom Kimi")
        #expect(registration.resumeCommand == "custom-kimi --resume {{sessionId}}")
    }

    @Test("Custom Kimi registration keeps command ownership across snapshot persistence")
    func customVaultRegistrationSurvivesSnapshotRoundTrip() throws {
        let registration = CmuxVaultAgentRegistration(
            id: "kimi",
            name: "Custom Kimi",
            detect: CmuxVaultAgentDetectRule(processName: "custom-kimi"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "custom-kimi --resume {{sessionId}}",
            forkCommand: "custom-kimi --fork {{sessionId}}"
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("kimi"),
            sessionId: "custom-session",
            workingDirectory: nil,
            launchCommand: nil,
            registration: registration
        )

        let decoded = try JSONDecoder().decode(
            SessionRestorableAgentSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded.kind == .custom("kimi"))
        #expect(decoded.resumeCommand == "'custom-kimi' '--resume' 'custom-session'")
        #expect(decoded.forkCommand == "'custom-kimi' '--fork' 'custom-session'")
    }

    @Test("Kimi hook sessions resume from their launch directory namespace")
    func hookSessionLoadsIntoResumePipeline() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-kimi-restore-\(UUID().uuidString)", isDirectory: true)
        let launchWorkingDirectory = root.appendingPathComponent("launch-repo", isDirectory: true)
        let runtimeWorkingDirectory = root.appendingPathComponent("runtime-worktree", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: launchWorkingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeWorkingDirectory, withIntermediateDirectories: true)

        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "72124c21-7b09-40a1-a98f-718164c46431"
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let store = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    sessionID: [
                        "sessionId": sessionID,
                        "workspaceId": workspaceID.uuidString,
                        "surfaceId": panelID.uuidString,
                        "cwd": runtimeWorkingDirectory.path,
                        "launchCommand": [
                            "launcher": "kimi",
                            "executablePath": "/Users/example/.local/bin/kimi",
                            "arguments": ["/Users/example/.local/bin/kimi"],
                            "workingDirectory": launchWorkingDirectory.path,
                            "capturedAt": 1_750_000_000.0,
                            "source": "test",
                        ],
                        "isRestorable": true,
                        "updatedAt": 1_750_000_000.0,
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try store.write(
            to: stateDirectory.appendingPathComponent("kimi-hook-sessions.json", isDirectory: false),
            options: .atomic
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceID, panelId: panelID)
        )
        #expect(snapshot.kind == .custom("kimi"))
        #expect(snapshot.kind.rawValue == "kimi")
        #expect(snapshot.registration?.id == "kimi")
        #expect(snapshot.sessionId == sessionID)
        #expect(snapshot.workingDirectory == launchWorkingDirectory.path)

        let resumeCommand = try #require(snapshot.resumeCommand)
        #expect(resumeCommand.contains("'/Users/example/.local/bin/kimi' '--resume' '\(sessionID)'"))
        #expect(resumeCommand.hasPrefix("cd -- '\(launchWorkingDirectory.path)'"))
    }

    @Test("Custom Kimi registrations preserve their runtime working directory")
    func customKimiRegistrationKeepsRuntimeDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-custom-kimi-restore-\(UUID().uuidString)", isDirectory: true)
        let launchWorkingDirectory = root.appendingPathComponent("launch-repo", isDirectory: true)
        let runtimeWorkingDirectory = root.appendingPathComponent("runtime-worktree", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: launchWorkingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeWorkingDirectory, withIntermediateDirectories: true)

        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "custom-kimi-session"
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let store = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    sessionID: [
                        "sessionId": sessionID,
                        "workspaceId": workspaceID.uuidString,
                        "surfaceId": panelID.uuidString,
                        "cwd": runtimeWorkingDirectory.path,
                        "launchCommand": [
                            "launcher": "kimi",
                            "executablePath": "/Users/example/.local/bin/custom-kimi",
                            "arguments": ["/Users/example/.local/bin/custom-kimi"],
                            "workingDirectory": launchWorkingDirectory.path,
                            "capturedAt": 1_750_000_000.0,
                            "source": "test",
                        ],
                        "isRestorable": true,
                        "updatedAt": 1_750_000_000.0,
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try store.write(
            to: stateDirectory.appendingPathComponent("kimi-hook-sessions.json", isDirectory: false),
            options: .atomic
        )
        let customRegistration = CmuxVaultAgentRegistration(
            id: "kimi",
            name: "Custom Kimi",
            detect: CmuxVaultAgentDetectRule(processName: "custom-kimi"),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: "custom-kimi --resume {{sessionId}}"
        )
        let registry = CmuxVaultAgentRegistry(registrations: [customRegistration])

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(
                homeDirectory: root.path,
                fileManager: fileManager,
                registry: registry,
                detectedSnapshots: [:],
                processArgumentsProvider: { _ in nil }
            ).snapshot(workspaceId: workspaceID, panelId: panelID)
        )
        #expect(snapshot.registration == customRegistration)
        #expect(snapshot.workingDirectory == runtimeWorkingDirectory.path)

        let resumeCommand = try #require(snapshot.resumeCommand)
        #expect(resumeCommand.hasPrefix("cd -- '\(runtimeWorkingDirectory.path)'"))
    }
}

@Suite("Restorable agent persisted kind decoding")
struct RestorableAgentPersistedKindDecodingTests {
    @Test("Registry-owned persisted binding kinds match live custom snapshots", arguments: registryOwnedCases)
    func registryOwnedPersistedBindingKindMatchesLiveCustomSnapshot(_ testCase: KindCase) throws {
        let sessionId = "session-\(testCase.id)"
        let launchDirectory = "/tmp/cmux-\(testCase.id)-launch"
        let runtimeDirectory = "/tmp/cmux-\(testCase.id)-runtime"
        let liveSnapshot = SessionRestorableAgentSnapshot(
            kind: .custom(testCase.id),
            sessionId: sessionId,
            workingDirectory: launchDirectory,
            launchCommand: nil,
            registration: testCase.registration
        )
        let persistedBinding = try Self.decodedBinding(
            kind: testCase.id,
            sessionId: sessionId,
            cwd: runtimeDirectory
        )

        let compatible = Workspace.restorableAgentForSessionRestore(
            liveSnapshot,
            resumeBinding: persistedBinding
        )
        #expect(compatible?.kind == liveSnapshot.kind)
        #expect(compatible?.kind == .custom(testCase.id))

        let retargeted = Workspace.resumeBindingForSessionRestore(
            persistedBinding,
            restorableAgent: liveSnapshot
        )
        let expectedDirectory = testCase.kind.cwdNamespacing == .byDirectory ? launchDirectory : runtimeDirectory
        #expect(retargeted?.cwd == expectedDirectory)
    }

    @Test("Native persisted binding kinds still match native snapshots", arguments: nativeCases)
    func nativePersistedBindingKindMatchesNativeSnapshot(_ testCase: KindCase) throws {
        let sessionId = "session-\(testCase.id)"
        let launchDirectory = "/tmp/cmux-\(testCase.id)-launch"
        let runtimeDirectory = "/tmp/cmux-\(testCase.id)-runtime"
        let liveSnapshot = SessionRestorableAgentSnapshot(
            kind: testCase.kind,
            sessionId: sessionId,
            workingDirectory: launchDirectory,
            launchCommand: nil,
            registration: testCase.registration
        )
        let persistedBinding = try Self.decodedBinding(
            kind: testCase.id,
            sessionId: sessionId,
            cwd: runtimeDirectory
        )

        let compatible = Workspace.restorableAgentForSessionRestore(
            liveSnapshot,
            resumeBinding: persistedBinding
        )
        #expect(compatible?.kind == liveSnapshot.kind)

        let retargeted = Workspace.resumeBindingForSessionRestore(
            persistedBinding,
            restorableAgent: liveSnapshot
        )
        let expectedDirectory = testCase.kind.cwdNamespacing == .byDirectory ? launchDirectory : runtimeDirectory
        #expect(retargeted?.cwd == expectedDirectory)
    }

    @Test("Kimi hook-store snapshots match persisted Kimi resume bindings")
    func kimiHookStoreSnapshotMatchesPersistedBindingKind() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-kimi-restore-of-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let launchDirectory = root.appendingPathComponent("launch-repo", isDirectory: true)
        let runtimeDirectory = root.appendingPathComponent("runtime-worktree", isDirectory: true)
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "72124c21-7b09-40a1-a98f-718164c46431"
        let store = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    sessionId: [
                        "sessionId": sessionId,
                        "workspaceId": workspaceId.uuidString,
                        "surfaceId": panelId.uuidString,
                        "cwd": runtimeDirectory.path,
                        "launchCommand": [
                            "launcher": "kimi",
                            "executablePath": "/Users/example/.local/bin/kimi",
                            "arguments": ["/Users/example/.local/bin/kimi"],
                            "workingDirectory": launchDirectory.path,
                            "capturedAt": 1_750_000_000.0,
                            "source": "test",
                        ],
                        "isRestorable": true,
                        "updatedAt": 1_750_000_000.0,
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try store.write(
            to: stateDirectory.appendingPathComponent("kimi-hook-sessions.json", isDirectory: false),
            options: .atomic
        )

        let liveSnapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        #expect(liveSnapshot.kind == .custom("kimi"))
        #expect(liveSnapshot.registration?.id == "kimi")

        let persistedBinding = try Self.decodedBinding(
            kind: "kimi",
            sessionId: sessionId,
            cwd: runtimeDirectory.path
        )
        let compatible = Workspace.restorableAgentForSessionRestore(
            liveSnapshot,
            resumeBinding: persistedBinding
        )

        #expect(compatible?.kind == liveSnapshot.kind)
    }

    private static func decodedBinding(
        kind: String,
        sessionId: String,
        cwd: String
    ) throws -> SurfaceResumeBindingSnapshot {
        let persisted = SurfaceResumeBindingSnapshot(
            kind: kind,
            command: "'\(kind)' '--resume' '\(sessionId)'",
            cwd: cwd,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true
        )
        return try JSONDecoder().decode(
            SurfaceResumeBindingSnapshot.self,
            from: JSONEncoder().encode(persisted)
        )
    }

    struct KindCase: Sendable, CustomTestStringConvertible {
        let id: String
        let kind: RestorableAgentKind
        let registration: CmuxVaultAgentRegistration?

        var testDescription: String { id }
    }

    private static let registryOwnedCases: [KindCase] = [
        KindCase(id: "pi", kind: .custom("pi"), registration: .builtInPi),
        KindCase(id: "grok", kind: .custom("grok"), registration: .builtInGrok),
        KindCase(id: "antigravity", kind: .custom("antigravity"), registration: .builtInAntigravity),
        KindCase(id: "kimi", kind: .custom("kimi"), registration: .builtInKimi),
        KindCase(
            id: "ollama",
            kind: .custom("ollama"),
            registration: CmuxVaultAgentRegistration(
                id: "ollama",
                name: "Custom Ollama",
                detect: CmuxVaultAgentDetectRule(processName: "ollama"),
                sessionIdSource: .argvOption("--session"),
                resumeCommand: "custom-ollama --resume {{sessionId}}"
            )
        ),
    ]

    private static let nativeCases: [KindCase] = [
        KindCase(id: "claude", kind: .claude, registration: nil),
        KindCase(id: "codex", kind: .codex, registration: nil),
        KindCase(id: "opencode", kind: .opencode, registration: nil),
    ]
}
