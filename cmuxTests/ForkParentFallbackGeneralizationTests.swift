import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct ForkParentFallbackGeneralizationTests {
    @Test func codexUnpromptedForkPaneUsesParentThreadWithoutStealingParentPane() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try writeStore(root: fixture.root, filename: "codex-hook-sessions.json", sessions: [
            fixture.parentCodexId: hookRecord(kind: "codex", sessionId: fixture.parentCodexId, fixture: fixture, panelId: fixture.parentPanelId),
        ])

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/Users/lawrence/.bun/bin/codex", "fork", fixture.parentCodexId, "--model", "gpt-5"],
            launchKind: "codex",
            processName: "codex",
            processPath: "/Users/lawrence/.bun/bin/codex"
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        let forkSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        #expect(forkSnapshot.kind == .codex)
        #expect(forkSnapshot.sessionId == fixture.parentCodexId)
        #expect(forkSnapshot.forkCommand?.contains(fixture.parentCodexId) == true)
        #expect(forkSnapshot.forkCommand?.contains("'fork'") == true)
        #expect(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.parentPanelId)?.sessionId == fixture.parentCodexId)
    }

    @Test func codexPaneHookIdentityWinsWhenProcessIdentityIsUnavailable() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try writeStore(root: fixture.root, filename: "codex-hook-sessions.json", sessions: [
            fixture.parentCodexId: hookRecord(kind: "codex", sessionId: fixture.parentCodexId, fixture: fixture, panelId: fixture.parentPanelId, updatedAt: 10),
            fixture.childCodexId: hookRecord(kind: "codex", sessionId: fixture.childCodexId, fixture: fixture, panelId: fixture.forkPanelId, updatedAt: 20),
        ])

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/codex", "fork", fixture.parentCodexId],
            launchKind: "codex",
            processName: "codex",
            processPath: "/usr/local/bin/codex"
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected, processIdentityProvider: { _ in nil })

        let forkSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        #expect(forkSnapshot.sessionId == fixture.childCodexId)
        #expect(index.processIDs(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId) == [fixture.forkProcessID])
    }

    @Test func codexFallbackYieldsToOtherKindSamePaneHookEntry() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try writeStore(root: fixture.root, filename: "opencode-hook-sessions.json", sessions: [
            "oc-session": hookRecord(kind: "opencode", sessionId: "oc-session", fixture: fixture, panelId: fixture.forkPanelId),
        ])

        let detected = detectedSnapshots(
            fixture: fixture,
            argv: ["/usr/local/bin/codex", "fork", fixture.parentCodexId],
            launchKind: "codex",
            processName: "codex",
            processPath: "/usr/local/bin/codex"
        )
        let index = loadIndex(fixture: fixture, detectedSnapshots: detected)

        let paneSnapshot = try #require(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId))
        #expect(paneSnapshot.kind == .opencode)
        #expect(paneSnapshot.sessionId == "oc-session")
    }

    @Test func piForkFlagDemotesDetectedParentAndDoesNotEvictParentPane() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try writeStore(root: fixture.root, filename: "pi-hook-sessions.json", sessions: [
            fixture.parentPiPath: hookRecord(kind: "pi", sessionId: fixture.parentPiPath, fixture: fixture, panelId: fixture.parentPanelId),
        ])

        let registry = CmuxVaultAgentRegistry(registrations: [.builtInPi])
        let detected = detectedSnapshots(
            fixture: fixture,
            registry: registry,
            argv: ["/usr/local/bin/pi", "--session", fixture.parentPiPath, "--fork"],
            launchKind: "pi",
            processName: "pi",
            processPath: "/usr/local/bin/pi"
        )
        let entry = try #require(detected[fixture.forkKey])
        #expect(entry.sessionIDSource == .forkParentFallback)

        let index = loadIndex(fixture: fixture, registry: registry, detectedSnapshots: detected)
        #expect(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.parentPanelId)?.sessionId == fixture.parentPiPath)
        #expect(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId)?.sessionId == fixture.parentPiPath)
    }

    @Test func piPaneHookIdentityWinsAfterForkMintsOwnSession() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try writeStore(root: fixture.root, filename: "pi-hook-sessions.json", sessions: [
            fixture.parentPiPath: hookRecord(kind: "pi", sessionId: fixture.parentPiPath, fixture: fixture, panelId: fixture.parentPanelId, updatedAt: 10),
            fixture.childPiPath: hookRecord(kind: "pi", sessionId: fixture.childPiPath, fixture: fixture, panelId: fixture.forkPanelId, updatedAt: 20),
        ])

        let registry = CmuxVaultAgentRegistry(registrations: [.builtInPi])
        let detected = detectedSnapshots(
            fixture: fixture,
            registry: registry,
            argv: ["/usr/local/bin/pi", "--session", fixture.parentPiPath, "--fork"],
            launchKind: "pi",
            processName: "pi",
            processPath: "/usr/local/bin/pi"
        )
        let index = loadIndex(fixture: fixture, registry: registry, detectedSnapshots: detected)

        #expect(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId)?.sessionId == fixture.childPiPath)
    }

    @Test func customRegistryForkTemplateWithConstantFlagDemotesParent() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let registration = customForkerRegistration()
        let registry = CmuxVaultAgentRegistry(registrations: [registration])

        let detected = detectedSnapshots(
            fixture: fixture,
            registry: registry,
            argv: ["/usr/local/bin/custom-forker", "--thread", fixture.parentCodexId, "--fork"],
            launchKind: "custom-forker",
            processName: "custom-forker",
            processPath: "/usr/local/bin/custom-forker"
        )

        let entry = try #require(detected[fixture.forkKey])
        #expect(entry.snapshot.kind == .custom("custom-forker"))
        #expect(entry.snapshot.sessionId == fixture.parentCodexId)
        #expect(entry.sessionIDSource == .forkParentFallback)
    }

    @Test func customRegistryForkTemplateWithNonForkMarkerDemotesParent() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let registration = customBranchFromRegistration()
        let registry = CmuxVaultAgentRegistry(registrations: [registration])

        let detected = detectedSnapshots(
            fixture: fixture,
            registry: registry,
            argv: ["/usr/local/bin/brancher", "--thread", fixture.parentCodexId, "--branch-from"],
            launchKind: "brancher",
            processName: "brancher",
            processPath: "/usr/local/bin/brancher"
        )

        #expect(detected[fixture.forkKey]?.sessionIDSource == .forkParentFallback)
    }

    @Test func customRegistryForkTemplateWithoutConstantMarkerStaysExplicit() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let registration = CmuxVaultAgentRegistration(
            id: "brancher",
            name: "Brancher",
            detect: CmuxVaultAgentDetectRule(processName: "brancher"),
            sessionIdSource: .argvOption("--thread"),
            resumeCommand: "{{executable}} --thread {{sessionId}}",
            forkCommand: "{{executable}} --thread {{sessionId}}"
        )
        let registry = CmuxVaultAgentRegistry(registrations: [registration])

        let detected = detectedSnapshots(
            fixture: fixture,
            registry: registry,
            argv: ["/usr/local/bin/brancher", "--thread", fixture.parentCodexId],
            launchKind: "brancher",
            processName: "brancher",
            processPath: "/usr/local/bin/brancher"
        )

        #expect(detected[fixture.forkKey]?.sessionIDSource == .explicit)
    }

    @Test func customRegistryPaneHookIdentityWinsAfterForkMintsOwnSession() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let registration = customForkerRegistration()
        let registry = CmuxVaultAgentRegistry(registrations: [registration])
        try writeStore(root: fixture.root, filename: "custom-forker-hook-sessions.json", sessions: [
            fixture.parentCodexId: hookRecord(kind: "custom-forker", sessionId: fixture.parentCodexId, fixture: fixture, panelId: fixture.parentPanelId, updatedAt: 10),
            fixture.childCodexId: hookRecord(kind: "custom-forker", sessionId: fixture.childCodexId, fixture: fixture, panelId: fixture.forkPanelId, updatedAt: 20),
        ])

        let detected = detectedSnapshots(
            fixture: fixture,
            registry: registry,
            argv: ["/usr/local/bin/custom-forker", "--thread", fixture.parentCodexId, "--fork"],
            launchKind: "custom-forker",
            processName: "custom-forker",
            processPath: "/usr/local/bin/custom-forker"
        )
        let index = loadIndex(fixture: fixture, registry: registry, detectedSnapshots: detected)

        #expect(index.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.forkPanelId)?.sessionId == fixture.childCodexId)
    }

    @Test func openCodeForkFallbackSolePaneAndAmbiguousBehaviorRemainLocked() {
        #expect(RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
            arguments: ["opencode", "--session", "parent", "--fork"],
            latestSessionIdForSolePanel: "child",
            sameWorkingDirectoryPanelCount: 1
        ) == "child")
        #expect(RestorableAgentSessionIndex.openCodeFallbackSessionIdForProcess(
            arguments: ["opencode", "--session", "parent", "--fork"],
            latestSessionIdForSolePanel: "child",
            sameWorkingDirectoryPanelCount: 2
        ) == nil)
    }

    @Test func opencodeProcessDetectedEntryWinsOverSamePaneCodexFallback() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let key = fixture.forkKey
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                processInfo(pid: 5_150, fixture: fixture, processName: "opencode", processPath: "/usr/local/bin/opencode"),
                processInfo(pid: fixture.forkProcessID, fixture: fixture, processName: "codex", processPath: "/usr/local/bin/codex"),
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fixture.fileManager,
            processSnapshot: processSnapshot,
            capturedAt: 42,
            processArgumentsProvider: { pid in
                if pid == 5_150 {
                    return processArguments(fixture: fixture, argv: ["/usr/local/bin/opencode", "--session", "oc-session"], launchKind: "opencode")
                }
                if pid == fixture.forkProcessID {
                    return processArguments(fixture: fixture, argv: ["/usr/local/bin/codex", "fork", fixture.parentCodexId], launchKind: "codex")
                }
                return nil
            }
        )

        let entry = try #require(detected[key])
        #expect(entry.snapshot.kind == .opencode)
        #expect(entry.snapshot.sessionId == "oc-session")
    }

    private struct Fixture {
        let fileManager: FileManager
        let root: URL
        let cwd: URL
        let workspaceId: UUID
        let parentPanelId: UUID
        let forkPanelId: UUID
        let parentCodexId = "019f436f-1111-4222-8333-aaaaaaaaaaaa"
        let childCodexId = "019f436f-2222-4333-8444-bbbbbbbbbbbb"
        let parentPiPath: String
        let childPiPath: String
        let forkProcessID = 5_151
        var forkKey: RestorableAgentSessionIndex.PanelKey {
            RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: forkPanelId)
        }

        static func make() throws -> Fixture {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("cmux-fork-parent-general-\(UUID().uuidString)", isDirectory: true)
            let cwd = root.appendingPathComponent("repo", isDirectory: true)
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            return Fixture(
                fileManager: fm,
                root: root,
                cwd: cwd,
                workspaceId: UUID(),
                parentPanelId: UUID(),
                forkPanelId: UUID(),
                parentPiPath: root.appendingPathComponent("parent-pi.jsonl").path,
                childPiPath: root.appendingPathComponent("child-pi.jsonl").path
            )
        }

        func cleanup() {
            try? fileManager.removeItem(at: root)
        }
    }

    private func detectedSnapshots(
        fixture: Fixture,
        registry: CmuxVaultAgentRegistry = CmuxVaultAgentRegistry(registrations: []),
        argv: [String],
        launchKind: String,
        processName: String,
        processPath: String?
    ) -> [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry] {
        let processArguments = processArguments(fixture: fixture, argv: argv, launchKind: launchKind)
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fixture.fileManager,
            processSnapshot: processSnapshot(fixture: fixture, processName: processName, processPath: processPath),
            capturedAt: 42,
            processArgumentsProvider: { $0 == fixture.forkProcessID ? processArguments : nil }
        )
    }

    private func loadIndex(
        fixture: Fixture,
        registry: CmuxVaultAgentRegistry = CmuxVaultAgentRegistry(registrations: []),
        detectedSnapshots: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry],
        processIdentityProvider: @escaping (Int) -> AgentPIDProcessIdentity? = { _ in nil }
    ) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: processIdentityProvider
        )
    }

    private func processSnapshot(fixture: Fixture, processName: String, processPath: String?) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [
                processInfo(pid: fixture.forkProcessID, fixture: fixture, processName: processName, processPath: processPath),
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
    }

    private func processInfo(pid: Int, fixture: Fixture, processName: String, processPath: String?) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: processName,
            path: processPath,
            ttyDevice: nil,
            cmuxWorkspaceID: fixture.workspaceId,
            cmuxSurfaceID: fixture.forkPanelId,
            cmuxAttributionReason: "cmux-test",
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }

    private func processArguments(fixture: Fixture, argv: [String], launchKind: String) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(arguments: argv, environment: [
            "CMUX_AGENT_LAUNCH_KIND": launchKind,
            "CMUX_AGENT_LAUNCH_CWD": fixture.cwd.path,
            "CMUX_WORKSPACE_ID": fixture.workspaceId.uuidString,
            "CMUX_SURFACE_ID": fixture.forkPanelId.uuidString,
            "CODEX_HOME": fixture.root.appendingPathComponent(".codex", isDirectory: true).path,
            "PWD": fixture.cwd.path,
        ])
    }

    private func hookRecord(
        kind: String,
        sessionId: String,
        fixture: Fixture,
        panelId: UUID,
        updatedAt: TimeInterval = 10
    ) -> [String: Any] {
        [
            "sessionId": sessionId,
            "workspaceId": fixture.workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": fixture.cwd.path,
            "pid": NSNull(),
            "updatedAt": updatedAt,
            "isRestorable": true,
            "launchCommand": [
                "launcher": kind,
                "executablePath": "/usr/local/bin/\(kind)",
                "arguments": ["/usr/local/bin/\(kind)"],
                "workingDirectory": fixture.cwd.path,
                "environment": ["CODEX_HOME": fixture.root.appendingPathComponent(".codex", isDirectory: true).path],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
    }

    private func customForkerRegistration() -> CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "custom-forker",
            name: "Custom Forker",
            detect: CmuxVaultAgentDetectRule(processName: "custom-forker"),
            sessionIdSource: .argvOption("--thread"),
            resumeCommand: "{{executable}} --thread {{sessionId}}",
            forkCommand: "{{executable}} --thread {{sessionId}} --fork"
        )
    }

    private func customBranchFromRegistration() -> CmuxVaultAgentRegistration {
        CmuxVaultAgentRegistration(
            id: "brancher",
            name: "Brancher",
            detect: CmuxVaultAgentDetectRule(processName: "brancher"),
            sessionIdSource: .argvOption("--thread"),
            resumeCommand: "{{executable}} --thread {{sessionId}}",
            forkCommand: "{{executable}} --thread {{sessionId}} --branch-from"
        )
    }

    private func writeStore(root: URL, filename: String, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": sessions], options: [.prettyPrinted])
        try data.write(to: stateDir.appendingPathComponent(filename), options: .atomic)
    }
}
