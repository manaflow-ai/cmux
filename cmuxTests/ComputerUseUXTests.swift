import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSettings
import CmuxTerminal
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use UX")
struct ComputerUseUXTests {
    private static let stateAuthenticationKey = Data(
        repeating: 0x5a,
        count: 32
    )

    @Test func missingStateDirectoryProducesEmptyScan() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result = ComputerUseStateRepository(
            authenticationKey: Self.stateAuthenticationKey
        ).scan(
            directoryURL: missingDirectory,
            sessions: [],
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )

        #expect(result == .empty)
    }

    @Test func malformedStateFileIsIgnored() throws {
        try withStateDirectory { directory in
            try Data("not-json".utf8).write(to: directory.appendingPathComponent("broken.json"))
            let result = ComputerUseStateRepository(
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                sessions: [ComputerUseSessionScope(id: "row", driverSessionID: "session-1")],
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )

            #expect(result == .empty)
        }
    }

    @Test func staleStateFileIsIgnored() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeState(
                to: directory.appendingPathComponent("stale.json"),
                pid: 42,
                session: "session-1",
                targetPID: 84,
                lastActionAt: now.addingTimeInterval(-3_601)
            )
            let result = ComputerUseStateRepository(
                recentActivityInterval: 3_600,
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                sessions: [ComputerUseSessionScope(id: "row", driverSessionID: "session-1")],
                now: now
            )

            #expect(result == .empty)
        }
    }

    @Test func newestRecentStateMustMatchStableDriverSession() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeState(
                to: directory.appendingPathComponent("matching.json"),
                pid: 99,
                session: "cmux-surface-1-mcp-101-1000",
                targetPID: 84,
                lastActionAt: now.addingTimeInterval(-20)
            )
            // A newer state from another surface must not be paired with this row.
            try writeState(
                to: directory.appendingPathComponent("foreign.json"),
                pid: 42,
                session: "cmux-surface-2-mcp-202-2000",
                targetPID: 198,
                lastActionAt: now.addingTimeInterval(-1)
            )
            let result = ComputerUseStateRepository(
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                sessions: [ComputerUseSessionScope(
                    id: "row",
                    driverSessionID: "cmux-surface-1"
                )],
                now: now
            )

            #expect(result.hasRecentStateFiles)
            #expect(result.newestStateByScopeID["row"]?.targetPID == 84)
        }
    }

    @Test func menuProjectionChoosesOnlyTheMostRecentlyActiveComputerUseSession() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let olderSurfaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let newerSurfaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            try writeState(
                to: directory.appendingPathComponent("older.json"),
                pid: 10,
                session: ComputerUseSessionScope.driverSessionID(surfaceID: olderSurfaceID),
                targetPID: 100,
                lastActionAt: now.addingTimeInterval(-10)
            )
            try writeState(
                to: directory.appendingPathComponent("newer.json"),
                pid: 20,
                session: ComputerUseSessionScope.driverSessionID(surfaceID: newerSurfaceID),
                targetPID: 200,
                lastActionAt: now.addingTimeInterval(-1)
            )

            let rows = [
                ComputerUseMenuBarRow(
                    id: "older",
                    title: "Older",
                    sessionID: "session-older",
                    workspaceID: UUID(),
                    surfaceID: olderSurfaceID,
                    rootProcessIdentities: [],
                    targetIdentity: nil,
                    targetAppName: nil,
                    stateWriterIdentity: nil,
                    proxySessionID: nil
                ),
                ComputerUseMenuBarRow(
                    id: "newer",
                    title: "Newer",
                    sessionID: "session-newer",
                    workspaceID: UUID(),
                    surfaceID: newerSurfaceID,
                    rootProcessIdentities: [],
                    targetIdentity: nil,
                    targetAppName: nil,
                    stateWriterIdentity: nil,
                    proxySessionID: nil
                ),
            ]
            let scan = ComputerUseStateRepository(
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                sessions: rows.map {
                    ComputerUseSessionScope(
                        id: $0.id,
                        driverSessionID: ComputerUseSessionScope.driverSessionID(surfaceID: $0.surfaceID)
                    )
                },
                now: now
            )
            let result = ComputerUseMenuBarScanResult(rows: rows, scan: scan)

            #expect(result.mostRecentlyActiveRow?.id == "newer")
        }
    }

    @MainActor
    @Test func onboardingAppearsUntilDirectCaptureIsReady() {
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: true, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: false, screenRecordingGranted: true,
            directCaptureReady: false))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: true, featureEnabled: true, permissionStatusIsKnown: false,
            accessibilityGranted: true, screenRecordingGranted: true,
            directCaptureReady: false))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: false, screenRecordingGranted: true,
            directCaptureReady: false))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: true, screenRecordingGranted: false,
            directCaptureReady: false))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: false,
            accessibilityGranted: true, screenRecordingGranted: true,
            directCaptureReady: false))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: true, screenRecordingGranted: true,
            directCaptureReady: false))
        #expect(!ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: true, screenRecordingGranted: true,
            directCaptureReady: true))
        #expect(!ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: false, permissionStatusIsKnown: false,
            accessibilityGranted: false, screenRecordingGranted: false,
            directCaptureReady: false))
    }

    @Test func computerUseRuntimePermissionReadinessRequiresExplicitCompletion() {
        var phase = ComputerUseRuntimePermissionPhase.disabled(
            onboardingComplete: false
        )

        phase = phase.applying(.setEnabled(true))
        #expect(phase == .onboardingRequired)

        phase = phase.applying(.onboardingPresented)
        #expect(phase == .onboarding)

        phase = phase.applying(.onboardingCompleted)
        #expect(phase == .ready)

        phase = phase.applying(.setEnabled(false))
        #expect(phase == .disabled(onboardingComplete: true))

        phase = phase.applying(.setEnabled(true))
        #expect(phase == .ready)

        phase = phase.applying(.helperReplaced)
        #expect(phase == .onboardingRequired)
    }

    @Test @MainActor func onlyRealComputerUseToolHooksTriggerOnboarding() {
        let invocation = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .preToolUse,
            source: "claude",
            toolName: "mcp__cmux-cua__start_session"
        )
        #expect(ComputerUseUXCoordinator.isComputerUseToolInvocation(invocation))

        // Sessions started by a pre-rename wrapper still carry the old server
        // name and must keep triggering onboarding.
        let legacyInvocation = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .preToolUse,
            source: "claude",
            toolName: "mcp__cmux-cua__start_session"
        )
        #expect(ComputerUseUXCoordinator.isComputerUseToolInvocation(legacyInvocation))

        let sessionStart = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .sessionStart,
            source: "claude",
            toolName: "mcp__cmux-cua__start_session"
        )
        #expect(!ComputerUseUXCoordinator.isComputerUseToolInvocation(sessionStart))

        let unrelatedTool = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .preToolUse,
            source: "claude",
            toolName: "Bash"
        )
        #expect(!ComputerUseUXCoordinator.isComputerUseToolInvocation(unrelatedTool))
    }

    @Test @MainActor
    func toolInvocationCannotOverrideDisabledComputerUseSetting() {
        #expect(ComputerUseUXCoordinator.shouldReconcileToolInvocation(
            featureEnabled: true,
            settingEnabled: true
        ))
        #expect(!ComputerUseUXCoordinator.shouldReconcileToolInvocation(
            featureEnabled: true,
            settingEnabled: false
        ))
        #expect(!ComputerUseUXCoordinator.shouldReconcileToolInvocation(
            featureEnabled: false,
            settingEnabled: true
        ))
    }

    @Test func parsesRealCuaStateFileShape() throws {
        // The helper daemon owns driver_pid while the kernel-authenticated MCP
        // proxy that issued the action is recorded independently as writer_pid.
        // This MAC is also asserted by the Rust driver test, making the
        // canonical cross-language state contract explicit.
        let json = """
        {"driver_pid":71790,"writer_pid":71600,\
        "writer_start_seconds":1700000000,"writer_start_microseconds":123456,\
        "session":null,"target_app":"Calculator",\
        "target_pid":71241,"target_window_id":87692,\
        "last_action_at":"2026-07-14T01:09:37.745752Z","schema":4,\
        "state_authentication_code":"dba2b7a606e510db5908f7c77bcdf2224c7a9764569fee7ad32aa3926928a460"}
        """
        let state = try #require(ComputerUseCuaState(
            data: Data(json.utf8),
            authenticationKey: Self.stateAuthenticationKey
        ))
        #expect(state.pid == 71790)
        #expect(state.writerPID == 71600)
        #expect(state.writerProcessIdentity.startSeconds == 1_700_000_000)
        #expect(state.writerProcessIdentity.startMicroseconds == 123_456)
        #expect(state.session == nil)
        #expect(state.targetApp == "Calculator")
        #expect(state.targetPID == 71241)
        #expect(state.targetWindowID == 87692)
        #expect(abs(state.lastActionAt.timeIntervalSince1970 - 1_783_991_377.745) < 0.01)
    }

    @Test func stateAuthenticationRejectsAgentForgedActivity() throws {
        let data = try Self.authenticatedStateData(
            driverPID: 2,
            writerPID: 3,
            writerStartSeconds: 1_700_000_000,
            writerStartMicroseconds: 123_456,
            session: "surface-a",
            targetApp: "Calculator",
            targetPID: 4,
            targetWindowID: 1,
            lastActionAt: "2026-07-14T01:09:37.745752Z"
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["target_pid"] = 99
        let forged = try JSONSerialization.data(withJSONObject: object)

        #expect(ComputerUseCuaState(
            data: forged,
            authenticationKey: Self.stateAuthenticationKey
        ) == nil)
    }

    @Test func stateEligibilityUsesAuthenticatedWriterInsteadOfHelperDaemon() throws {
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let data = try Self.authenticatedStateData(
            driverPID: 2,
            writerPID: Int(currentIdentity.pid),
            writerStartSeconds: currentIdentity.startSeconds,
            writerStartMicroseconds: currentIdentity.startMicroseconds,
            session: "surface-a",
            targetApp: "Calculator",
            targetPID: Int(currentIdentity.pid),
            targetWindowID: 1,
            lastActionAt: "2026-07-14T01:09:37.745752Z"
        )
        let state = try #require(ComputerUseCuaState(
            data: data,
            authenticationKey: Self.stateAuthenticationKey
        ))

        #expect(state.belongsToProcessTree(
            rootProcessIdentities: [currentIdentity]
        ))
    }

    @Test func menuStateScanAcceptsAuthenticatedWrapperParentOfRecordedAgent() throws {
        let writerIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let recordedAgent = Process()
        recordedAgent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        recordedAgent.arguments = ["30"]
        try recordedAgent.run()
        defer {
            if recordedAgent.isRunning {
                recordedAgent.terminate()
            }
            recordedAgent.waitUntilExit()
        }
        let recordedAgentIdentity = try #require(AgentPIDProcessIdentity(
            pid: recordedAgent.processIdentifier
        ))
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: UUID()
        )
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        try withStateDirectory { directory in
            let data = try Self.authenticatedStateData(
                driverPID: 70_001,
                writerPID: Int(writerIdentity.pid),
                writerStartSeconds: writerIdentity.startSeconds,
                writerStartMicroseconds: writerIdentity.startMicroseconds,
                session: driverSessionID,
                targetApp: "Calculator",
                targetPID: Int(writerIdentity.pid),
                targetWindowID: 1,
                lastActionAt: formatter.string(from: now)
            )
            try data.write(
                to: directory.appendingPathComponent("wrapper-parent.json"),
                options: .atomic
            )

            let result = ComputerUseStateRepository(
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                sessions: [
                    ComputerUseSessionScope(
                        id: "live-agent",
                        driverSessionID: driverSessionID
                    ),
                ],
                now: now
            ) { _, state in
                state.belongsToProcessTree(
                    rootProcessIdentities: [recordedAgentIdentity]
                )
            }

            #expect(
                result.newestStateByScopeID["live-agent"]?.writerProcessIdentity
                    == writerIdentity
            )
        }
    }

    @Test func stateEligibilityRejectsReusedWriterPIDGeneration() throws {
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let data = try Self.authenticatedStateData(
            driverPID: 2,
            writerPID: Int(currentIdentity.pid),
            writerStartSeconds: currentIdentity.startSeconds + 1,
            writerStartMicroseconds: currentIdentity.startMicroseconds,
            session: "surface-a",
            targetApp: "Calculator",
            targetPID: Int(currentIdentity.pid),
            targetWindowID: 1,
            lastActionAt: "2026-07-14T01:09:37.745752Z"
        )
        let state = try #require(ComputerUseCuaState(
            data: data,
            authenticationKey: Self.stateAuthenticationKey
        ))

        #expect(!state.belongsToProcessTree(
            rootProcessIdentities: [currentIdentity]
        ))
    }

    @Test func automaticActivationRevalidatesCurrentLogicalSession() throws {
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let data = try Self.authenticatedStateData(
            driverPID: 2,
            writerPID: Int(currentIdentity.pid),
            writerStartSeconds: currentIdentity.startSeconds,
            writerStartMicroseconds: currentIdentity.startMicroseconds,
            session: "surface-a",
            targetApp: "Calculator",
            targetPID: Int(currentIdentity.pid),
            targetWindowID: 1,
            lastActionAt: "2026-07-14T01:09:37.745752Z"
        )
        let state = try #require(ComputerUseCuaState(
            data: data,
            authenticationKey: Self.stateAuthenticationKey
        ))
        let workspaceID = UUID()
        let surfaceID = UUID()
        let scanned = ComputerUseLiveDriverSession(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            logicalSessionID: "logical-a",
            rootProcessIdentities: [currentIdentity]
        )

        #expect(scanned.authorizes(
            state: state,
            currentSession: scanned
        ))
        #expect(!scanned.authorizes(
            state: state,
            currentSession: ComputerUseLiveDriverSession(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                logicalSessionID: "replacement",
                rootProcessIdentities: [currentIdentity]
            )
        ))
    }

    @Test func generationlessLiveAgentStillProducesComputerUseMenuSession() throws {
        let processID = Int(ProcessInfo.processInfo.processIdentifier)
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "generationless-session"
            ),
            lifecycle: .running,
            updatedAt: Date().timeIntervalSince1970,
            provenance: .exactProcessBinding,
            processLiveness: .running,
            hasRecordedProcessID: true,
            processIDs: [processID],
            processIdentities: [:],
            agentProcessIDs: [processID],
            agentProcessIdentities: [:],
            hibernationPanelProcessIDs: [],
            terminationProcessIDs: [],
            terminationProcessIdentities: [:],
            containsUnrelatedProcess: false
        )

        let session = try #require(ComputerUseLiveDriverSession(
            workspaceID: UUID(),
            surfaceID: UUID(),
            entry: entry
        ))

        #expect(session.rootProcessIdentities == [currentIdentity])
    }

    @Test func exitedGenerationlessAgentCannotProduceComputerUseMenuSession() {
        let exitedProcessID = Int(Int32.max)
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "exited-generationless-session"
            ),
            lifecycle: .running,
            updatedAt: Date().timeIntervalSince1970,
            provenance: .exactProcessBinding,
            processLiveness: .running,
            hasRecordedProcessID: true,
            processIDs: [exitedProcessID],
            processIdentities: [:],
            agentProcessIDs: [exitedProcessID],
            agentProcessIdentities: [:],
            hibernationPanelProcessIDs: [],
            terminationProcessIDs: [],
            terminationProcessIdentities: [:],
            containsUnrelatedProcess: false
        )

        #expect(ComputerUseLiveDriverSession(
            workspaceID: UUID(),
            surfaceID: UUID(),
            entry: entry
        ) == nil)
    }

    /// The live v19 repro kept the Codex process and authenticated driver state
    /// alive while one SharedLiveAgentIndex refresh briefly omitted its row.
    /// Both the menu and target watcher must consume the same retained projection
    /// so that bookkeeping gap cannot look like a Computer Use disconnect.
    @Test @MainActor
    func sharedLiveSessionProjectionSurvivesTransientIndexGapUntilRootExits() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let processID = ProcessInfo.processInfo.processIdentifier
        let currentIdentity = try #require(AgentPIDProcessIdentity(pid: processID))
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "still-running-session"
            ),
            lifecycle: .running,
            updatedAt: Date().timeIntervalSince1970,
            provenance: .exactProcessBinding,
            processLiveness: .running,
            hasRecordedProcessID: true,
            processIDs: [Int(processID)],
            processIdentities: [Int(processID): currentIdentity],
            agentProcessIDs: [Int(processID)],
            agentProcessIdentities: [Int(processID): currentIdentity],
            hibernationPanelProcessIDs: [],
            terminationProcessIDs: [],
            terminationProcessIdentities: [:],
            containsUnrelatedProcess: false
        )
        var liveEntries = [(
            panelKey: RestorableAgentSessionIndex.PanelKey(
                workspaceId: workspaceID,
                panelId: surfaceID
            ),
            entry: entry
        )]
        var rootProcessIsAlive = true
        let projection = ComputerUseLiveSessionProjection(
            liveEntries: { liveEntries },
            scheduleRefreshIfStale: {},
            processIdentityIsAlive: { identity in
                rootProcessIsAlive && identity == currentIdentity
            }
        )

        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )
        #expect(projection.sessionsByDriverSessionID()[driverSessionID] != nil)

        liveEntries = []
        #expect(
            projection.sessionsByDriverSessionID()[driverSessionID] != nil,
            "A transient live-index omission must not disconnect an active proxy"
        )

        rootProcessIsAlive = false
        #expect(projection.sessionsByDriverSessionID()[driverSessionID] == nil)
    }

    @Test @MainActor
    func computerUseHookResolutionAcceptsTheCurrentProcessGenerationWhenAgentIDsDiffer() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let processID = ProcessInfo.processInfo.processIdentifier
        let currentIdentity = try #require(
            AgentPIDProcessIdentity(pid: processID)
        )
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "current-agent-generation"
            ),
            lifecycle: .running,
            updatedAt: Date().timeIntervalSince1970,
            provenance: .exactProcessBinding,
            processLiveness: .running,
            hasRecordedProcessID: true,
            processIDs: [Int(processID)],
            processIdentities: [Int(processID): currentIdentity],
            agentProcessIDs: [Int(processID)],
            agentProcessIdentities: [Int(processID): currentIdentity],
            hibernationPanelProcessIDs: [],
            terminationProcessIDs: [],
            terminationProcessIdentities: [:],
            containsUnrelatedProcess: false
        )
        let projection = ComputerUseLiveSessionProjection(
            liveEntries: {
                [(
                    panelKey: RestorableAgentSessionIndex.PanelKey(
                        workspaceId: workspaceID,
                        panelId: surfaceID
                    ),
                    entry: entry
                )]
            },
            scheduleRefreshIfStale: {}
        )
        let expectedDriverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )

        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: "current-agent-generation"
        ) == expectedDriverSessionID)
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: "replaced-agent-generation"
        ) == nil)
        #expect(projection.driverSessionID(
            surfaceID: surfaceID.uuidString,
            agentSessionID: "hook-protocol-session",
            hookProcessID: Int(processID)
        ) == expectedDriverSessionID)
        #expect(projection.driverSessionID(
            surfaceID: UUID().uuidString,
            agentSessionID: "hook-protocol-session",
            hookProcessID: Int(processID)
        ) == nil)
    }

    @Test @MainActor
    func completedComputerUseTurnRetiresOnlyStateAtOrBeforeItsCutoff() {
        let lifecycle = ComputerUseActivityLifecycle()
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: UUID()
        )
        let completion = Date(timeIntervalSince1970: 1_900_000_000)
        lifecycle.recordCompletion(
            driverSessionID: driverSessionID,
            receivedAt: completion
        )
        let cutoffs = lifecycle.completionCutoffs()

        #expect(!ComputerUseActivityLifecycle.isDisplayEligible(
            driverSessionID: driverSessionID,
            lastActionAt: completion.addingTimeInterval(-1),
            completionCutoffs: cutoffs
        ))
        #expect(!ComputerUseActivityLifecycle.isDisplayEligible(
            driverSessionID: driverSessionID,
            lastActionAt: completion,
            completionCutoffs: cutoffs
        ))
        #expect(ComputerUseActivityLifecycle.isDisplayEligible(
            driverSessionID: driverSessionID,
            lastActionAt: completion.addingTimeInterval(1),
            completionCutoffs: cutoffs
        ))
        #expect(ComputerUseActivityLifecycle.isDisplayEligible(
            driverSessionID: ComputerUseSessionScope.driverSessionID(
                surfaceID: UUID()
            ),
            lastActionAt: completion.addingTimeInterval(-1),
            completionCutoffs: cutoffs
        ))
    }

    @Test func computerUseSettingsNavigationRawValuesStayInSync() {
        #expect(SettingsSectionID.computerUse.rawValue == SettingsNavigationTarget.computerUse.rawValue)
    }

    @Test func targetIdentityFailsClosedWhenPIDIdentityChanges() {
        let launchDate = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = ComputerUseTargetIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate
        )

        #expect(identity.matches(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate
        ))
        #expect(!identity.matches(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Recycled",
            launchDate: launchDate
        ))
        #expect(!identity.matches(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate.addingTimeInterval(1)
        ))
        #expect(!identity.matches(
            processIdentifier: 43,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate
        ))
    }

    @Test @MainActor func onboardingCreatesFreshWindowAndRootForEveryRun() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let first = controller.makeWindow()
        let second = controller.makeWindow()
        defer {
            first.close()
            second.close()
        }

        #expect(first !== second)
        #expect(first.contentView !== second.contentView)
        #expect(first.frame.size == CGSize(width: 600, height: 440))
        #expect(first.contentView?.frame.size == CGSize(width: 600, height: 440))
        #expect(!first.styleMask.contains(.miniaturizable))
        #expect(!first.styleMask.contains(.resizable))
        #expect(!first.hasShadow)
    }

    @Test @MainActor func onboardingContentCannotOutgrowItsAppKitWindow() async {
        let expandedSize = CGSize(width: 600, height: 440)
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let oversizedContent = Color.clear.frame(width: 680, height: 883)
        let window = ComputerUseOnboardingWindow(
            contentRect: NSRect(origin: .zero, size: expandedSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let contentView = ComputerUseOnboardingHostingView(rootView: oversizedContent)
        window.contentView = contentView
        defer { window.close() }
        window.center()
        window.orderBack(nil)
        #expect(window.isVisible)

        // The live failure repeatedly measured the host at 883 points high,
        // then AppKit terminated cmux after its recursive constraint-pass limit
        // was exceeded. Drive real visible SwiftUI/AppKit layout passes at both
        // controller-owned onboarding sizes instead of invoking a frame setter.
        for expectedSize in [expandedSize, companionSize, expandedSize] {
            window.setAppKitOwnedFrame(
                NSRect(origin: window.frame.origin, size: expectedSize),
                display: true
            )
            if expectedSize == companionSize {
                let placementFrame = NSRect(
                    origin: NSPoint(x: window.frame.minX + 12, y: window.frame.minY + 12),
                    size: expectedSize
                )
                window.setFrame(placementFrame, display: true, animate: false)
                #expect(window.frame == placementFrame)
            }
            for _ in 0..<12 {
                contentView.invalidateIntrinsicContentSize()
                contentView.needsLayout = true
                contentView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await Task.yield()
            }

            #expect(window.frame.size == expectedSize)
            #expect(contentView.frame.size == expectedSize)
        }
    }

    @Test @MainActor func permissionCompanionUsesItsEntireFixedFrameForContent() {
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }

        controller.configureForPermissionCompanion(
            mainWindow,
            frame: NSRect(origin: mainWindow.frame.origin, size: companionSize)
        )
        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }

        #expect(mainWindow.frame.size == CGSize(width: 600, height: 440))
        #expect(companionWindow?.frame.size == companionSize)
        #expect(companionWindow?.contentView?.frame.size == companionSize)
        #expect(companionWindow?.contentLayoutRect.size == companionSize)
    }

    @Test @MainActor func permissionCompanionLeavesMainWindowChromeUntouched() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let window = controller.makeWindow()
        defer { window.close() }
        let expandedStyle = window.styleMask
        let expandedFrame = window.frame

        controller.prepareForPermissionCompanion(window)

        #expect(window.styleMask == expandedStyle)
        #expect(window.frame == expandedFrame)
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(window.standardWindowButton(buttonType)?.isHidden == false)
        }
    }

    @Test @MainActor func preparingPermissionCompanionHidesMainWindowWithoutMutatingItsChrome() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let window = controller.makeWindow()
        defer { window.close() }
        window.center()
        window.orderBack(nil)
        let expandedFrame = window.frame
        let expandedStyle = window.styleMask
        let standardButtonVisibility = [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].map { window.standardWindowButton($0)?.isHidden }

        controller.prepareForPermissionCompanion(window)

        #expect(!window.isVisible)
        #expect(window.frame == expandedFrame)
        #expect(window.styleMask == expandedStyle)
        #expect([
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].map { window.standardWindowButton($0)?.isHidden } == standardButtonVisibility)
    }

    @Test @MainActor func permissionCompanionUsesASeparateBorderlessWindow() {
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }
        mainWindow.center()
        mainWindow.orderBack(nil)
        let mainFrame = mainWindow.frame
        let destinationFrame = NSRect(
            x: mainFrame.maxX + 24,
            y: mainFrame.midY - companionSize.height / 2,
            width: companionSize.width,
            height: companionSize.height
        )

        controller.configureForPermissionCompanion(
            mainWindow,
            frame: destinationFrame
        )

        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }
        #expect(!mainWindow.isVisible)
        #expect(mainWindow.frame == mainFrame)
        #expect(companionWindow !== mainWindow)
        #expect(companionWindow?.styleMask == [.borderless, .nonactivatingPanel])
        #expect(companionWindow?.frame == destinationFrame)
        #expect(companionWindow?.contentLayoutRect.size == companionSize)
        #expect(companionWindow?.standardWindowButton(.closeButton) == nil)
        #expect(companionWindow?.standardWindowButton(.miniaturizeButton) == nil)
        #expect(companionWindow?.standardWindowButton(.zoomButton) == nil)
        #expect(companionWindow?.hasShadow == false)
    }

    @Test @MainActor func completionClosesCompanionAndRevealsCenteredMainWindowWithoutReturnGlide() {
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }
        mainWindow.center()
        mainWindow.orderBack(nil)
        let originalMainFrame = mainWindow.frame
        let destinationFrame = NSRect(
            x: originalMainFrame.maxX + 24,
            y: originalMainFrame.midY - companionSize.height / 2,
            width: companionSize.width,
            height: companionSize.height
        )
        controller.configureForPermissionCompanion(
            mainWindow,
            frame: destinationFrame
        )
        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }
        #expect(companionWindow?.isVisible == true)
        let visibleFrame = mainWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? originalMainFrame
        let expandedSize = CGSize(width: 600, height: 440)
        let expectedCenteredFrame = NSRect(
            x: visibleFrame.midX - expandedSize.width / 2,
            y: visibleFrame.midY - expandedSize.height / 2,
            width: expandedSize.width,
            height: expandedSize.height
        )

        controller.revealExpandedOnboarding(
            mainWindow,
            resetStep: false,
            completed: true
        )

        #expect(companionWindow?.isVisible == false)
        #expect(mainWindow.isVisible)
        #expect(mainWindow.frame.size == expandedSize)
        #expect(abs(mainWindow.frame.midX - expectedCenteredFrame.midX) <= 0.5)
        #expect(abs(mainWindow.frame.midY - expectedCenteredFrame.midY) <= 0.5)
    }

    /// Regression: interacting with the companion beside System Settings
    /// (dragging the helper tile, pressing Back) must never activate cmux —
    /// activation raised the main terminal window over the permission pane the
    /// user was dragging into.
    @Test @MainActor func permissionCompanionNeverActivatesTheApp() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let mainWindow = controller.makeWindow()
        defer {
            controller.dismiss()
            mainWindow.close()
        }

        controller.configureForPermissionCompanion(
            mainWindow,
            frame: NSRect(
                origin: .zero,
                size: ComputerUsePermissionCompanionLayout.size
            )
        )
        let companionWindow = NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.computerUse.onboarding.permissionCompanion"
        }

        let companionPanel = companionWindow as? NSPanel
        #expect(companionPanel != nil)
        #expect(companionPanel?.styleMask.contains(.nonactivatingPanel) == true)
        #expect(companionPanel?.becomesKeyOnlyIfNeeded == true)
        #expect(companionPanel?.hidesOnDeactivate == false)
    }

    /// The helper drag tile itself must also suppress activation: the press
    /// that starts a Finder-compatible drag is not a request to front cmux.
    @Test @MainActor func helperAppDragSourceDelaysWindowOrdering() throws {
        let dragSource = ComputerUseAppDragSourceView()
        let press = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        #expect(dragSource.shouldDelayWindowOrdering(for: press))
    }

    /// While the direct-capture probe can raise Tahoe's consent alert, the
    /// companion must explain that alert instead of stale drag instructions.
    @Test func companionMessageExplainsPendingScreenCaptureConsent() {
        #expect(
            ComputerUsePermissionCompanionMessage.resolve(
                permissionStep: .accessibility,
                screenCaptureConsentPending: false
            ) == .dragIntoAccessibility
        )
        #expect(
            ComputerUsePermissionCompanionMessage.resolve(
                permissionStep: .screenRecording,
                screenCaptureConsentPending: false
            ) == .dragIntoScreenshots
        )
        #expect(
            ComputerUsePermissionCompanionMessage.resolve(
                permissionStep: .screenRecording,
                screenCaptureConsentPending: true
            ) == .confirmScreenCapture
        )
        #expect(
            ComputerUsePermissionCompanionMessage.resolve(
                permissionStep: .accessibility,
                screenCaptureConsentPending: true
            ) == .confirmScreenCapture
        )
    }

    /// Regression: Tahoe's direct-capture consent follows the helper's code
    /// signature. After a helper rebuild the cached ready flag must drop, so
    /// onboarding re-presents and the system "bypass" alert appears with the
    /// onboarding explanation instead of mid-session with none.
    @Test @MainActor func replacingTheInstalledHelperInvalidatesDirectCaptureReady() throws {
        let suiteName = "cmux.tests.directCapture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = ComputerUseOnboardingWindowController.directCaptureReadyDefaultsKey
        defaults.set(true, forKey: key)

        ComputerUseOnboardingWindowController.invalidateDirectCaptureReady(in: defaults)

        #expect(!defaults.bool(forKey: key))
        #expect(
            ComputerUseOnboardingWindowController.shouldPresentAutomatically(
                seen: true,
                featureEnabled: true,
                permissionStatusIsKnown: true,
                accessibilityGranted: true,
                screenRecordingGranted: true,
                directCaptureReady: defaults.bool(forKey: key)
            )
        )
    }

    @Test @MainActor func screenCaptureConsentPendingTracksTheProbe() {
        let presentationState = ComputerUseOnboardingPresentationState()
        #expect(!presentationState.screenCaptureConsentPending)

        presentationState.beginScreenCaptureConsent()
        #expect(presentationState.screenCaptureConsentPending)

        presentationState.endScreenCaptureConsent()
        #expect(!presentationState.screenCaptureConsentPending)
    }

    @Test @MainActor
    func permissionCompanionPublishesItsRecoveredStatusToTheMainOnboarding() {
        let presentationState = ComputerUseOnboardingPresentationState()

        presentationState.publishPermissionSnapshot(
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: true
        )

        #expect(
            presentationState.permissionSnapshot
                == ComputerUseOnboardingPermissionSnapshot(
                    statusIsKnown: true,
                    accessibilityGranted: true,
                    screenRecordingGranted: true
                )
        )
    }

    /// Regression: ScreenCaptureKit can return from its first direct-content
    /// query while Tahoe's system consent sheet is still waiting for a user
    /// decision. The companion must remain visible and completion must not
    /// replace it until that prompt-capable verification has actually ended.
    @Test @MainActor func pendingScreenCaptureConsentCannotShowCompletion() {
        let presentationState = ComputerUseOnboardingPresentationState()
        presentationState.showPermissionCompanion()
        presentationState.beginScreenCaptureConsent()

        presentationState.showCompletionInExpandedOnboarding()

        #expect(presentationState.screenCaptureConsentPending)
        #expect(presentationState.permissionCompanionVisible)
        #expect(!presentationState.onboardingComplete)
    }

    /// Keep the permission companion at the wider, compact proportions that
    /// make the app row read as one full-width drag target.
    @Test func permissionCompanionUsesTheApprovedCompactProportions() {
        let size = ComputerUsePermissionCompanionLayout.size

        #expect(size == CGSize(width: 472, height: 112))
        #expect(ComputerUsePermissionCompanionLayout.horizontalInset == 12)
        #expect(ComputerUsePermissionCompanionLayout.verticalInset == 8)
        #expect(ComputerUsePermissionCompanionLayout.leadingColumnWidth == 40)
        #expect(ComputerUsePermissionCompanionLayout.headerHeight == 48)
        #expect(ComputerUsePermissionCompanionLayout.dragRowHeight == 40)
        #expect(ComputerUsePermissionCompanionLayout.columnSpacing == 8)
        #expect(ComputerUsePermissionCompanionLayout.rowSpacing == 8)
    }

    @Test func permissionCompanionUsesOneAlignmentGrid() {
        let instructionLeadingEdge = ComputerUsePermissionCompanionLayout.horizontalInset
            + ComputerUsePermissionCompanionLayout.leadingColumnWidth
            + ComputerUsePermissionCompanionLayout.columnSpacing
        let dragTileLeadingEdge = ComputerUsePermissionCompanionLayout.horizontalInset
            + ComputerUsePermissionCompanionLayout.leadingColumnWidth
            + ComputerUsePermissionCompanionLayout.columnSpacing

        #expect(instructionLeadingEdge == dragTileLeadingEdge)
        #expect(
            ComputerUsePermissionCompanionLayout.verticalInset * 2
                + ComputerUsePermissionCompanionLayout.headerHeight
                + ComputerUsePermissionCompanionLayout.rowSpacing
                + ComputerUsePermissionCompanionLayout.dragRowHeight
                == ComputerUsePermissionCompanionLayout.size.height
        )
    }

    @Test func permissionCompanionStartsSmallAndCenteredOverMainWindow() {
        let mainFrame = NSRect(x: 100, y: 200, width: 600, height: 440)

        let companionFrame = ComputerUseOnboardingWindowController
            .permissionCompanionStartingFrame(centeredOver: mainFrame)

        #expect(companionFrame.size == ComputerUsePermissionCompanionLayout.size)
        #expect(companionFrame.midX == mainFrame.midX)
        #expect(companionFrame.midY == mainFrame.midY)
    }

    @Test @MainActor func permissionCompanionTransitionAllowsIntermediateWindowFrames() {
        let expandedSize = CGSize(width: 600, height: 440)
        let companionSize = ComputerUsePermissionCompanionLayout.size
        let window = ComputerUseOnboardingWindow(
            contentRect: NSRect(origin: .zero, size: expandedSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let startingFrame = window.frame
        let destinationFrame = NSRect(
            x: startingFrame.minX + 160,
            y: startingFrame.minY + 120,
            width: companionSize.width,
            height: companionSize.height
        )
        let intermediateFrame = NSRect(
            x: (startingFrame.minX + destinationFrame.minX) / 2,
            y: (startingFrame.minY + destinationFrame.minY) / 2,
            width: (startingFrame.width + destinationFrame.width) / 2,
            height: (startingFrame.height + destinationFrame.height) / 2
        )
        var observedIntermediateFrame: NSRect?
        window.withAppKitOwnedFrameTransition(
            to: destinationFrame,
            duration: 0.05
        ) {
            window.setFrame(intermediateFrame, display: false)
            observedIntermediateFrame = window.frame
            window.setFrame(destinationFrame, display: false)
        }

        #expect(observedIntermediateFrame == intermediateFrame)
        #expect(window.frame == destinationFrame)

        window.setFrame(startingFrame, display: false)
        #expect(window.frame == destinationFrame)
    }

    @Test func permissionCompanionAnimationHonorsReduceMotion() {
        #expect(ComputerUseOnboardingWindowController.permissionCompanionGlideDuration >= 0.4)
        #expect(ComputerUseOnboardingWindowController.permissionCompanionGlideDuration <= 0.6)
        #expect(ComputerUseOnboardingWindowController.shouldAnimate(
            windowIsVisible: true,
            reduceMotion: false
        ))
        #expect(!ComputerUseOnboardingWindowController.shouldAnimate(
            windowIsVisible: true,
            reduceMotion: true
        ))
        #expect(!ComputerUseOnboardingWindowController.shouldAnimate(
            windowIsVisible: false,
            reduceMotion: false
        ))
    }

    @Test func permissionRowsKeepTheAllowActionUntilTheGrantIsKnown() {
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: false,
            statusIsKnown: true,
            systemSettingsOpened: false
        ) == .allow)
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: false,
            statusIsKnown: true,
            systemSettingsOpened: true
        ) == .allow)
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: true,
            statusIsKnown: true,
            systemSettingsOpened: true
        ) == .done)
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: true,
            statusIsKnown: false,
            systemSettingsOpened: true
        ) == .allow)

        #expect(ComputerUsePermissionRowAction.allow.destination == .systemSettings)
        #expect(ComputerUsePermissionRowAction.done.destination == nil)
    }

    @Test func permissionProgressAdvancesInPlaceToTheNextMissingGrant() {
        #expect(ComputerUseOnboardingStep.nextMissingPermission(
            statusIsKnown: true,
            accessibilityGranted: false,
            screenRecordingGranted: false
        ) == .accessibility)
        #expect(ComputerUseOnboardingStep.nextMissingPermission(
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: false
        ) == .screenRecording)
        #expect(ComputerUseOnboardingStep.nextMissingPermission(
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: true
        ) == .complete)
        #expect(ComputerUseOnboardingStep.nextMissingPermission(
            statusIsKnown: false,
            accessibilityGranted: true,
            screenRecordingGranted: true
        ) == nil)
    }

    @Test @MainActor func permissionCompanionReportsLayoutReadinessBeforeWindowMovement() {
        let state = ComputerUseOnboardingPresentationState()

        state.showPermissionCompanion()
        #expect(state.permissionCompanionVisible)
        #expect(!state.permissionCompanionLayoutReady)

        state.markPermissionCompanionLayoutReady()
        #expect(state.permissionCompanionLayoutReady)

        state.requestReturnToOverview()
        #expect(!state.permissionCompanionVisible)
        #expect(!state.permissionCompanionLayoutReady)
    }

    @Test @MainActor func completedOnboardingReturnsToExpandedMainWindow() {
        let state = ComputerUseOnboardingPresentationState()
        state.showPermissionCompanion()
        state.markPermissionCompanionLayoutReady()

        state.showCompletionInExpandedOnboarding()

        #expect(!state.permissionCompanionVisible)
        #expect(!state.permissionCompanionLayoutReady)
        #expect(state.onboardingComplete)
    }

    @Test func permissionAdvancementWaitsForEachExplicitAllowAndDirectCapture() {
        #expect(ComputerUseOnboardingAdvance.resolve(
            activeStep: .overview,
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            directCaptureReady: false
        ) == .none)
        #expect(ComputerUseOnboardingAdvance.resolve(
            activeStep: .accessibility,
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            directCaptureReady: false
        ) == .requestSecondAllow)
        #expect(ComputerUseOnboardingAdvance.resolve(
            activeStep: .accessibility,
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            directCaptureReady: false
        ) == .requestSecondAllow)
        #expect(ComputerUseOnboardingAdvance.resolve(
            activeStep: .screenRecording,
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            directCaptureReady: false
        ) == .verifyScreenCapture)
        #expect(ComputerUseOnboardingAdvance.resolve(
            activeStep: .screenRecording,
            statusIsKnown: true,
            accessibilityGranted: true,
            screenRecordingGranted: true,
            directCaptureReady: true
        ) == .complete)

        #expect(ComputerUseOnboardingAllowAction.resolve(
            permissionStep: .screenRecording,
            statusIsKnown: true,
            screenRecordingGranted: false,
            directCaptureReady: false
        ) == .openSystemSettings)
        #expect(ComputerUseOnboardingAllowAction.resolve(
            permissionStep: .screenRecording,
            statusIsKnown: true,
            screenRecordingGranted: true,
            directCaptureReady: false
        ) == .verifyScreenCapture)
        #expect(ComputerUseOnboardingAllowAction.resolve(
            permissionStep: .screenRecording,
            statusIsKnown: true,
            screenRecordingGranted: true,
            directCaptureReady: true
        ) == .none)
    }

    @Test func completedOnboardingRemainsVisibleBeforeAutomaticDismissal() {
        #expect(ComputerUseOnboardingStep.complete.rawValue > ComputerUseOnboardingStep.screenRecording.rawValue)
        #expect(ComputerUseOnboardingWindowController.completionDismissDelay >= .seconds(2))
    }

    @Test
    func permissionRowsRemainActionableWhileTheHelperIsBeingPrepared() {
        #expect(ComputerUsePermissionRowAction.isButtonEnabled(
            helperIsReady: false,
            permissionSetupInFlight: false
        ))
        #expect(ComputerUsePermissionRowAction.isButtonEnabled(
            helperIsReady: true,
            permissionSetupInFlight: false
        ))
        #expect(!ComputerUsePermissionRowAction.isButtonEnabled(
            helperIsReady: true,
            permissionSetupInFlight: true
        ))
    }

    @Test @MainActor
    func onboardingRendersAdaptiveComputerUseArtworkWithoutLaunchServices() throws {
        let helperAppURL = URL(fileURLWithPath: "/fixture/cmux Computer Use.app")
        let artwork = NSImage(size: NSSize(width: 32, height: 32))
        var artworkRequests: [URL] = []
        var fallbackRequests: [URL] = []

        let icon = try #require(ComputerUseRuntimeService.resolvePresentationIcon(
            helperAppURL: helperAppURL,
            loadArtwork: { url in
                artworkRequests.append(url)
                return artwork
            },
            loadFallbackIcon: { url in
                fallbackRequests.append(url)
                return nil
            }
        ))

        #expect(icon !== artwork)
        #expect(artworkRequests.isEmpty)
        #expect(fallbackRequests.isEmpty)
    }

    @Test @MainActor
    func computerUseHelperArtworkMatchesTheCurrentAppearance() throws {
        let helperAppURL = URL(fileURLWithPath: "/fixture/cmux Computer Use.app")
        let staticArtwork = NSImage(
            size: NSSize(width: 32, height: 32),
            flipped: false
        ) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }

        func resolvedIcon(named appearanceName: NSAppearance.Name) throws -> NSImage {
            let appearance = try #require(NSAppearance(named: appearanceName))
            var resolved: NSImage?
            appearance.performAsCurrentDrawingAppearance {
                resolved = ComputerUseRuntimeService.resolvePresentationIcon(
                    helperAppURL: helperAppURL,
                    darkMode: appearanceName == .darkAqua,
                    loadArtwork: { _ in staticArtwork },
                    loadFallbackIcon: { _ in nil }
                )
            }
            return try #require(resolved)
        }

        let lightIcon = try resolvedIcon(named: .aqua)
        let darkIcon = try resolvedIcon(named: .darkAqua)
        let lightPlate = try Self.compositedIconColor(lightIcon, appearance: .aqua)
        let darkPlate = try Self.compositedIconColor(darkIcon, appearance: .darkAqua)
        let lightCorner = try Self.sampledIconColor(lightIcon, x: 0, y: 0)
        let darkCorner = try Self.sampledIconColor(darkIcon, x: 0, y: 0)

        #expect(lightPlate.brightnessComponent > 0.7)
        #expect(darkPlate.brightnessComponent < 0.4)
        #expect(lightCorner.alphaComponent < 0.01)
        #expect(darkCorner.alphaComponent < 0.01)
    }

    @Test @MainActor func firstUseOnboardingStartsAtOverview() {
        #expect(ComputerUseOnboardingView.initialStep == .overview)
    }

    @Test func permissionCompanionSitsBesideSystemSettingsOnItsActualDisplay() throws {
        let placement = ComputerUseOnboardingWindowPlacement(gap: 12, screenInset: 16)
        let primaryDisplay = CGRect(x: 0, y: 0, width: 1_512, height: 949)
        let externalDisplay = CGRect(x: -575, y: 982, width: 1_920, height: 1_080)
        let systemSettings = placement.appKitFrame(
            fromQuartz: CGRect(x: 225, y: -1_003, width: 723, height: 762),
            primaryScreenMaxY: 982
        )
        let permissionDisplay = try #require(placement.visibleFrame(
            containing: systemSettings,
            candidates: [primaryDisplay, externalDisplay]
        ))

        let onboarding = placement.frame(
            onboardingSize: ComputerUsePermissionCompanionLayout.size,
            beside: systemSettings,
            in: permissionDisplay
        )

        #expect(systemSettings == CGRect(x: 225, y: 1_223, width: 723, height: 762))
        #expect(permissionDisplay == externalDisplay)
        #expect(externalDisplay.contains(onboarding))
        #expect(onboarding.intersects(systemSettings))
        #expect(onboarding.maxX == systemSettings.maxX - 12)
        #expect(onboarding.minY == systemSettings.minY + 12)
    }

    @Test @MainActor func permissionOnboardingStartsAtTheRequestedStep() {
        #expect(ComputerUseOnboardingWindowController.StartingPoint.overview.step == .overview)
        #expect(ComputerUseOnboardingWindowController.StartingPoint.accessibility.step == .accessibility)
        #expect(ComputerUseOnboardingWindowController.StartingPoint.screenRecording.step == .screenRecording)
    }

    @Test @MainActor func onboardingWindowUsesOnlyExplicitHeaderDragRegion() {
        let controller = ComputerUseOnboardingWindowController(
            runtimeService: ComputerUseRuntimeService()
        )
        let window = controller.makeWindow()
        defer { window.close() }

        #expect(!window.isMovableByWindowBackground)
    }

    @Test @MainActor func helperCardExportsFinderCompatibleAppPayload() {
        let helperURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let item = ComputerUseAppDragSourceView.pasteboardItem(for: helperURL)

        #expect(item.string(forType: .fileURL) == helperURL.absoluteString)
        #expect(item.types == [.fileURL])
    }

    @Test func taggedRuntimeKeepsHelperSocketAndStateIsolated() {
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            socketRootDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
            userIdentifier: 501,
            environment: ["CMUX_TAG": "permission-owner-v2"],
            authenticationToken: "test-token"
        )

        #expect(paths.scope == "permission-owner-v2-b557c76d99865947")
        #expect(paths.daemonSocketURL.path == "/tmp/cmux-cua-501/\(paths.scope)/cmux-cua.sock")
        #expect(
            paths.codexDaemonSocketURL.path
                == "/tmp/cmux-cua-501/\(paths.scope)/cmux-cua-codex.sock"
        )
        #expect(paths.stateDirectoryURL.path.hasSuffix(
            "/Library/Application Support/cmux/cmux-cua/runtime/\(paths.scope)/state"
        ))
        #expect(
            paths.permissionDatabaseDirectoryURL.path
                == "/Users/tester/Library/Application Support/com.apple.TCC"
        )
        #expect(paths.installedHelperAppURL.path.hasSuffix(
            "/Library/Application Support/cmux/cmux-cua/helper/\(paths.scope)/cmux Computer Use.app"
        ))
        #expect(
            paths.installedHelperExecutableURL.path
                == paths.installedHelperAppURL
                    .appendingPathComponent("Contents/MacOS/cmux-cua")
                    .path
        )
    }

    @Test func onlyExactSurfaceDerivedDriverSessionsAreManaged() {
        let surfaceID = UUID()
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )
        #expect(ComputerUseSessionScope.isManagedDriverSessionID(driverSessionID))
        #expect(!ComputerUseSessionScope.isManagedDriverSessionID(
            "cmux-\(surfaceID.uuidString)-mcp-1"
        ))
        #expect(!ComputerUseSessionScope.isManagedDriverSessionID("default"))
        #expect(!ComputerUseSessionScope.isManagedDriverSessionID("cmux-not-a-uuid"))
        #expect(ComputerUseSessionScope.isManagedProxySessionID(
            "\(driverSessionID)-mcp-42-1000",
            for: driverSessionID
        ))
        let nativeEndRequest = ComputerUseRuntimeService.endDriverSessionRequest(
            driverSessionID: driverSessionID,
            proxySessionID: "\(driverSessionID)-mcp-42-1000",
            profile: .native
        )
        #expect(nativeEndRequest?["method"] as? String == "call")
        #expect(nativeEndRequest?["name"] as? String == "end_session")
        #expect(
            (nativeEndRequest?["args"] as? [String: String])?["session"]
                == "\(driverSessionID)-mcp-42-1000"
        )
        let codexEndRequest = ComputerUseRuntimeService.endDriverSessionRequest(
            driverSessionID: driverSessionID,
            proxySessionID: "\(driverSessionID)-mcp-42-1000",
            profile: .codexCompatibility
        )
        #expect(codexEndRequest?["method"] as? String == "session_end")
        #expect(
            codexEndRequest?["session_id"] as? String
                == "\(driverSessionID)-mcp-42-1000"
        )
        #expect(codexEndRequest?["name"] == nil)
        #expect(codexEndRequest?["args"] == nil)

        let nativeCursorRequest =
            ComputerUseRuntimeService.setDriverCursorVisibleRequest(
                true,
                driverSessionID: driverSessionID,
                profile: .native
            )
        #expect(nativeCursorRequest?["method"] as? String == "call")
        #expect(
            nativeCursorRequest?["name"] as? String
                == "set_agent_cursor_enabled"
        )
        #expect(
            (nativeCursorRequest?["args"] as? [String: Any])?["cursor_id"]
                as? String == driverSessionID
        )
        #expect(
            (nativeCursorRequest?["args"] as? [String: Any])?["_host_session"]
                as? String == driverSessionID
        )
        #expect(
            (nativeCursorRequest?["args"] as? [String: Any])?["enabled"]
                as? Bool == true
        )

        let codexCursorRequest =
            ComputerUseRuntimeService.setDriverCursorVisibleRequest(
                false,
                driverSessionID: driverSessionID,
                profile: .codexCompatibility
            )
        #expect(
            codexCursorRequest?["method"] as? String
                == "set_cursor_enabled"
        )
        #expect(
            (codexCursorRequest?["args"] as? [String: Any])?["session"]
                as? String == driverSessionID
        )
        #expect(
            (codexCursorRequest?["args"] as? [String: Any])?["enabled"]
                as? Bool == false
        )
        #expect(codexCursorRequest?["name"] == nil)

        let proxyCursorSessionID =
            "\(driverSessionID)-mcp-42-1000"
        let generationScopedCursorRequest =
            ComputerUseRuntimeService.setDriverCursorVisibleRequest(
                false,
                driverSessionID: driverSessionID,
                profile: .codexCompatibility,
                proxySessionID: proxyCursorSessionID
            )
        #expect(
            (generationScopedCursorRequest?["args"] as? [String: Any])?["generation"]
                as? String == proxyCursorSessionID,
            "Turn completion visibility must be scoped to the proxy generation that started it"
        )
        let proxyCursorRequest =
            ComputerUseRuntimeService.setDriverCursorVisibleRequest(
                false,
                driverSessionID: proxyCursorSessionID,
                profile: .codexCompatibility
            )
        #expect(
            (proxyCursorRequest?["args"] as? [String: Any])?["session"]
                as? String == driverSessionID,
            "Compatibility cursor visibility must target the stable surface session"
        )
        #expect(
            (proxyCursorRequest?["args"] as? [String: Any])?["enabled"]
                as? Bool == false
        )

        let compatReassertRequest =
            ComputerUseRuntimeService.reassertDriverCursorRequest(
                driverSessionID: proxyCursorSessionID,
                targetWindowID: 42,
                profile: .codexCompatibility
            )
        #expect(
            (compatReassertRequest?["args"] as? [String: Any])?["session"]
                as? String == driverSessionID,
            "Compatibility reassertion must use the stable surface cursor key"
        )

        let reassertRequest = ComputerUseRuntimeService.reassertDriverCursorRequest(
            driverSessionID: driverSessionID,
            targetWindowID: 42,
            profile: .native
        )
        #expect(reassertRequest?["method"] as? String == "reassert_cursor")
        #expect(
            (reassertRequest?["args"] as? [String: Any])?["session"]
                as? String == driverSessionID
        )
        #expect(
            (reassertRequest?["args"] as? [String: Any])?["window_id"]
                as? Int == 42
        )
        #expect(
            (reassertRequest?["args"] as? [String: Any])?["enabled"] == nil,
            "A focus reassertion may only repair z-order; lifecycle visibility belongs to the serialized show/hide path"
        )
        #expect(
            ComputerUseRuntimeService.reassertDriverCursorRequest(
                driverSessionID: "foreign-session",
                targetWindowID: 42,
                profile: .native
            ) == nil
        )
        #expect(
            ComputerUseRuntimeService.reassertDriverCursorRequest(
                driverSessionID: driverSessionID,
                targetWindowID: 0,
                profile: .native
            ) == nil
        )

        #expect(ComputerUseSessionScope.isManagedProxySessionID(
            driverSessionID,
            for: driverSessionID
        ))
        #expect(ComputerUseRuntimeService.endDriverSessionRequest(
            driverSessionID: driverSessionID,
            proxySessionID: driverSessionID,
            profile: .native
        ).flatMap { request in
            (request["args"] as? [String: String])?["session"]
        } == driverSessionID)
        #expect(!ComputerUseSessionScope.isManagedProxySessionID(
            "\(driverSessionID)-mcp-",
            for: driverSessionID
        ))
        #expect(!ComputerUseSessionScope.isManagedProxySessionID(
            "cmux-\(UUID().uuidString)-mcp-42-1000",
            for: driverSessionID
        ))
    }

    @Test func helperTerminationRecoveryIgnoresIntentionalAndForeignExits() {
        let helperURL = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support/cmux/cmux-cua/helper/tag/cmux Computer Use.app"
        )
        let helperBundleIdentifier = "com.cmuxterm.cua"

        #expect(ComputerUseRuntimeService.shouldRecoverAfterHelperTermination(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            wasExpected: false,
            terminatedBundleIdentifier: helperBundleIdentifier,
            terminatedBundleURL: helperURL,
            helperBundleIdentifier: helperBundleIdentifier,
            helperBundleURL: helperURL
        ))
        #expect(!ComputerUseRuntimeService.shouldRecoverAfterHelperTermination(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            wasExpected: true,
            terminatedBundleIdentifier: helperBundleIdentifier,
            terminatedBundleURL: helperURL,
            helperBundleIdentifier: helperBundleIdentifier,
            helperBundleURL: helperURL
        ))
        #expect(!ComputerUseRuntimeService.shouldRecoverAfterHelperTermination(
            desiredEnabled: false,
            acceptsNewLaunches: true,
            wasExpected: false,
            terminatedBundleIdentifier: helperBundleIdentifier,
            terminatedBundleURL: helperURL,
            helperBundleIdentifier: helperBundleIdentifier,
            helperBundleURL: helperURL
        ))
        #expect(!ComputerUseRuntimeService.shouldRecoverAfterHelperTermination(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            wasExpected: false,
            terminatedBundleIdentifier: "com.example.foreign.helper",
            terminatedBundleURL: URL(fileURLWithPath: "/Applications/Other Helper.app"),
            helperBundleIdentifier: helperBundleIdentifier,
            helperBundleURL: helperURL
        ))
    }

    @Test func trackedHelperTerminationRecoversWhenLaunchServicesDropsBundleMetadata() {
        let helperURL = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support/cmux/cmux-cua/helper/tag/cmux Computer Use.app"
        )

        #expect(ComputerUseRuntimeService.shouldRecoverAfterHelperTermination(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            wasExpected: false,
            isTrackedHelperProcess: true,
            terminatedBundleIdentifier: nil,
            terminatedBundleURL: nil,
            helperBundleIdentifier: "com.cmuxterm.cua",
            helperBundleURL: helperURL
        ))
    }

    @Test func enabledRuntimeRepairsADeadDaemonWithoutATerminationNotification() {
        #expect(ComputerUseRuntimeService.shouldScheduleHelperRecovery(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            daemonListening: false,
            recoveryInFlight: false
        ))
        #expect(!ComputerUseRuntimeService.shouldScheduleHelperRecovery(
            desiredEnabled: false,
            acceptsNewLaunches: true,
            daemonListening: false,
            recoveryInFlight: false
        ))
        #expect(!ComputerUseRuntimeService.shouldScheduleHelperRecovery(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            daemonListening: true,
            recoveryInFlight: false
        ))
        #expect(!ComputerUseRuntimeService.shouldScheduleHelperRecovery(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            daemonListening: false,
            recoveryInFlight: true
        ))
    }

    @Test func untaggedRuntimeUsesBundleIdentityToIsolateAppVariants() {
        let production = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            authenticationToken: "production-token"
        )
        let staging = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.staging",
            authenticationToken: "staging-token"
        )

        #expect(production.scope == "com.cmuxterm.app")
        #expect(staging.scope == "com.cmuxterm.app.staging")
        #expect(production.daemonSocketURL != staging.daemonSocketURL)
        #expect(production.installedHelperAppURL != staging.installedHelperAppURL)
    }

    @Test func taggedRuntimeSocketFitsDarwinUnixPathLimit() {
        let longTagPrefix = String(repeating: "computer-use-long-tag-", count: 4)
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/\(String(repeating: "long-home-", count: 10))"),
            environment: ["CMUX_TAG": "\(longTagPrefix)a"]
        )
        let sibling = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            environment: ["CMUX_TAG": "\(longTagPrefix)b"]
        )

        // Darwin's `sockaddr_un.sun_path` holds at most 104 bytes including
        // the terminating NUL, so the filesystem path must stay below 104.
        #expect(paths.daemonSocketURL.path.utf8.count < 104)
        #expect(paths.codexDaemonSocketURL.path.utf8.count < 104)
        #expect(paths.scope != sibling.scope)
    }

    @Test func taggedRuntimeKeepsSanitizationCollisionsIsolated() {
        let slash = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            environment: ["CMUX_TAG": "foo/bar"]
        )
        let questionMark = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            environment: ["CMUX_TAG": "foo?bar"]
        )

        #expect(slash.scope != questionMark.scope)
        #expect(slash.daemonSocketURL != questionMark.daemonSocketURL)
        #expect(slash.installedHelperAppURL != questionMark.installedHelperAppURL)
        #expect(slash.daemonSocketURL.path.utf8.count < 104)
        #expect(slash.codexDaemonSocketURL.path.utf8.count < 104)
        #expect(questionMark.daemonSocketURL.path.utf8.count < 104)
        #expect(questionMark.codexDaemonSocketURL.path.utf8.count < 104)
    }

    @Test func defaultRuntimeUsesDarwinPerUserTemporaryDirectory() {
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            environment: ["CMUX_TAG": "secure-runtime"],
            authenticationToken: "test-token"
        )

        #expect(paths.runtimeDirectoryURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        ))
    }

    @Test func appEnvironmentDoesNotExportComputerUseBearerToken() {
        #expect(getenv(ComputerUseRuntimePaths.authenticationTokenEnvironmentKey) == nil)
    }

    @Test @MainActor func privateDaemonCredentialSurvivesHostRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sockets = root.appendingPathComponent("sockets", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)

        let credential = String(repeating: "a1", count: 32)
        let firstLaunch = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "restart-safe"],
            authenticationToken: credential
        )
        let runtime = ComputerUseRuntimeService(paths: firstLaunch)
        #expect(runtime.prepareRuntimeForLaunch())

        runtime.stopForTermination()

        #expect(
            try String(contentsOf: firstLaunch.authenticationTokenFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == credential
        )
        let relaunched = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "restart-safe"]
        )
        #expect(relaunched.authenticationToken == credential)
    }

    @Test @MainActor
    func unverifiedDaemonProbeDoesNotSendHostCapability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-unverified-peer-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-cu-peer-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "unverified-peer"],
            authenticationToken: "agent-capability",
            hostAuthenticationToken: "host-capability"
        )
        let runtime = ComputerUseRuntimeService(
            bundle: Bundle(for: NSApplication.self),
            paths: paths
        )
        #expect(runtime.prepareRuntimeForLaunch())
        let responder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"structuredContent":{"accessibility":true,"screen_recording":true}}}"#
        )

        let status = await runtime.refreshHelperStatus()
        let line = try #require(responder.receivedRequests.first)
        let envelope = try #require(
            try JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as? [String: Any]
        )

        #expect(status.accessibility)
        #expect(status.screenRecording)
        #expect(envelope["auth_token"] as? String == "agent-capability")
        #expect(envelope["host_auth_token"] == nil)
        responder.stop()
        runtime.stopForTermination()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func nativePermissionRequestUsesBothCapabilitiesAndExactHelperPeer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-host-permission-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-cu-host-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "host-permission"],
            authenticationToken: "agent-capability",
            hostAuthenticationToken: "host-capability"
        )
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        let responder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"permission":"screen_recording","requested":true}}"#
        )

        let outcome = await ComputerUseRuntimeService.requestSystemPermission(
            .screenRecording,
            paths: paths,
            expectedPeerIdentity: currentIdentity
        )
        let line = try #require(responder.receivedRequests.first)
        let envelope = try #require(
            try JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as? [String: Any]
        )
        let request = try #require(envelope["request"] as? [String: Any])

        #expect(outcome == .accepted)
        #expect(envelope["auth_token"] as? String == "agent-capability")
        #expect(envelope["host_auth_token"] as? String == "host-capability")
        #expect(request["method"] as? String == "request_system_permission")
        #expect(request["name"] as? String == "screen_recording")
        responder.stop()
    }

    @Test
    func nativePermissionRequestRequiresHelperOwnedTCCStatus() {
        let helperStatus = ComputerUsePermissionStatus(
            accessibility: false,
            screenRecording: false,
            isKnown: true,
            sourceAttribution: "helper-daemon"
        )
        let hostStatus = ComputerUsePermissionStatus(
            accessibility: false,
            screenRecording: false,
            isKnown: true,
            sourceAttribution: "caller"
        )

        #expect(ComputerUseRuntimeService.shouldRequestSystemPermission(
            status: helperStatus
        ))
        #expect(!ComputerUseRuntimeService.shouldRequestSystemPermission(
            status: hostStatus
        ))
        #expect(!ComputerUseRuntimeService.shouldRequestSystemPermission(
            status: nil
        ))
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func directCaptureVerificationUsesHostCapabilityAndExactHelperPeer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-direct-capture-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-cu-capture-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "direct-capture"],
            authenticationToken: "agent-capability",
            hostAuthenticationToken: "host-capability"
        )
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        let responder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"capturable":true}}"#
        )

        let ready = await ComputerUseRuntimeService.verifyDirectScreenCapture(
            paths: paths,
            expectedPeerIdentity: currentIdentity
        )
        let line = try #require(responder.receivedRequests.first)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let request = try #require(envelope["request"] as? [String: Any])

        #expect(ready)
        #expect(envelope["auth_token"] as? String == "agent-capability")
        #expect(envelope["host_auth_token"] as? String == "host-capability")
        #expect(request["method"] as? String == "verify_screen_capture")
        responder.stop()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func directCaptureVerificationDistinguishesDenialFromHelperUnavailability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-direct-capture-outcome-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-cu-capture-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "direct-capture-outcome"],
            authenticationToken: "agent-capability",
            hostAuthenticationToken: "host-capability"
        )
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        let deniedResponder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"capturable":false}}"#
        )
        let denied = await ComputerUseRuntimeService
            .verifyDirectScreenCaptureOutcome(
                paths: paths,
                expectedPeerIdentity: currentIdentity
            )
        deniedResponder.stop()

        let unavailableResponder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":false}"#
        )
        let unavailable = await ComputerUseRuntimeService
            .verifyDirectScreenCaptureOutcome(
                paths: paths,
                expectedPeerIdentity: currentIdentity
            )
        unavailableResponder.stop()

        let nativeReadyResponder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"capturable":true}}"#
        )
        let codexDeniedResponder = try UnixSocketResponder(
            path: paths.codexDaemonSocketURL.path,
            response: #"{"ok":true,"result":{"capturable":false}}"#
        )
        let profiles = await ComputerUseRuntimeService
            .verifyDirectScreenCaptureOutcomes(
                paths: paths,
                expectedPeerIdentities: [
                    .native: currentIdentity,
                    .codexCompatibility: currentIdentity,
                ]
            )
        nativeReadyResponder.stop()
        codexDeniedResponder.stop()

        #expect(denied == .notCapturable)
        #expect(unavailable == .unavailable)
        #expect(profiles == .notCapturable)
        #expect(nativeReadyResponder.receivedRequests.count == 1)
        #expect(codexDeniedResponder.receivedRequests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func nativePermissionRequestRejectsAReusedHelperProcessIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-stale-permission-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-cu-stale-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "stale-permission"],
            authenticationToken: "agent-capability",
            hostAuthenticationToken: "host-capability"
        )
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let staleIdentity = AgentPIDProcessIdentity(
            pid: currentIdentity.pid,
            startSeconds: currentIdentity.startSeconds + 1,
            startMicroseconds: currentIdentity.startMicroseconds
        )
        try FileManager.default.createDirectory(
            at: paths.runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
        let responder = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"permission":"accessibility","requested":true}}"#
        )

        let outcome = await ComputerUseRuntimeService.requestSystemPermission(
            .accessibility,
            paths: paths,
            expectedPeerIdentity: staleIdentity
        )

        #expect(outcome == .unknown)
        #expect(responder.receivedRequests.isEmpty)
        responder.stop()
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func permissionRefreshSurvivesHelperSocketReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-permissions-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        // Keep the fixture socket under Darwin's short, stable `/tmp` alias.
        // Remote builders can expose a user temp path long enough that even a
        // one-character runtime scope cannot fit in a UNIX-domain socket path.
        let sockets = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "cmux-cu-permissions-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sockets)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sockets,
            withIntermediateDirectories: true
        )
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: home,
            socketRootDirectoryURL: sockets,
            userIdentifier: getuid(),
            environment: ["CMUX_TAG": "permission-replacement"],
            authenticationToken: "permission-test-token"
        )
        let runtime = ComputerUseRuntimeService(
            bundle: Bundle(for: NSApplication.self),
            paths: paths
        )
        await runtime.setEnabled(true)

        let unavailable = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":false}"#
        )
        let refreshTask = Task { @MainActor in
            await runtime.refreshHelperStatus()
        }
        while unavailable.receivedRequests.isEmpty {
            await Task.yield()
        }
        unavailable.stop()

        let replacement = try UnixSocketResponder(
            path: paths.daemonSocketURL.path,
            response: #"{"ok":true,"result":{"structuredContent":{"accessibility":true,"screen_recording":true}}}"#
        )
        let status = await refreshTask.value
        replacement.stop()

        #expect(runtime.permissionStatusIsKnown)
        #expect(status.accessibility)
        #expect(status.screenRecording)

        await runtime.setEnabled(false)
    }

    @Test func helperLaunchConfigurationIsQuietAndExternallyOwned() throws {
        let paths = ComputerUseRuntimePaths(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester"),
            environment: [:],
            bundleIdentifier: nil,
            authenticationToken: "test-auth-token"
        )
        let rootIdentity = AgentPIDProcessIdentity(
            pid: 42,
            startSeconds: 1_700_000_000,
            startMicroseconds: 123_456
        )
        let configuration = try #require(ComputerUseHelperLaunchConfiguration(
            paths: paths,
            rootProcessIdentity: rootIdentity
        ))

        #expect(configuration.arguments == [
            "serve",
            "--socket",
            paths.daemonSocketURL.path,
            "--no-permissions-gate",
            "--cursor-shape",
            "cmux",
            "--idle-hide-ms",
            "0",
            "--cursor-speed",
            "1.75",
        ])
        #expect(configuration.environment["CMUX_CUA_EXTERNAL_PERMISSION_FLOW"] == "1")
        #expect(configuration.environment["CMUX_CUA_PERMISSIONS_GATE"] == "0")
        #expect(configuration.environment["CMUX_CUA_TELEMETRY_ENABLED"] == "false")
        #expect(configuration.environment["CMUX_CUA_UPDATE_CHECK"] == "false")
        #expect(configuration.environment["CMUX_CUA_RESPONSIBILITY_DISCLAIMED"] == "1")
        #expect(configuration.environment["CMUX_CUA_SOCKET_AUTH_TOKEN"] == "test-auth-token")
        let hostAuthority = try #require(
            configuration.environment["CMUX_CUA_SOCKET_HOST_AUTH_TOKEN"]
        )
        #expect(hostAuthority.count == 64)
        #expect(hostAuthority != "test-auth-token")
        #expect(configuration.environment["CMUX_CUA_SOCKET_AUTHORIZED_ROOT_PID"]
            == "42")
        #expect(configuration.environment["CMUX_CUA_SOCKET_AUTHORIZED_ROOT_START_SECONDS"]
            == "1700000000")
        #expect(configuration.environment["CMUX_CUA_SOCKET_AUTHORIZED_ROOT_START_MICROSECONDS"]
            == "123456")

        let codexConfiguration = try #require(
            ComputerUseHelperLaunchConfiguration(
                paths: paths,
                profile: .codexCompatibility,
                rootProcessIdentity: rootIdentity
            )
        )
        #expect(codexConfiguration.arguments == [
            "serve",
            "--socket",
            paths.codexDaemonSocketURL.path,
            "--codex-computer-use-compat",
            "--no-permissions-gate",
            "--cursor-shape",
            "cmux",
            "--idle-hide-ms",
            "0",
            "--cursor-speed",
            "1.75",
        ])
        #expect(codexConfiguration.environment == configuration.environment)
    }

    @Test func agentWrappersDeclareHostOwnedComputerUseOnboarding() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for wrapperName in [
            "cmux-codex-wrapper",
            "cmux-claude-wrapper",
        ] {
            let wrapperURL = repositoryRoot
                .appendingPathComponent("Resources/bin", isDirectory: true)
                .appendingPathComponent(wrapperName, isDirectory: false)
            let source = try String(contentsOf: wrapperURL, encoding: .utf8)
            let declaresExternalFlow = source.contains(
                #"CMUX_CUA_EXTERNAL_PERMISSION_FLOW="1""#
            ) || source.contains(
                #""CMUX_CUA_EXTERNAL_PERMISSION_FLOW":"1""#
            )
            #expect(declaresExternalFlow)
            #expect(!source.contains(
                #"CMUX_CUA_EXTERNAL_PERMISSION_FLOW="0""#
            ))
        }
    }

    /// Codex actions acknowledge dispatch and use an explicit state refresh.
    @Test func bundledCodexInstructionsUseVisiblePointerClicksAndExplicitState() throws {
        let skillURL = try #require(Bundle.main.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "cmux-cua"
        ))
        let skill = try String(contentsOf: skillURL, encoding: .utf8)

        // Visible pointer interaction is the product default; keystrokes are
        // for text fields, not a shortcut around clicking controls.
        #expect(skill.contains(
            "Operate controls with visible pointer clicks by default"
        ))
        #expect(skill.contains(
            "mean literal button-by-button pointer"
        ))
        #expect(skill.contains(
            "Reserve `type_text` for entering text"
        ))
        #expect(skill.contains(
            "Actions return a compact dispatch acknowledgement"
        ))
        #expect(skill.contains(
            "call `get_app_state` before deciding what to do next"
        ))
        #expect(skill.contains(
            "Calculator's **All Clear** removes display nodes"
        ))
        #expect(!skill.contains("Every successful action already returns a fresh app state"))
    }

    @Test(.timeLimit(.minutes(1)))
    func daemonReadinessUsesTheExactPIDFileSignal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-readiness-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let pidFileURL = root.appendingPathComponent("cua.pid")
        let readiness = ComputerUseDaemonReadiness(
            pidFileURL: pidFileURL,
            timeout: .seconds(2)
        )
        #expect(readiness.prepare())

        let readyTask = Task {
            await readiness.waitUntilReady {
                (try? Data(contentsOf: pidFileURL)) == Data("42".utf8)
            }
        }
        try Data("42".utf8).write(to: pidFileURL)

        #expect(await readyTask.value)
    }

    @Test func menuBarRequiresAComputerUsePairedSession() {
        let unmatchedRecentState = ComputerUseMenuBarSnapshot(
            rows: [],
            hasRecentStateFiles: true,
            showInMenuBar: true,
            featureEnabled: true
        )

        #expect(!unmatchedRecentState.shouldShowStatusItem)
    }

    @MainActor
    @Test func menuStartPrimesAgentIndexWithoutPerStateReloads() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cua-menu-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                Issue.record("Computer-use menu refresh scheduled an agent-index reload")
                return (
                    index: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: {
                root.appendingPathComponent("hooks", isDirectory: true).path
            }
        )
        let catalog = SettingCatalog()
        let store = ComputerUseMenuBarSnapshotStore(
            liveSessionProjection: ComputerUseLiveSessionProjection(
                liveAgentIndex: sharedIndex
            ),
            activityLifecycle: ComputerUseActivityLifecycle(),
            stateRepository: ComputerUseStateRepository(
                authenticationKey: Self.stateAuthenticationKey
            ),
            stateDirectoryURL: root.appendingPathComponent("state", isDirectory: true),
            configStore: JSONConfigStore(fileURL: root.appendingPathComponent("cmux.json")),
            showInMenuBarKey: catalog.computerUse.showInMenuBar,
            workspaceTitle: { _ in nil },
            featureEnabled: { true },
            refreshPolicy: ComputerUseMenuBarRefreshPolicy(minimumEventReloadInterval: 60)
        )

        store.refresh()
        #expect(!sharedIndex.hasScheduledRefresh)

        store.start()
        #expect(sharedIndex.hasScheduledRefresh)

        store.refresh()
        #expect(sharedIndex.hasScheduledRefresh)
        store.stop()
    }

    @Test func menuRefreshPolicyDebouncesOnlyWhenFeatureAndMenuAreVisible() throws {
        let policy = ComputerUseMenuBarRefreshPolicy(minimumEventReloadInterval: 0.2)
        let firstEvent = Date(timeIntervalSince1970: 1_900_000_000)
        let secondEvent = firstEvent.addingTimeInterval(0.05)
        let lastAction = firstEvent.addingTimeInterval(-30)

        #expect(policy.reloadDeadline(
            forEventAt: firstEvent,
            featureEnabled: false,
            showInMenuBar: false
        ) == nil)
        #expect(policy.reloadDeadline(
            forEventAt: firstEvent,
            featureEnabled: true,
            showInMenuBar: false
        ) == nil)
        #expect(policy.reloadDeadline(
            forEventAt: firstEvent,
            featureEnabled: false,
            showInMenuBar: true
        ) == nil)
        let firstDeadline = try #require(policy.reloadDeadline(
            forEventAt: firstEvent,
            featureEnabled: true,
            showInMenuBar: true
        ))
        let secondDeadline = try #require(policy.reloadDeadline(
            forEventAt: secondEvent,
            featureEnabled: true,
            showInMenuBar: true
        ))
        #expect(firstDeadline == firstEvent.addingTimeInterval(0.2))
        #expect(secondDeadline > firstDeadline)
        #expect(policy.stateExpirationDeadline(
            lastActionAt: lastAction,
            recentActivityInterval: 3_600
        ) == lastAction.addingTimeInterval(3_600.2))
    }

    @Test func computerUseSchemaDeclaresPersistedKeys() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repositoryRoot.appendingPathComponent("web/data/cmux.schema.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        )
        let properties = try #require(object["properties"] as? [String: Any])
        let computerUse = try #require(properties["computerUse"] as? [String: Any])
        #expect(computerUse["additionalProperties"] as? Bool == false)
        let computerUseProperties = try #require(computerUse["properties"] as? [String: Any])
        #expect((computerUseProperties["enabled"] as? [String: Any])?["type"] as? String == "boolean")
        #expect((computerUseProperties["showInMenuBar"] as? [String: Any])?["type"] as? String == "boolean")
    }

    @Test func generatedAgentShimReadsComputerUseAuthorityOnEveryLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cua-live-setting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let settingURL = root.appendingPathComponent("enabled")
        let logURL = root.appendingPathComponent("disabled-value")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let wrapperURL = binDirectory.appendingPathComponent("cmux-claude-wrapper")
        try """
        #!/usr/bin/env bash
        printf '%s' "${CMUX_COMPUTER_USE_MCP_DISABLED:-missing}" > "$CMUX_TEST_LOG"
        """.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperURL.path)
        let shimSet = try #require(TerminalSurface.installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: binDirectory,
            surfaceId: UUID(),
            temporaryDirectory: shimRoot,
            computerUseSettingFileURL: settingURL
        ))
        let shim = try #require(shimSet.shims.first { $0.commandName == "claude" })

        // Setting disabled -> shim forces the disable regardless of inherited env.
        try "0\n".write(to: settingURL, atomically: true, encoding: .utf8)
        try runShim(at: shim.executablePath, logURL: logURL, inheritedDisabled: "0")
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "1")

        // A terminal spawned while the app setting was disabled must observe a
        // later live enable without confusing app state with the user kill switch.
        try "1\n".write(to: settingURL, atomically: true, encoding: .utf8)
        try runShim(
            at: shim.executablePath,
            logURL: logURL,
            inheritedDisabled: "0",
            appEnabledAtSpawn: "0"
        )
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "0")

        // Setting enabled but the user exported the documented kill switch
        // (CMUX_COMPUTER_USE_MCP_DISABLED=1): the shim must NOT clobber it.
        try "1\n".write(to: settingURL, atomically: true, encoding: .utf8)
        try runShim(at: shim.executablePath, logURL: logURL, inheritedDisabled: "1")
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "1")
    }

    // MARK: - Watch-the-target activation

    @Test func watchTargetActivatesEachNewTargetExactlyOnce() {
        // A brand-new target (nothing activated yet) is fronted.
        #expect(ComputerUseWatchTargetDecision.activation(current: 100, lastActivated: nil) == 100)
        // The same target driving again (every action rewrites the state file) is
        // NOT re-fronted — this is what keeps cmux from stealing focus repeatedly.
        #expect(ComputerUseWatchTargetDecision.activation(current: 100, lastActivated: 100) == nil)
        // A different app starts being driven -> front it once.
        #expect(ComputerUseWatchTargetDecision.activation(current: 200, lastActivated: 100) == 200)
    }

    @Test func explicitFocusModesRemainAuthoritativeAcrossLaterActions() {
        #expect(ComputerUseWatchTargetDecision.activation(
            current: 200,
            lastActivated: 100,
            focusMode: .callingTerminal
        ) == nil)
        #expect(ComputerUseWatchTargetDecision.activation(
            current: 200,
            lastActivated: 200,
            focusMode: .computerUse,
            targetIsFrontmost: false
        ) == 200)
        #expect(ComputerUseWatchTargetDecision.activation(
            current: 200,
            lastActivated: 200,
            focusMode: .computerUse,
            targetIsFrontmost: true
        ) == nil)
    }

    @Test func transientTargetValidationDoesNotConsumeFreshActivity() {
        let unauthorized = ComputerUseWatchTargetDecision.activityDisposition(
            isAuthorized: false,
            validatedTargetPID: 200,
            lastActivatedTargetPID: nil
        )
        #expect(unauthorized.shouldRetry)
        #expect(unauthorized.targetPIDToActivate == nil)

        let targetUnavailable = ComputerUseWatchTargetDecision.activityDisposition(
            isAuthorized: true,
            validatedTargetPID: nil,
            lastActivatedTargetPID: nil
        )
        #expect(targetUnavailable.shouldRetry)
        #expect(targetUnavailable.targetPIDToActivate == nil)

        let deduplicated = ComputerUseWatchTargetDecision.activityDisposition(
            isAuthorized: true,
            validatedTargetPID: 200,
            lastActivatedTargetPID: 200
        )
        #expect(!deduplicated.shouldRetry)
        #expect(deduplicated.targetPIDToActivate == nil)

        let newTarget = ComputerUseWatchTargetDecision.activityDisposition(
            isAuthorized: true,
            validatedTargetPID: 200,
            lastActivatedTargetPID: nil
        )
        #expect(!newTarget.shouldRetry)
        #expect(newTarget.targetPIDToActivate == 200)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func computerUseFilesystemCallbacksHopSafelyToMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-watcher-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = try #require(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated
                && $0.bundleIdentifier?.isEmpty == false
                && $0.localizedName?.isEmpty == false
                && $0.launchDate != nil
        })
        let targetName = try #require(target.localizedName)
        let targetLaunchDate = try #require(target.launchDate)
        let writerIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let workspaceID = UUID()
        let surfaceID = UUID()
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )
        let liveSession = ComputerUseLiveDriverSession(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            logicalSessionID: "watcher-main-actor-session",
            rootProcessIdentities: [writerIdentity]
        )
        let actionDate = max(Date(), targetLaunchDate)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let state = try Self.authenticatedStateData(
            driverPID: 70_001,
            writerPID: Int(writerIdentity.pid),
            writerStartSeconds: writerIdentity.startSeconds,
            writerStartMicroseconds: writerIdentity.startMicroseconds,
            session: driverSessionID,
            targetApp: targetName,
            targetPID: Int(target.processIdentifier),
            targetWindowID: 7,
            lastActionAt: formatter.string(from: actionDate)
        )

        let activationEvents = AsyncStream.makeStream(
            of: pid_t.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        defer { activationEvents.continuation.finish() }

        try await confirmation(
            "background directory callback activated the target once"
        ) { activated in
            let controller = ComputerUseWatchTargetController(
                stateDirectoryURL: directory,
                featureEnabled: { true },
                liveDriverSessions: { [driverSessionID: liveSession] },
                currentLiveDriverSession: { _ in liveSession },
                feed: ComputerUseWatchTargetFeed(
                    authenticationKey: Self.stateAuthenticationKey
                ),
                activate: { application in
                    activationEvents.continuation.yield(
                        application.processIdentifier
                    )
                }
            )
            controller.start()
            defer { controller.stop() }

            try state.write(
                to: directory.appendingPathComponent("watcher.json"),
                options: .atomic
            )
            for await processIdentifier in activationEvents.stream {
                guard processIdentifier == target.processIdentifier else {
                    continue
                }
                activated()
                activationEvents.continuation.finish()
                break
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func backgroundActivityCannotFrontItsTargetAndViewResumesIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-background-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && !$0.isTerminated
                && $0.bundleIdentifier?.isEmpty == false
                && $0.localizedName?.isEmpty == false
                && $0.launchDate != nil
        })
        let targetName = try #require(target.localizedName)
        let targetBundleIdentifier = try #require(target.bundleIdentifier)
        let targetLaunchDate = try #require(target.launchDate)
        let writerIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let backgroundSurfaceID = UUID()
        let foregroundSurfaceID = UUID()
        let backgroundDriverSessionID =
            ComputerUseSessionScope.driverSessionID(
                surfaceID: backgroundSurfaceID
            )
        let backgroundProxySessionID =
            "\(backgroundDriverSessionID)-mcp-73-2000"
        let foregroundDriverSessionID =
            ComputerUseSessionScope.driverSessionID(
                surfaceID: foregroundSurfaceID
            )
        let backgroundLogicalSessionID = "background-logical-session"
        let foregroundLogicalSessionID = "foreground-logical-session"
        let backgroundSession = ComputerUseLiveDriverSession(
            workspaceID: UUID(),
            surfaceID: backgroundSurfaceID,
            logicalSessionID: backgroundLogicalSessionID,
            rootProcessIdentities: [writerIdentity]
        )
        let foregroundSession = ComputerUseLiveDriverSession(
            workspaceID: UUID(),
            surfaceID: foregroundSurfaceID,
            logicalSessionID: foregroundLogicalSessionID,
            rootProcessIdentities: [writerIdentity]
        )
        let sessions = [
            backgroundDriverSessionID: backgroundSession,
            foregroundDriverSessionID: foregroundSession,
        ]
        let sessionsBySurfaceID = Dictionary(
            uniqueKeysWithValues: sessions.values.map {
                ($0.surfaceID, $0)
            }
        )
        var featureEnabled = false
        var reportScannedSession = false
        let scannedSessions = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        defer { scannedSessions.continuation.finish() }
        var activatedProcessIdentifiers: [pid_t] = []
        var focusedTerminalSessions: [(workspaceID: UUID, surfaceID: UUID)] = []
        var cursorVisibilityChanges: [
            (
                driverSessionID: String,
                proxySessionID: String?,
                visible: Bool
            )
        ] = []
        let controller = ComputerUseWatchTargetController(
            stateDirectoryURL: directory,
            featureEnabled: { featureEnabled },
            liveDriverSessions: { sessions },
            currentLiveDriverSession: { scannedSession in
                if reportScannedSession {
                    scannedSessions.continuation.yield(
                        scannedSession.logicalSessionID
                    )
                }
                return sessionsBySurfaceID[scannedSession.surfaceID]
            },
            feed: ComputerUseWatchTargetFeed(
                authenticationKey: Self.stateAuthenticationKey
            ),
            onFocusTerminal: { workspaceID, surfaceID, _ in
                focusedTerminalSessions.append((workspaceID, surfaceID))
            },
            onCursorVisibilityChange: {
                driverSessionID,
                proxySessionID,
                visible,
                _ in
                cursorVisibilityChanges.append((
                    driverSessionID,
                    proxySessionID,
                    visible
                ))
            },
            frontmostApplicationProcessIdentifier: { nil },
            activate: { application in
                activatedProcessIdentifiers.append(
                    application.processIdentifier
                )
            }
        )
        controller.start()
        defer { controller.stop() }

        #expect(controller.continueInBackground(
            driverSessionID: backgroundDriverSessionID,
            logicalSessionID: backgroundLogicalSessionID,
            stateWriterIdentity: writerIdentity,
            proxySessionID: backgroundProxySessionID
        ))
        await Task.yield()
        #expect(cursorVisibilityChanges.isEmpty)
        #expect(focusedTerminalSessions.count == 1)
        #expect(
            focusedTerminalSessions.first?.workspaceID
                == backgroundSession.workspaceID
        )
        #expect(
            focusedTerminalSessions.first?.surfaceID
                == backgroundSession.surfaceID
        )

        let actionDate = max(Date(), targetLaunchDate)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let foregroundState = try Self.authenticatedStateData(
            driverPID: 71_001,
            writerPID: Int(writerIdentity.pid),
            writerStartSeconds: writerIdentity.startSeconds,
            writerStartMicroseconds: writerIdentity.startMicroseconds,
            session: foregroundDriverSessionID,
            targetApp: "cmux test host",
            targetPID: Int(ProcessInfo.processInfo.processIdentifier),
            targetWindowID: 7,
            lastActionAt: formatter.string(from: actionDate)
        )
        let backgroundState = try Self.authenticatedStateData(
            driverPID: 71_002,
            writerPID: Int(writerIdentity.pid),
            writerStartSeconds: writerIdentity.startSeconds,
            writerStartMicroseconds: writerIdentity.startMicroseconds,
            session: backgroundDriverSessionID,
            targetApp: targetName,
            targetPID: Int(target.processIdentifier),
            targetWindowID: 8,
            lastActionAt: formatter.string(
                from: actionDate.addingTimeInterval(0.1)
            )
        )
        try foregroundState.write(
            to: directory.appendingPathComponent("foreground.json"),
            options: .atomic
        )
        try backgroundState.write(
            to: directory.appendingPathComponent("background.json"),
            options: .atomic
        )

        reportScannedSession = true
        featureEnabled = true
        NotificationCenter.default.post(
            name: .cmuxFeatureFlagsDidChange,
            object: nil
        )
        var scannedIterator = scannedSessions.stream.makeAsyncIterator()
        let scannedLogicalSessionID = await scannedIterator.next()

        #expect(scannedLogicalSessionID == backgroundLogicalSessionID)
        #expect(activatedProcessIdentifiers.isEmpty)
        #expect(focusedTerminalSessions.count == 2)

        let identity = ComputerUseTargetIdentity(
            processIdentifier: Int(target.processIdentifier),
            bundleIdentifier: targetBundleIdentifier,
            launchDate: targetLaunchDate
        )
        #expect(controller.viewTarget(
            identity,
            driverSessionID: backgroundDriverSessionID,
            logicalSessionID: backgroundLogicalSessionID,
            stateWriterIdentity: writerIdentity,
            proxySessionID: backgroundProxySessionID
        ))
        await Task.yield()
        #expect(activatedProcessIdentifiers == [target.processIdentifier])
        #expect(cursorVisibilityChanges.isEmpty)
        #expect(!controller.isRunningInBackground(
            driverSessionID: backgroundDriverSessionID,
            logicalSessionID: backgroundLogicalSessionID
        ))
    }

    @Test @MainActor
    func computerUseSessionsDefaultToCallingTerminalFocus() async {
        let controller = ComputerUseSessionPresentationController(
            setCursorVisibility: { _, _, _, _ in },
            focusTerminal: { _, _, _ in }
        )
        let driverSessionID = "terminal-default-session"

        controller.driverSessionDidStart(driverSessionID)
        #expect(controller.isRunningInBackground(driverSessionID))

        var targetWasActivated = false
        controller.activateTarget(driverSessionID: driverSessionID) {
            targetWasActivated = true
        }
        #expect(!targetWasActivated)

        controller.focusComputerUse(driverSessionID: driverSessionID) {
            targetWasActivated = true
        }
        #expect(!targetWasActivated)
        await Task.yield()
        #expect(targetWasActivated)
        #expect(controller.focusMode(for: driverSessionID) == .computerUse)

        controller.driverSessionDidComplete(driverSessionID)
        controller.driverSessionDidStart(driverSessionID)
        #expect(controller.isRunningInBackground(driverSessionID))
    }

    @Test @MainActor
    func focusTransitionsReassertTheExistingCursorTargetWithoutSnapshotFetch() async throws {
        let driverSessionID = "focus-reassert-session"
        let targetWindowID: UInt32 = 42
        let reassertions = AsyncStream.makeStream(
            of: (targetWindowID: UInt32?, visible: Bool).self,
            bufferingPolicy: .unbounded
        )
        defer { reassertions.continuation.finish() }
        var activations = 0
        var terminalFocuses = 0
        let controller = ComputerUseSessionPresentationController(
            setCursorVisibility: { _, _, _, _ in },
            focusTerminal: { _, _, _ in terminalFocuses += 1 },
            reassertCursor: { _, _, targetWindowID, _ in
                reassertions.continuation.yield((targetWindowID, true))
            }
        )
        controller.driverSessionDidStart(driverSessionID)
        controller.focusCallingTerminal(
            driverSessionID: driverSessionID,
            workspaceID: UUID(),
            surfaceID: UUID(),
            targetWindowID: targetWindowID
        )
        var iterator = reassertions.stream.makeAsyncIterator()
        let terminalReassertion = try #require(await iterator.next())
        #expect(terminalReassertion.targetWindowID == targetWindowID)
        #expect(terminalReassertion.visible)
        #expect(terminalFocuses == 1)

        controller.focusComputerUse(
            driverSessionID: driverSessionID,
            targetWindowID: targetWindowID
        ) {
            activations += 1
        }
        let computerUseReassertion = try #require(await iterator.next())
        #expect(computerUseReassertion.targetWindowID == targetWindowID)
        #expect(computerUseReassertion.visible)
        #expect(activations == 1)
        #expect(controller.focusMode(for: driverSessionID) == .computerUse)
    }

    /// Status-item actions run while AppKit is still tracking the menu. The
    /// selected mode must become authoritative immediately, but the activation
    /// effect must wait until menu tracking unwinds. If the user switches modes
    /// before that happens, only the newest choice may take focus.
    @Test(.timeLimit(.minutes(1))) @MainActor
    func newestMenuFocusChoiceWinsAfterMenuTrackingCloses() async throws {
        let application = NSRunningApplication.current
        let bundleIdentifier = try #require(application.bundleIdentifier)
        let launchDate = try #require(application.launchDate)
        let writerIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let workspaceID = UUID()
        let surfaceID = UUID()
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )
        let logicalSessionID = "menu-focus-session"
        let liveSession = ComputerUseLiveDriverSession(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            logicalSessionID: logicalSessionID,
            rootProcessIdentities: [writerIdentity]
        )
        let focusEffectStream = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .unbounded
        )
        defer { focusEffectStream.continuation.finish() }
        var focusEffects: [String] = []
        let controller = ComputerUseWatchTargetController(
            stateDirectoryURL: FileManager.default.temporaryDirectory,
            featureEnabled: { false },
            liveDriverSessions: { [driverSessionID: liveSession] },
            currentLiveDriverSession: { _ in liveSession },
            feed: ComputerUseWatchTargetFeed(
                authenticationKey: Self.stateAuthenticationKey
            ),
            onFocusTerminal: { _, _, _ in
                focusEffects.append("terminal")
                focusEffectStream.continuation.yield("terminal")
            },
            activate: { _ in
                focusEffects.append("computerUse")
                focusEffectStream.continuation.yield("computerUse")
            }
        )
        controller.start()
        defer { controller.stop() }
        controller.driverSessionDidStart(driverSessionID)

        #expect(controller.continueInBackground(
            driverSessionID: driverSessionID,
            logicalSessionID: logicalSessionID,
            stateWriterIdentity: writerIdentity
        ))
        let target = ComputerUseTargetIdentity(
            processIdentifier: Int(application.processIdentifier),
            bundleIdentifier: bundleIdentifier,
            launchDate: launchDate
        )
        #expect(controller.viewTarget(
            target,
            driverSessionID: driverSessionID,
            logicalSessionID: logicalSessionID,
            stateWriterIdentity: writerIdentity
        ))

        #expect(focusEffects.isEmpty)
        #expect(!controller.isRunningInBackground(
            driverSessionID: driverSessionID,
            logicalSessionID: logicalSessionID
        ))

        var focusEffectIterator =
            focusEffectStream.stream.makeAsyncIterator()
        let committedFocusEffect =
            try #require(await focusEffectIterator.next())

        #expect(committedFocusEffect == "computerUse")
        #expect(focusEffects == ["computerUse"])
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func newerComputerUseFocusInvalidatesDelayedTerminalAndCursorEffects() async throws {
        let currentApplication = NSRunningApplication.current
        let bundleIdentifier = try #require(currentApplication.bundleIdentifier)
        let launchDate = try #require(currentApplication.launchDate)
        let writerIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let workspaceID = UUID()
        let surfaceID = UUID()
        let driverSessionID = ComputerUseSessionScope.driverSessionID(
            surfaceID: surfaceID
        )
        let proxySessionID = "\(driverSessionID)-mcp-81-3000"
        let logicalSessionID = "presentation-generation-session"
        let liveSession = ComputerUseLiveDriverSession(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            logicalSessionID: logicalSessionID,
            rootProcessIdentities: [writerIdentity]
        )
        let cursorEffects = AsyncStream.makeStream(
            of: (
                proxySessionID: String?,
                visible: Bool,
                isCurrent: @MainActor @Sendable () -> Bool
            ).self,
            bufferingPolicy: .unbounded
        )
        defer { cursorEffects.continuation.finish() }
        var observedCursorEffects: [(proxySessionID: String?, visible: Bool)] = []
        var delayedTerminalFocusIsCurrent:
            (@MainActor @Sendable () -> Bool)?
        let controller = ComputerUseWatchTargetController(
            stateDirectoryURL: FileManager.default.temporaryDirectory,
            featureEnabled: { false },
            liveDriverSessions: { [driverSessionID: liveSession] },
            currentLiveDriverSession: { _ in liveSession },
            feed: ComputerUseWatchTargetFeed(
                authenticationKey: Self.stateAuthenticationKey
            ),
            onFocusTerminal: { _, _, isCurrent in
                delayedTerminalFocusIsCurrent = isCurrent
            },
            onCursorVisibilityChange: {
                _,
                proxySessionID,
                visible,
                isCurrent in
                observedCursorEffects.append((proxySessionID, visible))
                cursorEffects.continuation.yield((
                    proxySessionID,
                    visible,
                    isCurrent
                ))
            },
            activate: { _ in }
        )
        controller.start()
        defer { controller.stop() }

        controller.driverSessionDidStart(driverSessionID)
        var cursorIterator = cursorEffects.stream.makeAsyncIterator()
        let initialShow = try #require(await cursorIterator.next())
        #expect(initialShow.visible)
        #expect(initialShow.proxySessionID == nil)
        #expect(initialShow.isCurrent())

        #expect(controller.continueInBackground(
            driverSessionID: driverSessionID,
            logicalSessionID: logicalSessionID,
            stateWriterIdentity: writerIdentity,
            proxySessionID: proxySessionID
        ))
        await Task.yield()
        #expect(observedCursorEffects.count == 1)
        #expect(initialShow.isCurrent())
        #expect(delayedTerminalFocusIsCurrent?() == true)

        let target = ComputerUseTargetIdentity(
            processIdentifier: Int(currentApplication.processIdentifier),
            bundleIdentifier: bundleIdentifier,
            launchDate: launchDate
        )
        #expect(controller.viewTarget(
            target,
            driverSessionID: driverSessionID,
            logicalSessionID: logicalSessionID,
            stateWriterIdentity: writerIdentity,
            proxySessionID: proxySessionID
        ))
        await Task.yield()
        #expect(observedCursorEffects.count == 1)
        #expect(initialShow.isCurrent())
        #expect(delayedTerminalFocusIsCurrent?() == false)

        controller.driverSessionDidComplete(driverSessionID)
        let completionHide = try #require(await cursorIterator.next())
        #expect(!completionHide.visible)
        #expect(completionHide.proxySessionID == proxySessionID)
        #expect(completionHide.isCurrent())
        #expect(!initialShow.isCurrent())

        controller.driverSessionDidStart(driverSessionID)
        let nextTurnShow = try #require(await cursorIterator.next())
        #expect(nextTurnShow.visible)
        #expect(nextTurnShow.proxySessionID == proxySessionID)
        #expect(nextTurnShow.isCurrent())
        #expect(!completionHide.isCurrent())
    }

    @Test @MainActor func computerUsePresentationModeResetsAfterLiveSessionsEnd() throws {
        let logicalSessionA = "logical-session-a"
        let logicalSessionB = "logical-session-b"
        let workspaceIDA = UUID()
        let workspaceIDB = UUID()
        let surfaceIDA = UUID()
        let surfaceIDB = UUID()
        let currentIdentity = try #require(AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        ))
        let liveDriverSessions = [
            "session-a": ComputerUseLiveDriverSession(
                workspaceID: workspaceIDA,
                surfaceID: surfaceIDA,
                logicalSessionID: logicalSessionA,
                rootProcessIdentities: [currentIdentity]
            ),
            "session-b": ComputerUseLiveDriverSession(
                workspaceID: workspaceIDB,
                surfaceID: surfaceIDB,
                logicalSessionID: logicalSessionB,
                rootProcessIdentities: [currentIdentity]
            ),
        ]
        let currentSessionsBySurfaceID = Dictionary(
            uniqueKeysWithValues: liveDriverSessions.values.map {
                ($0.surfaceID, $0)
            }
        )
        var fullLookupCount = 0
        var keyedLookupCount = 0
        let controller = ComputerUseWatchTargetController(
            stateDirectoryURL: FileManager.default.temporaryDirectory,
            featureEnabled: { false },
            liveDriverSessions: {
                fullLookupCount += 1
                return liveDriverSessions
            },
            currentLiveDriverSession: { scannedSession in
                keyedLookupCount += 1
                return currentSessionsBySurfaceID[scannedSession.surfaceID]
            },
            feed: ComputerUseWatchTargetFeed(
                authenticationKey: Self.stateAuthenticationKey
            )
        )
        controller.start()
        defer { controller.stop() }
        #expect(fullLookupCount == 1)

        #expect(!controller.isRunningInBackground(
            driverSessionID: "session-a",
            logicalSessionID: logicalSessionA
        ))
        #expect(controller.continueInBackground(
            driverSessionID: "session-a",
            logicalSessionID: logicalSessionA,
            stateWriterIdentity: currentIdentity
        ))
        #expect(controller.isRunningInBackground(
            driverSessionID: "session-a",
            logicalSessionID: logicalSessionA
        ))
        #expect(!controller.isRunningInBackground(
            driverSessionID: "session-b",
            logicalSessionID: logicalSessionB
        ))
        #expect(controller.continueInBackground(
            driverSessionID: "session-b",
            logicalSessionID: logicalSessionB,
            stateWriterIdentity: currentIdentity
        ))
        #expect(controller.isRunningInBackground(
            driverSessionID: "session-a",
            logicalSessionID: logicalSessionA
        ))
        #expect(controller.isRunningInBackground(
            driverSessionID: "session-b",
            logicalSessionID: logicalSessionB
        ))
        controller.driverSessionDidComplete("session-a")
        #expect(!controller.isRunningInBackground(
            driverSessionID: "session-a",
            logicalSessionID: logicalSessionA
        ))
        #expect(controller.isRunningInBackground(
            driverSessionID: "session-b",
            logicalSessionID: logicalSessionB
        ))
        #expect(fullLookupCount == 1)
        #expect(keyedLookupCount > 0)

        let staleController = ComputerUseWatchTargetController(
            stateDirectoryURL: FileManager.default.temporaryDirectory,
            featureEnabled: { false },
            liveDriverSessions: { liveDriverSessions },
            currentLiveDriverSession: { scannedSession in
                ComputerUseLiveDriverSession(
                    workspaceID: scannedSession.workspaceID,
                    surfaceID: scannedSession.surfaceID,
                    logicalSessionID: "replacement-session",
                    rootProcessIdentities: [currentIdentity]
                )
            },
            feed: ComputerUseWatchTargetFeed(
                authenticationKey: Self.stateAuthenticationKey
            )
        )
        staleController.start()
        defer { staleController.stop() }
        #expect(!staleController.continueInBackground(
            driverSessionID: "session-a",
            logicalSessionID: logicalSessionA,
            stateWriterIdentity: currentIdentity
        ))
    }

    @Test func watchTargetDoesNotReFrontAfterUserFocusAwayOrIdleGap() {
        // The user manually clicks into cmux mid-session. The driver keeps driving
        // the same target pid, so `current` stays equal to `lastActivated` and we
        // return nil: cmux does not yank focus back to the target.
        #expect(ComputerUseWatchTargetDecision.activation(current: 100, lastActivated: 100) == nil)
        // A brief idle gap between actions makes the state file momentarily stale
        // (current == nil). We must keep the last target and do nothing, so that
        // when the same target resumes it is still deduped rather than re-fronted.
        #expect(ComputerUseWatchTargetDecision.activation(current: nil, lastActivated: 100) == nil)
    }

    @Test func watchTargetActivatesNewTargetAfterPreviousOneCleared() {
        // Target A was fronted; its session ended (state went stale -> nil). When a
        // genuinely different target B begins being driven, front B once. `lastActivated`
        // remains A across the idle gap, so B (!= A) is correctly detected as new.
        #expect(ComputerUseWatchTargetDecision.activation(current: nil, lastActivated: 100) == nil)
        #expect(ComputerUseWatchTargetDecision.activation(current: 300, lastActivated: 100) == 300)
    }

    @Test func watchTargetFeedSelectsNewestFreshCuaState() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeState(
                to: directory.appendingPathComponent("older.json"),
                pid: 10, session: "session-a", targetPID: 500, lastActionAt: now.addingTimeInterval(-3)
            )
            try writeState(
                to: directory.appendingPathComponent("newer.json"),
                pid: 11, session: "session-a-mcp-11", targetPID: 600, lastActionAt: now.addingTimeInterval(-1)
            )
            try writeState(
                to: directory.appendingPathComponent("foreign.json"),
                pid: 12, session: "session-b", targetPID: 700, lastActionAt: now
            )
            // A cursor feed file in the same directory must never be mistaken for a
            // driver state.
            try writeCursorState(
                to: directory.appendingPathComponent("11.cursor.json"),
                driverPID: 11, visible: true, x: 1, y: 1, updatedAt: now
            )
            let selected = ComputerUseWatchTargetFeed(
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                driverSessionIDs: ["session-a", "session-b"],
                now: now
            )
            #expect(selected.map(\.driverSessionID) == ["session-a", "session-b"])
            #expect(selected.map(\.targetPID) == [600, 700])
        }
    }

    @Test func watchTargetFeedRejectsStaleCuaState() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            // Older than the freshness window -> the session is no longer driving.
            try writeState(
                to: directory.appendingPathComponent("stale.json"),
                pid: 10, session: "session-a", targetPID: 500, lastActionAt: now.addingTimeInterval(-30)
            )
            let feed = ComputerUseWatchTargetFeed(
                freshnessInterval: 5,
                authenticationKey: Self.stateAuthenticationKey
            )
            #expect(feed.scan(
                directoryURL: directory,
                driverSessionIDs: ["session-a"],
                now: now,
                isStateEligible: { _, _ in
                    Issue.record(
                        "Stale states must be rejected before process ancestry validation"
                    )
                    return true
                }
            ).isEmpty)
        }
    }

    @Test func watchTargetFeedRejectsPathologicallyLargeStateDirectory() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeState(
                to: directory.appendingPathComponent("valid.json"),
                pid: 10,
                session: "session-a",
                targetPID: 500,
                lastActionAt: now
            )
            for index in 0 ..< 4_096 {
                try Data("{}".utf8).write(
                    to: directory.appendingPathComponent("junk-\(index).json")
                )
            }

            #expect(ComputerUseWatchTargetFeed(
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                driverSessionIDs: ["session-a"],
                now: now
            ).isEmpty)
        }
    }

    @Test func menuRepositoryRejectsPathologicallyLargeStateDirectory() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeState(
                to: directory.appendingPathComponent("valid.json"),
                pid: 10,
                session: "session-a",
                targetPID: 500,
                lastActionAt: now
            )
            for index in 0 ..< 512 {
                try Data("{}".utf8).write(
                    to: directory.appendingPathComponent("junk-\(index).json")
                )
            }

            let scan = ComputerUseStateRepository(
                authenticationKey: Self.stateAuthenticationKey
            ).scan(
                directoryURL: directory,
                sessions: [
                    ComputerUseSessionScope(
                        id: "row-a",
                        driverSessionID: "session-a"
                    ),
                ],
                now: now
            )
            #expect(scan.newestStateByScopeID.isEmpty)
            #expect(!scan.hasRecentStateFiles)
        }
    }

    @Test func unavailablePermissionStatusIsNotReportedAsDenied() {
        #expect(!ComputerUsePermissionStatus.unknown.isKnown)
        #expect(!ComputerUsePermissionStatus.unknown.accessibility)
        #expect(!ComputerUsePermissionStatus.unknown.screenRecording)
        #expect(ComputerUsePermissionStatus(structuredContent: [
            "accessibility": true,
            "screen_recording": false,
        ])?.isKnown == true)
        #expect(ComputerUsePermissionStatus(structuredContent: [
            "accessibility": true,
            "screen_recording": true,
            "source": ["attribution": "helper-daemon"],
        ])?.helperOwnsPermissions == true)
        #expect(ComputerUsePermissionStatus(structuredContent: [
            "accessibility": true,
            "screen_recording": true,
            "source": ["attribution": "caller"],
        ]) == nil)
        #expect(ComputerUsePermissionStatus(structuredContent: [
            "accessibility": true,
        ]) == nil)

        let knownGranted = ComputerUsePermissionStatus(
            accessibility: true,
            screenRecording: true,
            isKnown: true
        )
        let temporarilyUnavailable = knownGranted.applyingProbeResult(nil)
        #expect(!temporarilyUnavailable.isKnown)
        #expect(temporarilyUnavailable.accessibility)
        #expect(temporarilyUnavailable.screenRecording)

        let knownDenied = ComputerUsePermissionStatus(
            accessibility: false,
            screenRecording: false,
            isKnown: true
        )
        #expect(
            temporarilyUnavailable.applyingProbeResult(knownDenied)
                == knownDenied
        )
    }

    @Test @MainActor
    func helperBundleRegistrationUsesTheCurrentInstalledPath() {
        let path = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support/cmux/cmux-cua/helper/tag/cmux Computer Use.app"
        )
        var registeredURL: CFURL?
        let registered = ComputerUseRuntimeService.registerHelperBundle(
            at: path,
            register: { url in
                registeredURL = url
                return noErr
            }
        )

        #expect(registered)
        #expect(registeredURL as URL? == path.standardizedFileURL)
    }

    // MARK: - Cursor overlay

    @Test func cursorFeedFlipsGlobalTopLeftToAppKitBottomLeft() {
        // Non-zero primary-screen-height fixture: a feed point 200px below the top
        // of a 1200pt-tall primary display lands 1000pt above the AppKit origin.
        let point = ComputerUseCursorOverlayGeometry.appKitPoint(
            feedX: 100,
            feedY: 200,
            primaryScreenMaxY: 1200
        )
        #expect(point.x == 100)
        #expect(point.y == 1000)

        // The origin at the very top-left of the primary display flips to its full
        // height; the bottom-left flips to zero.
        #expect(ComputerUseCursorOverlayGeometry.appKitPoint(feedX: 0, feedY: 0, primaryScreenMaxY: 1200).y == 1200)
        #expect(ComputerUseCursorOverlayGeometry.appKitPoint(feedX: 0, feedY: 1200, primaryScreenMaxY: 1200).y == 0)
    }

    @Test func cursorWindowOriginPlacesHotspotAtConvertedPoint() {
        let hotspot = ComputerUseCursorOverlayGeometry.appKitPoint(
            feedX: 100,
            feedY: 200,
            primaryScreenMaxY: 1200
        )
        let origin = ComputerUseCursorOverlayGeometry.windowOrigin(forAppKitHotspot: hotspot)
        let inset = ComputerUseCursorOverlayGeometry.hotspotInset
        let height = ComputerUseCursorOverlayGeometry.windowSize.height
        // Adding the hotspot inset back to the window origin returns the hotspot.
        #expect(origin.x + inset == hotspot.x)
        #expect(origin.y + (height - inset) == hotspot.y)
    }

    @Test func cursorFeedSelectsNewestVisibleFreshFile() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeCursorState(
                to: directory.appendingPathComponent("10.cursor.json"),
                driverPID: 10, visible: true, x: 1, y: 1, updatedAt: now.addingTimeInterval(-3)
            )
            try writeCursorState(
                to: directory.appendingPathComponent("11.cursor.json"),
                driverPID: 11, visible: true, x: 42, y: 84, updatedAt: now.addingTimeInterval(-1)
            )
            // A hidden file that is newer must NOT win over the visible one.
            try writeCursorState(
                to: directory.appendingPathComponent("12.cursor.json"),
                driverPID: 12, visible: false, x: 9, y: 9, updatedAt: now
            )
            let selected = ComputerUseCursorFeed().scan(directoryURL: directory, now: now)
            #expect(selected?.driverPID == 11)
            #expect(selected?.x == 42)
            #expect(selected?.y == 84)
        }
    }

    @Test func cursorFeedIgnoresStaleAndHiddenFiles() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            // Fresh but hidden -> not shown.
            try writeCursorState(
                to: directory.appendingPathComponent("20.cursor.json"),
                driverPID: 20, visible: false, x: 1, y: 1, updatedAt: now
            )
            // Visible but stale (older than the freshness window) -> not shown.
            try writeCursorState(
                to: directory.appendingPathComponent("21.cursor.json"),
                driverPID: 21, visible: true, x: 1, y: 1, updatedAt: now.addingTimeInterval(-30)
            )
            let feed = ComputerUseCursorFeed(freshnessInterval: 5)
            #expect(feed.scan(directoryURL: directory, now: now) == nil)

            // Once the visible file refreshes it becomes selectable again.
            try writeCursorState(
                to: directory.appendingPathComponent("21.cursor.json"),
                driverPID: 21, visible: true, x: 5, y: 6, updatedAt: now
            )
            #expect(feed.scan(directoryURL: directory, now: now)?.driverPID == 21)
        }
    }

    @Test func cursorStateParsesBrandedFeedShape() throws {
        let json = """
        {"driver_pid":4242,"session":null,"visible":true,"x":812.5,"y":460.0,\
        "label":"cmux","gradient":["#12c7f5","#2d8cff","#6c5cff"],"bloom":"#2d8cff",\
        "updated_at":"2026-07-14T01:09:37.745752Z","schema":1}
        """
        let state = try #require(ComputerUseCursorState(data: Data(json.utf8)))
        #expect(state.driverPID == 4242)
        #expect(state.visible)
        #expect(state.x == 812.5)
        #expect(state.y == 460.0)
        #expect(state.label == "cmux")
        #expect(state.gradient == ["#12C7F5", "#2D8CFF", "#6C5CFF"])
        #expect(state.bloom == "#2D8CFF")
    }

    @Test func cursorColorParsingNormalizesFeedColors() {
        #expect(ComputerUseCursorColorParsing.normalizedHex("12c7f5") == "#12C7F5")
        #expect(ComputerUseCursorColorParsing.normalizedHex(" #2d8cff ") == "#2D8CFF")
        #expect(ComputerUseCursorColorParsing.normalizedHex("#6c5cffcc") == "#6C5CFFCC")
        #expect(ComputerUseCursorColorParsing.normalizedHex("not-a-color") == nil)
    }

    @Test @MainActor func decorativeCursorOverlayStaysOutOfAccessibilityTree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cua-cursor-accessibility-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeCursorState(
            to: directory.appendingPathComponent("42.cursor.json"),
            driverPID: 42,
            visible: true,
            x: 100,
            y: 100,
            updatedAt: Date()
        )

        let controller = ComputerUseCursorOverlayController(
            stateDirectoryURL: directory,
            featureEnabled: { true },
            pollInterval: 60,
            glideDuration: 0
        )
        controller.start()
        defer { controller.stop() }

        let deadline = ContinuousClock.now + .seconds(2)
        var cursorPanel: NSPanel?
        while cursorPanel == nil, ContinuousClock.now < deadline {
            cursorPanel = NSApp.windows
                .compactMap { $0 as? NSPanel }
                .first { $0.contentView is AgentCursorPointerView }
            if cursorPanel == nil {
                try await ContinuousClock().sleep(for: .milliseconds(10))
            }
        }

        let panel = try #require(cursorPanel)
        let pointerView = try #require(panel.contentView as? AgentCursorPointerView)
        #expect(!panel.isAccessibilityElement())
        #expect(!pointerView.isAccessibilityElement())
    }

    private func writeCursorState(
        to url: URL,
        driverPID: Int,
        visible: Bool,
        x: Double,
        y: Double,
        updatedAt: Date
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "driver_pid": driverPID,
            "session": NSNull(),
            "visible": visible,
            "x": x,
            "y": y,
            "label": "cmux",
            "gradient": ["#12c7f5", "#2d8cff", "#6c5cff"],
            "bloom": "#2d8cff",
            "updated_at": formatter.string(from: updatedAt),
            "schema": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: .atomic)
    }

    private func withStateDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cua-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeState(
        to url: URL,
        pid: Int,
        session: String?,
        targetPID: Int,
        lastActionAt: Date
    ) throws {
        // Mirrors the authenticated driver's schema-4 shape.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try Self.authenticatedStateData(
            driverPID: pid,
            writerPID: pid,
            writerStartSeconds: 1_700_000_000,
            writerStartMicroseconds: 123_456,
            session: session,
            targetApp: "Example App",
            targetPID: targetPID,
            targetWindowID: 7,
            lastActionAt: formatter.string(from: lastActionAt)
        )
        try data.write(to: url, options: .atomic)
    }

    private static func authenticatedStateData(
        driverPID: Int,
        writerPID: Int,
        writerStartSeconds: Int64,
        writerStartMicroseconds: Int64,
        session: String?,
        targetApp: String,
        targetPID: Int,
        targetWindowID: Int,
        lastActionAt: String
    ) throws -> Data {
        // Schema-4 keeps the historical wire prefix shared with the Rust
        // cmux-cua writer; the Swift type name is the part that was renamed.
        var message = Data("cmux-computer-use-state-v1\0".utf8)
        appendInteger(driverPID, to: &message)
        appendInteger(writerPID, to: &message)
        appendInteger(writerStartSeconds, to: &message)
        appendInteger(writerStartMicroseconds, to: &message)
        appendOptionalString(session, to: &message)
        appendOptionalString(targetApp, to: &message)
        appendInteger(targetPID, to: &message)
        appendInteger(targetWindowID, to: &message)
        appendString(lastActionAt, to: &message)
        appendInteger(4, to: &message)
        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: stateAuthenticationKey)
        )
        let object: [String: Any] = [
            "driver_pid": driverPID,
            "writer_pid": writerPID,
            "writer_start_seconds": writerStartSeconds,
            "writer_start_microseconds": writerStartMicroseconds,
            "session": session as Any? ?? NSNull(),
            "target_app": targetApp,
            "target_pid": targetPID,
            "target_window_id": targetWindowID,
            "last_action_at": lastActionAt,
            "schema": 4,
            "state_authentication_code": code.map {
                String(format: "%02x", $0)
            }.joined(),
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func appendInteger<T: BinaryInteger>(
        _ value: T,
        to message: inout Data
    ) {
        message.append(contentsOf: String(value).utf8)
        message.append(0)
    }

    private static func appendString(_ value: String, to message: inout Data) {
        let bytes = Data(value.utf8)
        message.append(contentsOf: String(bytes.count).utf8)
        message.append(UInt8(ascii: ":"))
        message.append(bytes)
        message.append(0)
    }

    private static func appendOptionalString(
        _ value: String?,
        to message: inout Data
    ) {
        guard let value else {
            message.append(contentsOf: [UInt8(ascii: "-"), 0])
            return
        }
        appendString(value, to: &message)
    }

    private static func sampledIconColor(
        _ image: NSImage,
        x: Int? = nil,
        y: Int? = nil
    ) throws -> NSColor {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let color = try #require(bitmap.colorAt(
            x: x ?? bitmap.pixelsWide / 2,
            y: y ?? bitmap.pixelsHigh * 4 / 5
        ))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private static func compositedIconColor(
        _ image: NSImage,
        appearance appearanceName: NSAppearance.Name
    ) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let composite = NSImage(
            size: NSSize(width: 128, height: 128),
            flipped: false
        ) { rect in
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                image.draw(in: rect)
            }
            return true
        }
        return try sampledIconColor(composite)
    }

    private func runShim(
        at path: String,
        logURL: URL,
        inheritedDisabled: String = "0",
        appEnabledAtSpawn: String = "1"
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        let inherited = ProcessInfo.processInfo.environment
        // A generated agent shim needs ordinary shell context, not Xcode's
        // XCTest/DYLD injection environment. Passing the complete test-host
        // environment to `/usr/bin/env bash` can attach the child to the
        // running test session and terminate the app-host runner mid-suite.
        process.environment = [
            "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": inherited["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
            "CMUX_TEST_LOG": logURL.path,
            "CMUX_COMPUTER_USE_MCP_DISABLED": inheritedDisabled,
            TerminalSurface.computerUseAppEnabledEnvironmentKey: appEnabledAtSpawn,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
