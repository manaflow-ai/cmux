import AppKit
import CmuxComputerUse
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use Watch Target Runtime", .serialized)
struct ComputerUseWatchTargetRuntimeTests {
    private static let stateFixture = ComputerUseAuthenticatedStateFixture()

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

        let targetFixture = try await ComputerUseExternalApplicationFixture(
            applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")
        )
        defer { targetFixture.terminate() }
        let target = targetFixture.application
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
        let proxySessionID = "\(driverSessionID)-mcp-73-2000"
        let liveSession = ComputerUseLiveDriverSession(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            logicalSessionID: "watcher-main-actor-session",
            rootProcessIdentities: [writerIdentity]
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
                    authenticationKey: Self.stateFixture.authenticationKey
                ),
                activate: { application in
                    activationEvents.continuation.yield(
                        application.processIdentifier
                    )
                }
            )
            controller.start()
            defer { controller.stop() }

            let actionDate = max(Date(), targetLaunchDate)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            let state = try Self.stateFixture.data(
                driverPID: 70_001,
                writerPID: Int(writerIdentity.pid),
                writerStartSeconds: writerIdentity.startSeconds,
                writerStartMicroseconds: writerIdentity.startMicroseconds,
                session: proxySessionID,
                targetApp: targetName,
                targetPID: Int(target.processIdentifier),
                targetWindowID: 7,
                lastActionAt: formatter.string(from: actionDate)
            )

            try state.write(
                to: directory.appendingPathComponent("watcher.json"),
                options: .atomic
            )
            // Exercise the same scan-queue to main-actor hop as the directory
            // watcher. A direct refresh is the deterministic backstop when a
            // coalesced filesystem event is delivered before the file is visible
            // to the utility queue on a busy app-host.
            controller.refresh()
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

        let targetFixture = try await ComputerUseExternalApplicationFixture(
            applicationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app")
        )
        defer { targetFixture.terminate() }
        let target = targetFixture.application
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
                authenticationKey: Self.stateFixture.authenticationKey
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
        let foregroundState = try Self.stateFixture.data(
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
        let backgroundState = try Self.stateFixture.data(
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
        var scannedLogicalSessionID: String?
        while let logicalSessionID = await scannedIterator.next() {
            if logicalSessionID == backgroundLogicalSessionID {
                scannedLogicalSessionID = logicalSessionID
                break
            }
        }

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
        #expect(cursorVisibilityChanges.count == 1)
        #expect(cursorVisibilityChanges.first?.driverSessionID == backgroundDriverSessionID)
        #expect(cursorVisibilityChanges.first?.visible == true)
        #expect(!controller.isRunningInBackground(
            driverSessionID: backgroundDriverSessionID,
            logicalSessionID: backgroundLogicalSessionID
        ))
    }
}
