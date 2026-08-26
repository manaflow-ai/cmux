import Foundation
import Testing
import struct CMUXMobileCore.MobileBrowserStreamCapability

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
    }
}
