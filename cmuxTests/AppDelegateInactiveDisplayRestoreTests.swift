import AppKit
import CmuxWindowing
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AppDelegateInactiveDisplayRestoreTests {
    private let builtInFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    private let builtInVisible = CGRect(x: 0, y: 0, width: 1_512, height: 944)
    private let externalFrame = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
    private let externalVisible = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_055)

    private var builtIn: AppDelegate.SessionDisplayGeometry {
        geometry("uuid:BUILTIN", builtInFrame, builtInVisible, displayID: 1)
    }

    private var external: AppDelegate.SessionDisplayGeometry {
        geometry("uuid:EXTERNAL", externalFrame, externalVisible, displayID: 2)
    }

    private struct SameConfigurationFixture {
        let appDelegate: AppDelegate
        let windowId: UUID
        let window: NSWindow
        let signature: String
        let rescuedBuiltInFrame: CGRect
    }

    @MainActor
    private struct DisplayReconcileState {
        let lastAppliedSignature: String?
        let lastVisibleTopology: [MainWindowVisibleFrameTopologySignatureEntry]?
        let unknownConfiguration: Bool
        let unknownVisibleTopology: Bool
        let inactiveState: AppDelegate.InactiveDisplayTransitionState
        let captureSuppressed: Bool
        let suppressionSignature: String?
        let suppressionGeneration: Int?
        let reconcileRetryBudget: Int
        let topologyRetryBudget: Int

        init(_ appDelegate: AppDelegate) {
            lastAppliedSignature = appDelegate.lastAppliedConfigurationSignature
            lastVisibleTopology = appDelegate.lastVisibleFrameFitTopologySignature
            unknownConfiguration = appDelegate.didObserveUnknownDisplayConfiguration
            unknownVisibleTopology = appDelegate.didObserveUnknownVisibleFrameFitTopology
            inactiveState = appDelegate.inactiveDisplayTransitionState
            captureSuppressed = appDelegate.isScreenChangeCaptureSuppressed
            suppressionSignature = appDelegate.screenChangeCaptureSuppressionSignature
            suppressionGeneration = appDelegate.screenChangeCaptureSuppressionSignatureGeneration
            reconcileRetryBudget = appDelegate.screenChangeReconcileRetryBudget
            topologyRetryBudget = appDelegate.visibleFrameFitTopologyRetryBudget
        }

        func restore(on appDelegate: AppDelegate) {
            appDelegate.lastAppliedConfigurationSignature = lastAppliedSignature
            appDelegate.lastVisibleFrameFitTopologySignature = lastVisibleTopology
            appDelegate.didObserveUnknownDisplayConfiguration = unknownConfiguration
            appDelegate.didObserveUnknownVisibleFrameFitTopology = unknownVisibleTopology
            appDelegate.inactiveDisplayTransitionState = inactiveState
            appDelegate.isScreenChangeCaptureSuppressed = captureSuppressed
            appDelegate.screenChangeCaptureSuppressionSignature = suppressionSignature
            appDelegate.screenChangeCaptureSuppressionSignatureGeneration = suppressionGeneration
            appDelegate.screenChangeReconcileRetryBudget = reconcileRetryBudget
            appDelegate.visibleFrameFitTopologyRetryBudget = topologyRetryBudget
        }
    }

    private func geometry(
        _ stableID: String,
        _ frame: CGRect,
        _ visibleFrame: CGRect,
        displayID: UInt32
    ) -> AppDelegate.SessionDisplayGeometry {
        AppDelegate.SessionDisplayGeometry(
            displayID: displayID,
            stableID: stableID,
            frame: frame,
            visibleFrame: visibleFrame
        )
    }

    private func makeSameConfigurationFixture() throws -> SameConfigurationFixture {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let windowId = UUID()
        let signature = try #require([builtIn, external].displayConfigurationSignature())
        let externalWindowFrame = CGRect(x: -1_600, y: 200, width: 1_000, height: 700)
        let rescuedBuiltInFrame = CGRect(x: 220, y: 160, width: 1_000, height: 700)
        let rememberedEntry = SessionConfigFrameEntry(
            signature: signature,
            frame: SessionRectSnapshot(externalWindowFrame),
            display: SessionDisplaySnapshot(
                displayID: 2,
                stableID: "uuid:EXTERNAL",
                frame: SessionRectSnapshot(externalFrame),
                visibleFrame: SessionRectSnapshot(externalVisible)
            ),
            lastUsedAt: 100
        )
        let snapshot = emptyWindowSnapshot(windowId: windowId, configFrames: [rememberedEntry])
        let createdWindowId = appDelegate.createMainWindow(
            sessionWindowSnapshot: snapshot,
            preferredWindowId: windowId,
            shouldActivate: false
        )
        return SameConfigurationFixture(
            appDelegate: appDelegate,
            windowId: createdWindowId,
            window: try #require(appDelegate.mainWindow(for: createdWindowId)),
            signature: signature,
            rescuedBuiltInFrame: rescuedBuiltInFrame
        )
    }

    private func emptyWindowSnapshot(
        windowId: UUID,
        configFrames: [SessionConfigFrameEntry]
    ) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: windowId,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil),
            configFrames: configFrames
        )
    }

    private func closeCreatedWindow(_ appDelegate: AppDelegate, windowId: UUID) {
        guard let window = appDelegate.mainWindow(for: windowId) else { return }
#if DEBUG
        let previousConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler }
#endif
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }

    private func prepareSameConfiguration(_ fixture: SameConfigurationFixture) {
        let displays = [builtIn, external]
        fixture.appDelegate.inactiveDisplayTransitionState = .idle
        fixture.appDelegate.lastAppliedConfigurationSignature = fixture.signature
        fixture.appDelegate.didObserveUnknownDisplayConfiguration = false
        fixture.appDelegate.lastVisibleFrameFitTopologySignature = MainWindowVisibleFrameFitCore()
            .trustedTopologySignature(of: displays)
        fixture.appDelegate.didObserveUnknownVisibleFrameFitTopology = false
    }

    private func cleanUp(
        _ fixture: SameConfigurationFixture,
        restoring state: DisplayReconcileState
    ) {
        NotificationQueue.default.dequeueNotifications(
            matching: Notification(
                name: AppDelegate.screenChangeReconcileNotification,
                object: fixture.appDelegate
            ),
            coalesceMask: Int(
                NotificationQueue.NotificationCoalescing.onName.rawValue
                    | NotificationQueue.NotificationCoalescing.onSender.rawValue
            )
        )
        fixture.appDelegate.removeInactiveDisplayRecoveryInteractionMonitor()
        state.restore(on: fixture.appDelegate)
        fixture.appDelegate.windowConfigFrames.removeValue(forKey: fixture.windowId)
        closeCreatedWindow(fixture.appDelegate, windowId: fixture.windowId)
    }

    @Test
    func sameDisplayConfigurationReconcileRespectsInactiveRecovery() throws {
        let fixture = try makeSameConfigurationFixture()
        let appDelegate = fixture.appDelegate
        let previousState = DisplayReconcileState(appDelegate)
        defer { cleanUp(fixture, restoring: previousState) }

        prepareSameConfiguration(fixture)
        appDelegate.beginInactiveDisplayTransition(configurationSignature: fixture.signature)
        fixture.window.setFrame(fixture.rescuedBuiltInFrame, display: false)

        appDelegate.reconcileMainWindowFramesAfterScreenChange(
            displays: (available: [builtIn, external], fallback: builtIn),
            isMirrored: false
        )
        #expect(fixture.window.frame.equalTo(fixture.rescuedBuiltInFrame))
        #expect(appDelegate.inactiveDisplayTransitionState == .armed(signature: fixture.signature))
        #expect(!appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: fixture.signature))

        appDelegate.markInactiveDisplayRecoveryReady(isSessionActiveAndUnlocked: true)
        appDelegate.reconcileMainWindowFramesAfterScreenChange(
            displays: (available: [builtIn, external], fallback: builtIn),
            isMirrored: false
        )

        let restoredDisplay = try #require(
            AppDelegate.bestDisplayForFrame(fixture.window.frame, in: [builtIn, external])
        )
        #expect(AppDelegate.samePhysicalDisplay(restoredDisplay, external))
        #expect(!fixture.window.frame.equalTo(fixture.rescuedBuiltInFrame))
        #expect(
            appDelegate.inactiveDisplayTransitionState == .recoveryReady(signature: fixture.signature)
        )
        #expect(!appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: fixture.signature))

        appDelegate.finalizeInactiveDisplayRecovery(
            displays: (available: [builtIn, external], fallback: builtIn),
            isMirrored: false
        )
        #expect(appDelegate.inactiveDisplayTransitionState == .idle)
        #expect(appDelegate.inactiveDisplayRecoveryInteractionMonitor == nil)
        #expect(appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: fixture.signature))
    }

    @Test
    func earlyRecoveryReconcileKeepsTokenForLateRehome() throws {
        let fixture = try makeSameConfigurationFixture()
        let appDelegate = fixture.appDelegate
        let previousState = DisplayReconcileState(appDelegate)
        defer { cleanUp(fixture, restoring: previousState) }

        prepareSameConfiguration(fixture)
        appDelegate.beginScreenChangeCaptureSuppression()
        appDelegate.inactiveDisplayTransitionState = .recoveryReady(signature: fixture.signature)
        appDelegate.updateInactiveDisplayRecoveryAfterReconcile(currentSignature: fixture.signature)

        #expect(
            appDelegate.inactiveDisplayTransitionState
                == .recoveryReady(signature: fixture.signature)
        )
        #expect(!appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: fixture.signature))

        fixture.window.setFrame(fixture.rescuedBuiltInFrame, display: false)
        appDelegate.reconcileMainWindowFramesAfterScreenChange(
            displays: (available: [builtIn, external], fallback: builtIn),
            isMirrored: false
        )

        let restoredDisplay = try #require(
            AppDelegate.bestDisplayForFrame(fixture.window.frame, in: [builtIn, external])
        )
        #expect(AppDelegate.samePhysicalDisplay(restoredDisplay, external))
        #expect(appDelegate.inactiveDisplayRecoveryIsPending)

        appDelegate.finalizeInactiveDisplayRecovery(
            displays: (available: [builtIn, external], fallback: builtIn),
            isMirrored: false
        )
        #expect(appDelegate.inactiveDisplayTransitionState == .idle)
        #expect(appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: fixture.signature))
    }

    @Test
    func sameDisplayConfigurationReconcileWithoutInactiveRecoveryLeavesWindowAlone() throws {
        let fixture = try makeSameConfigurationFixture()
        let appDelegate = fixture.appDelegate
        let previousState = DisplayReconcileState(appDelegate)
        defer { cleanUp(fixture, restoring: previousState) }

        prepareSameConfiguration(fixture)
        fixture.window.setFrame(fixture.rescuedBuiltInFrame, display: false)
        appDelegate.reconcileMainWindowFramesAfterScreenChange(
            displays: (available: [builtIn, external], fallback: builtIn),
            isMirrored: false
        )

        #expect(fixture.window.frame.equalTo(fixture.rescuedBuiltInFrame))
        #expect(appDelegate.inactiveDisplayTransitionState == .idle)
    }

    @Test
    func inactiveRecoveryOnlyRestoresAcrossPhysicalDisplays() throws {
        let rememberedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: "uuid:EXTERNAL",
            frame: SessionRectSnapshot(externalFrame),
            visibleFrame: SessionRectSnapshot(externalVisible)
        )
        let shiftedExternalFrame = CGRect(x: -1_300, y: 120, width: 900, height: 650)
        let rescuedBuiltInFrame = CGRect(x: 220, y: 160, width: 900, height: 650)

        #expect(!AppDelegate.shouldRestoreAfterInactiveDisplayTransition(
            liveFrame: shiftedExternalFrame,
            rememberedDisplay: rememberedDisplay,
            availableDisplays: [builtIn, external]
        ))
        #expect(AppDelegate.shouldRestoreAfterInactiveDisplayTransition(
            liveFrame: rescuedBuiltInFrame,
            rememberedDisplay: rememberedDisplay,
            availableDisplays: [builtIn, external]
        ))
    }

    @Test
    func recoveryWaitsUntilTheConsoleSessionIsUnlocked() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let previousState = DisplayReconcileState(appDelegate)
        defer {
            NotificationQueue.default.dequeueNotifications(
                matching: Notification(
                    name: AppDelegate.screenChangeReconcileNotification,
                    object: appDelegate
                ),
                coalesceMask: Int(
                    NotificationQueue.NotificationCoalescing.onName.rawValue
                        | NotificationQueue.NotificationCoalescing.onSender.rawValue
                )
            )
            appDelegate.removeInactiveDisplayRecoveryInteractionMonitor()
            previousState.restore(on: appDelegate)
        }

        appDelegate.inactiveDisplayTransitionState = .armed(signature: "docked")
        appDelegate.markInactiveDisplayRecoveryReady(isSessionActiveAndUnlocked: false)
        #expect(appDelegate.inactiveDisplayTransitionState == .armed(signature: "docked"))

        appDelegate.markInactiveDisplayRecoveryReady(isSessionActiveAndUnlocked: true)
        appDelegate.markInactiveDisplayRecoveryReady(isSessionActiveAndUnlocked: true)
        #expect(
            appDelegate.inactiveDisplayTransitionState == .recoveryReady(signature: "docked")
        )
        #expect(appDelegate.inactiveDisplayRecoveryInteractionMonitor != nil)
    }

    @Test
    func topologyChangeWhileInactiveUsesNormalConfigurationRestore() throws {
        let fixture = try makeSameConfigurationFixture()
        let appDelegate = fixture.appDelegate
        let previousState = DisplayReconcileState(appDelegate)
        defer { cleanUp(fixture, restoring: previousState) }

        prepareSameConfiguration(fixture)
        appDelegate.beginInactiveDisplayTransition(configurationSignature: fixture.signature)
        fixture.window.setFrame(fixture.rescuedBuiltInFrame, display: false)
        appDelegate.reconcileMainWindowFramesAfterScreenChange(
            displays: (available: [builtIn], fallback: builtIn),
            isMirrored: false
        )
        #expect(fixture.window.frame.equalTo(fixture.rescuedBuiltInFrame))
        #expect(appDelegate.inactiveDisplayTransitionState == .armed(signature: fixture.signature))

        appDelegate.markInactiveDisplayRecoveryReady(isSessionActiveAndUnlocked: true)
        appDelegate.reconcileMainWindowFramesAfterScreenChange(
            displays: (available: [builtIn], fallback: builtIn),
            isMirrored: false
        )
        #expect(fixture.window.frame.equalTo(fixture.rescuedBuiltInFrame))
        #expect(appDelegate.inactiveDisplayTransitionState == .idle)

        appDelegate.reconcileMainWindowFramesAfterScreenChange(
            displays: (available: [builtIn, external], fallback: builtIn),
            isMirrored: false
        )
        let restoredDisplay = try #require(
            AppDelegate.bestDisplayForFrame(fixture.window.frame, in: [builtIn, external])
        )
        #expect(AppDelegate.samePhysicalDisplay(restoredDisplay, external))
    }
}
