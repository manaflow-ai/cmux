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

    @Test("Kimi hook sessions are discovered and produce a resume command")
    func hookSessionLoadsIntoResumePipeline() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-kimi-restore-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

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
                        "cwd": workingDirectory.path,
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
        #expect(snapshot.workingDirectory == workingDirectory.path)

        let resumeCommand = try #require(snapshot.resumeCommand)
        #expect(resumeCommand.contains("'kimi' '--resume' '\(sessionID)'"))
        #expect(resumeCommand.hasPrefix("cd -- '\(workingDirectory.path)'"))
    }
}
