import Foundation
import Testing
import struct CMUXMobileCore.MobileBrowserStreamCapability
import CmuxIrxTransport

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the MDM `DisableEmbeddedBrowser` policy: the gate is
/// tier 0 (wins over user settings), and every browser-creation entry class
/// refuses under it — user-initiated, layout application, session restore,
/// and the workspace initial surface.
///
/// `.serialized`: the tests swap the process-wide
/// `managedPolicyOverrideForTesting` seam and the shared
/// `browserDisabledOverride` default.
@MainActor
@Suite(.serialized)
struct ManagedPolicyBrowserGateTests {
    /// Runs `body` with the managed-policy override and a defined user-level
    /// disable state, restoring both afterwards.
    private func withBrowserPolicy(
        managed: Bool?,
        userDisabled: Bool?,
        _ body: () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let previousOverride = BrowserAvailabilitySettings.managedPolicyOverrideForTesting
        let previousUserValue = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            BrowserAvailabilitySettings.managedPolicyOverrideForTesting = previousOverride
            if let previousUserValue {
                defaults.set(previousUserValue, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
        }
        BrowserAvailabilitySettings.managedPolicyOverrideForTesting = managed
        if let userDisabled {
            defaults.set(userDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
        } else {
            defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
        }
        try body()
    }

    @Test func managedPolicyWinsOverAUserLevelEnable() {
        withBrowserPolicy(managed: true, userDisabled: false) {
            #expect(BrowserAvailabilitySettings.isDisabled())
            #expect(!BrowserAvailabilitySettings.isEnabled())
            #expect(BrowserAvailabilitySettings.isManagedByPolicy)
        }
    }

    @Test func userLevelDisableStillWorksWithoutTheManagedPolicy() {
        withBrowserPolicy(managed: false, userDisabled: true) {
            #expect(BrowserAvailabilitySettings.isDisabled())
            #expect(!BrowserAvailabilitySettings.isManagedByPolicy)
        }
    }

    @Test func userInitiatedCreationRefusesWhileDisabled() throws {
        try withBrowserPolicy(managed: true, userDisabled: false) {
            let workspace = Workspace()
            let paneID = try #require(workspace.bonsplitController.focusedPaneId)
            #expect(workspace.newBrowserSurface(inPane: paneID, url: nil, focus: false) == nil)
            #expect(!workspace.panels.values.contains { $0 is BrowserPanel })
        }
    }

    @Test func layoutApplicationRefusesWhileDisabledByUserSetting() throws {
        // Regression: layout application used the `.restoration` policy and
        // could create browser panes while the browser was disabled.
        try withBrowserPolicy(managed: nil, userDisabled: true) {
            let workspace = Workspace()
            let paneID = try #require(workspace.bonsplitController.focusedPaneId)
            #expect(workspace.newBrowserSurface(
                inPane: paneID,
                url: nil,
                focus: false,
                creationPolicy: .layoutApplication
            ) == nil)
        }
    }

    @Test func sessionRestoreRefusesOnlyUnderTheManagedPolicy() throws {
        // User-level disable: restore still re-materializes pre-existing panes.
        try withBrowserPolicy(managed: nil, userDisabled: true) {
            let workspace = Workspace()
            let paneID = try #require(workspace.bonsplitController.focusedPaneId)
            let restored = workspace.newBrowserSurface(
                inPane: paneID,
                url: nil,
                focus: false,
                creationPolicy: .restoration
            )
            #expect(restored != nil)
            restored?.close()
        }
        // Managed policy: nothing may create a browser pane, restore included.
        try withBrowserPolicy(managed: true, userDisabled: nil) {
            let workspace = Workspace()
            let paneID = try #require(workspace.bonsplitController.focusedPaneId)
            #expect(workspace.newBrowserSurface(
                inPane: paneID,
                url: nil,
                focus: false,
                creationPolicy: .restoration
            ) == nil)
        }
    }

    @Test func browserInitialSurfaceFallsBackToATerminalWhileDisabled() {
        // Regression: `Workspace.init` with `initialSurface: .browser` built a
        // BrowserPanel with no availability check.
        withBrowserPolicy(managed: true, userDisabled: nil) {
            let workspace = Workspace(initialSurface: .browser)
            #expect(!workspace.panels.values.contains { $0 is BrowserPanel })
            #expect(workspace.panels.values.contains { $0 is TerminalPanel })
        }
    }

    @Test func dockAvailabilityProviderHonorsTheManagedPolicy() {
        withBrowserPolicy(managed: true, userDisabled: false) {
            // The default browserAvailabilityProvider consults the gate; every
            // dock browser-creation path (makePanel, session restore, app-link
            // placement) refuses through it.
            let dock = DockSplitStore(
                workspaceId: UUID(),
                baseDirectoryProvider: { nil }
            )
            #expect(!dock.isBrowserAvailable())
        }
    }

    @Test func mobileCapabilitiesDropBrowserEntriesWhileDisabled() {
        let withBrowser = MobileHostService.mobileHostCapabilities(
            includingWorkspaceChanges: true,
            includingBrowser: true
        )
        let withoutBrowser = MobileHostService.mobileHostCapabilities(
            includingWorkspaceChanges: true,
            includingBrowser: false
        )
        #expect(withBrowser.contains(MobileBrowserStreamCapability.createIdentifier))
        #expect(!withoutBrowser.contains(MobileBrowserStreamCapability.identifier))
        #expect(!withoutBrowser.contains(MobileBrowserStreamCapability.createIdentifier))
        #expect(withoutBrowser.contains("terminal.bytes.v1"))
        // The phone browser tunnel is a browser affordance too.
        #expect(withBrowser.contains(IrxTunnelCapability.current.identifier))
        #expect(!withoutBrowser.contains(IrxTunnelCapability.current.identifier))
    }

    @Test func browserTunnelIsUnavailableUnderManagedPolicy() {
        withBrowserPolicy(managed: true, userDisabled: nil) {
            #expect(!MobileHostBrowserTunnel.isAvailable)
        }
        withBrowserPolicy(managed: false, userDisabled: true) {
            // A user-level disable keeps live panes, and the tunnel with them.
            #expect(MobileHostBrowserTunnel.isAvailable)
        }
    }

    @Test func browserTunnelPolicyIsLoopbackOnlyUntilOptIn() throws {
        let suite = "cmux.tests.browser-tunnel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MobileHostBrowserTunnel.policy(defaults: defaults).allowsNonLoopbackHosts == false)
        #expect(MobileHostBrowserTunnel.policy(defaults: defaults).evaluate(host: "10.0.0.2", port: 80) == .deny)
        defaults.set(true, forKey: "mobile.browserTunnel.allowOtherHosts")
        #expect(MobileHostBrowserTunnel.policy(defaults: defaults).allowsNonLoopbackHosts)
        #expect(MobileHostBrowserTunnel.policy(defaults: defaults).evaluate(host: "169.254.169.254", port: 80) == .deny)
    }

    /// Regression coverage for issue #10866.
    ///
    /// A disabled browser must not leave an affordance behind. The actions
    /// above already refuse, but the button and menu item that reach them were
    /// still drawn, so the user got controls that only beep. Affordance
    /// visibility has to track the same gate the actions consult, under the
    /// user setting and under managed policy alike.
    @Test
    func browserAffordanceVisibilityFollowsTheAvailabilityGate() {
        withBrowserPolicy(managed: nil, userDisabled: true) {
            #expect(!BrowserAvailabilitySettings.isEnabled())
            #expect(
                !BrowserAvailabilitySettings.offersBrowserAffordance(
                    isEnabled: BrowserAvailabilitySettings.isEnabled()
                ),
                "a user-disabled browser must not offer a create affordance"
            )
        }

        withBrowserPolicy(managed: true, userDisabled: false) {
            #expect(!BrowserAvailabilitySettings.isEnabled())
            #expect(
                !BrowserAvailabilitySettings.offersBrowserAffordance(
                    isEnabled: BrowserAvailabilitySettings.isEnabled()
                ),
                "a policy-disabled browser must not offer a create affordance"
            )
        }

        withBrowserPolicy(managed: nil, userDisabled: false) {
            #expect(BrowserAvailabilitySettings.isEnabled())
            #expect(
                BrowserAvailabilitySettings.offersBrowserAffordance(
                    isEnabled: BrowserAvailabilitySettings.isEnabled()
                ),
                "an enabled browser must still offer its create affordance"
            )
        }
    }

    /// Regression coverage for the surface tab bar's globe button (#10866).
    ///
    /// The tab bar filters built-in buttons whose feature is off. The browser
    /// button was missing from that filter, so disabling the browser left the
    /// globe in the tab bar while its action refused. It has to follow the
    /// same gate under the user setting and under managed policy, and it must
    /// not take the other built-in buttons down with it.
    @Test
    func surfaceTabBarGlobeButtonFollowsTheAvailabilityGate() {
        withBrowserPolicy(managed: nil, userDisabled: true) {
            #expect(
                !Workspace.surfaceTabBarBuiltInActionIsAvailable(.newBrowser),
                "a user-disabled browser must not leave the globe button drawn"
            )
        }

        withBrowserPolicy(managed: true, userDisabled: false) {
            #expect(
                !Workspace.surfaceTabBarBuiltInActionIsAvailable(.newBrowser),
                "a policy-disabled browser must not leave the globe button drawn"
            )
        }

        withBrowserPolicy(managed: nil, userDisabled: false) {
            #expect(
                Workspace.surfaceTabBarBuiltInActionIsAvailable(.newBrowser),
                "an enabled browser must still offer its tab bar button"
            )
            // Buttons with no feature gate of their own stay available, so the
            // browser gate cannot be read as a blanket filter.
            #expect(Workspace.surfaceTabBarBuiltInActionIsAvailable(.newTerminal))
            #expect(Workspace.surfaceTabBarBuiltInActionIsAvailable(.newWorkspace))
            #expect(Workspace.surfaceTabBarBuiltInActionIsAvailable(.splitRight))
        }

        // The gate must not follow the browser either way while it is off.
        withBrowserPolicy(managed: true, userDisabled: true) {
            #expect(Workspace.surfaceTabBarBuiltInActionIsAvailable(.newTerminal))
        }
    }

    /// The availability gate is watched by one owner (#10866).
    ///
    /// Each consumer used to subscribe to all three underlying signals, which
    /// duplicated the state and made every unrelated `UserDefaults` write
    /// rebuild live tab-bar button models. The monitor must therefore
    /// broadcast a real transition and stay silent otherwise.
    @Test
    func availabilityMonitorBroadcastsOnlyRealTransitions() async {
        let defaults = UserDefaults.standard
        let previousOverride = BrowserAvailabilitySettings.managedPolicyOverrideForTesting
        let previousUserValue = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        defer {
            BrowserAvailabilitySettings.managedPolicyOverrideForTesting = previousOverride
            if let previousUserValue {
                defaults.set(previousUserValue, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
        }
        BrowserAvailabilitySettings.managedPolicyOverrideForTesting = nil
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)

        let center = NotificationCenter()
        let recorder = AvailabilityChangeRecorder()
        let token = center.addObserver(
            forName: BrowserAvailabilityMonitor.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { recorder.record() }
        }
        defer { center.removeObserver(token) }

        let monitor = BrowserAvailabilityMonitor(notificationCenter: center)
        #expect(monitor.isEnabled)

        // An unrelated defaults write must not be broadcast as a change.
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        await drainMainQueue()
        #expect(recorder.count == 0, "an unchanged gate was broadcast as a transition")

        defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        await drainMainQueue()
        #expect(recorder.count == 1, "a real transition was not broadcast")
        #expect(!monitor.isEnabled)

        // Re-signalling the same state stays silent.
        center.post(name: UserDefaults.didChangeNotification, object: nil)
        await drainMainQueue()
        #expect(recorder.count == 1, "an unchanged gate was broadcast again")
    }

    /// Lets main-queue notification delivery settle. Two turns: the monitor
    /// observes on the main queue and its broadcast is delivered on another.
    private func drainMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

/// Counts monitor broadcasts for ``ManagedPolicyBrowserGateTests``.
@MainActor
private final class AvailabilityChangeRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
