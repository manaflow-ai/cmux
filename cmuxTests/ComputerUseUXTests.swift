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
                    stateWriterIdentity: nil
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
                    stateWriterIdentity: nil
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
    @Test func onboardingRetriesUntilPermissionsAreVerified() {
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: true, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: false, screenRecordingGranted: true))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: true, featureEnabled: true, permissionStatusIsKnown: false,
            accessibilityGranted: true, screenRecordingGranted: true))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: false, screenRecordingGranted: true))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: true, screenRecordingGranted: false))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: false,
            accessibilityGranted: true, screenRecordingGranted: true))
        #expect(!ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, permissionStatusIsKnown: true,
            accessibilityGranted: true, screenRecordingGranted: true))
        #expect(!ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: false, permissionStatusIsKnown: false,
            accessibilityGranted: false, screenRecordingGranted: false))
    }

    @Test @MainActor func onlyRealComputerUseToolHooksTriggerOnboarding() {
        let invocation = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .preToolUse,
            source: "claude",
            toolName: "mcp__cmux-computer-use__start_session"
        )
        #expect(ComputerUseUXCoordinator.isComputerUseToolInvocation(invocation))

        let sessionStart = WorkstreamEvent(
            sessionId: "session-1",
            hookEventName: .sessionStart,
            source: "claude",
            toolName: "mcp__cmux-computer-use__start_session"
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

    @Test func parsesRealDriverStateFileShape() throws {
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
        let state = try #require(ComputerUseDriverState(
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

        #expect(ComputerUseDriverState(
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
        let state = try #require(ComputerUseDriverState(
            data: data,
            authenticationKey: Self.stateAuthenticationKey
        ))

        #expect(state.belongsToProcessTree(
            rootProcessIdentities: [currentIdentity]
        ))
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
        let state = try #require(ComputerUseDriverState(
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
        let state = try #require(ComputerUseDriverState(
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

    @Test func liveDriverSessionRejectsGenerationlessPIDFallback() throws {
        let processID = Int(ProcessInfo.processInfo.processIdentifier)
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "generationless-session"
            ),
            lifecycle: .running,
            updatedAt: Date().timeIntervalSince1970,
            processLiveness: .running,
            processIDs: [processID],
            agentProcessIDs: [processID],
            agentProcessIdentities: [:]
        )

        #expect(ComputerUseLiveDriverSession(
            workspaceID: UUID(),
            surfaceID: UUID(),
            entry: entry
        ) == nil)
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
    }

    @Test @MainActor func onboardingContentCannotOutgrowItsAppKitWindow() async {
        let expandedSize = CGSize(width: 600, height: 440)
        let companionSize = CGSize(width: 532, height: 110)
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

    @Test func permissionRowsKeepOneRepeatableAllowFlowUntilGranted() {
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: false,
            statusIsKnown: true,
            nativeRequestAttempted: false
        ) == .allow)
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: false,
            statusIsKnown: true,
            nativeRequestAttempted: true
        ) == .allow)
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: true,
            statusIsKnown: true,
            nativeRequestAttempted: true
        ) == .done)
        #expect(ComputerUsePermissionRowAction.resolve(
            granted: true,
            statusIsKnown: false,
            nativeRequestAttempted: true
        ) == .checkStatus)
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
            onboardingSize: CGSize(width: 532, height: 110),
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
        #expect(paths.daemonSocketURL.path == "/tmp/cmux-cua-501/\(paths.scope)/cua.sock")
        #expect(paths.stateDirectoryURL.path.hasSuffix(
            "/Library/Application Support/cmux/computer-use/runtime/\(paths.scope)/state"
        ))
        #expect(
            paths.permissionDatabaseDirectoryURL.path
                == "/Users/tester/Library/Application Support/com.apple.TCC"
        )
        #expect(paths.installedHelperAppURL.path.hasSuffix(
            "/Library/Application Support/cmux/computer-use/helper/\(paths.scope)/cmux Computer Use.app"
        ))
    }

    @Test func onlyExactSurfaceDerivedDriverSessionsAreManaged() {
        let surfaceID = UUID()
        #expect(ComputerUseSessionScope.isManagedDriverSessionID(
            ComputerUseSessionScope.driverSessionID(surfaceID: surfaceID)
        ))
        #expect(!ComputerUseSessionScope.isManagedDriverSessionID(
            "cmux-\(surfaceID.uuidString)-mcp-1"
        ))
        #expect(!ComputerUseSessionScope.isManagedDriverSessionID("default"))
        #expect(!ComputerUseSessionScope.isManagedDriverSessionID("cmux-not-a-uuid"))
    }

    @Test func helperTerminationRecoveryIgnoresIntentionalAndForeignExits() {
        let helperURL = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support/cmux/computer-use/helper/tag/cmux Computer Use.app"
        )
        let helperBundleIdentifier = "com.cmuxterm.app.debug.tag.computer-use"

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
            terminatedBundleIdentifier: "com.trycua.driver",
            terminatedBundleURL: URL(fileURLWithPath: "/Applications/CuaDriver.app"),
            helperBundleIdentifier: helperBundleIdentifier,
            helperBundleURL: helperURL
        ))
    }

    @Test func trackedHelperTerminationRecoversWhenLaunchServicesDropsBundleMetadata() {
        let helperURL = URL(
            fileURLWithPath: "/Users/tester/Library/Application Support/cmux/computer-use/helper/tag/cmux Computer Use.app"
        )

        #expect(ComputerUseRuntimeService.shouldRecoverAfterHelperTermination(
            desiredEnabled: true,
            acceptsNewLaunches: true,
            wasExpected: false,
            isTrackedHelperProcess: true,
            terminatedBundleIdentifier: nil,
            terminatedBundleURL: nil,
            helperBundleIdentifier: "com.cmuxterm.app.debug.tag.computer-use",
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
        #expect(questionMark.daemonSocketURL.path.utf8.count < 104)
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
        ])
        #expect(configuration.environment["CUA_DRIVER_RS_EXTERNAL_PERMISSION_FLOW"] == "1")
        #expect(configuration.environment["CUA_DRIVER_RS_PERMISSIONS_GATE"] == "0")
        #expect(configuration.environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"] == "false")
        #expect(configuration.environment["CUA_DRIVER_RS_UPDATE_CHECK"] == "false")
        #expect(configuration.environment["CUA_DRIVER_RS_RESPONSIBILITY_DISCLAIMED"] == "1")
        #expect(configuration.environment["CUA_DRIVER_SOCKET_AUTH_TOKEN"] == "test-auth-token")
        #expect(configuration.environment["CUA_DRIVER_SOCKET_AUTHORIZED_ROOT_PID"]
            == "42")
        #expect(configuration.environment["CUA_DRIVER_SOCKET_AUTHORIZED_ROOT_START_SECONDS"]
            == "1700000000")
        #expect(configuration.environment["CUA_DRIVER_SOCKET_AUTHORIZED_ROOT_START_MICROSECONDS"]
            == "123456")
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
    @Test func menuRefreshDoesNotScheduleAgentIndexReload() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-computer-use-menu-refresh-\(UUID().uuidString)", isDirectory: true)
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
            liveAgentIndex: sharedIndex,
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
            .appendingPathComponent("cmux-computer-use-live-setting-\(UUID().uuidString)", isDirectory: true)
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
        let shim = try #require(TerminalSurface.installClaudeCommandShimIfPossible(
            wrapperURL: wrapperURL,
            surfaceId: UUID(),
            temporaryDirectory: shimRoot,
            computerUseSettingFileURL: settingURL
        ))

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

    @Test func backgroundModeSuppressesAutomaticTargetFrontingUntilResumed() {
        #expect(ComputerUseWatchTargetDecision.activation(
            current: 200,
            lastActivated: 100,
            automaticActivationEnabled: false
        ) == nil)
        #expect(ComputerUseWatchTargetDecision.activation(
            current: 200,
            lastActivated: 100,
            automaticActivationEnabled: true
        ) == 200)
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
                "cmux-computer-use-watcher-\(UUID().uuidString)",
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

    @Test func watchTargetFeedSelectsNewestFreshDriverState() throws {
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

    @Test func watchTargetFeedRejectsStaleDriverState() throws {
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
            .appendingPathComponent("cmux-computer-use-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func runShim(
        at path: String,
        logURL: URL,
        inheritedDisabled: String = "0",
        appEnabledAtSpawn: String = "1"
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_LOG"] = logURL.path
        environment["CMUX_COMPUTER_USE_MCP_DISABLED"] = inheritedDisabled
        environment[TerminalSurface.computerUseAppEnabledEnvironmentKey] = appEnabledAtSpawn
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
