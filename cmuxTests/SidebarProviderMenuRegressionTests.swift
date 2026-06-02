import Foundation
import Testing
import CmuxExtensionKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the right-click sidebar-button view switcher.
///
/// v0.64.10 shipped seven built-in sidebar views — Default Workspaces plus the
/// Project Worktrees, Attention Queue, Dev Servers, Last Prompt, Super Compact,
/// and Browser Stack presets — that the sidebar-button context menu let users
/// switch between. #4994 ("Replace sidebar extension kit contract") swept that
/// menu behind the experimental Extensions beta flag and stubbed the built-in
/// providers out, so on a default install (beta off) the menu and every one of
/// its views disappeared (https://github.com/manaflow-ai/cmux/issues/5173).
///
/// These tests pin the two guarantees the regression broke: the built-in views
/// are available regardless of the experimental flag, and a selected view
/// resolves to itself (which is what drives the menu's active-view checkmark).
@MainActor
@Suite(.serialized)
struct SidebarProviderMenuRegressionTests {
    /// Stable ids of the seven built-in sidebar views, in menu order.
    private static let builtInViewIDs: [String] = [
        "cmux.sidebar.default",
        "com.example.cmux.sidebar.project-worktrees",
        "com.example.cmux.sidebar.attention-queue",
        "com.example.cmux.sidebar.dev-servers",
        "com.example.cmux.sidebar.last-prompt",
        "com.example.cmux.sidebar.super-compact",
        "com.example.cmux.sidebar.browser-stack",
    ]

    private static let extensionsBetaKey = "extensions.beta.enabled"

    private func withExtensionsBeta(_ enabled: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.extensionsBetaKey)
        defaults.set(enabled, forKey: Self.extensionsBetaKey)
        defer { restore(previous, forKey: Self.extensionsBetaKey) }
        body()
    }

    private func withSelectedProvider(_ providerId: String, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let key = CmuxExtensionSidebarSelection.defaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(providerId, forKey: key)
        defer { restore(previous, forKey: key) }
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The built-in views must remain selectable even when the experimental
    /// Extensions beta is disabled — the regression hid every one of them.
    @Test
    func builtInViewsAvailableWhenExtensionsBetaDisabled() {
        withExtensionsBeta(false) {
            let availableIDs = Set(CmuxExtensionSidebarSelection.descriptors.map(\.id))
            for builtInID in Self.builtInViewIDs {
                #expect(
                    availableIDs.contains(builtInID),
                    "Built-in sidebar view \(builtInID) is missing from the switcher menu"
                )
            }
        }
    }

    /// Persisting a built-in view as the selection drives the menu's active-view
    /// checkmark to that view. This exercises the same path `showMenu` uses to
    /// decide which item is checked — read the persisted id from `UserDefaults`,
    /// resolve it through `effectiveProviderId`, then look up the descriptor —
    /// rather than asserting on the id in isolation.
    @Test
    func persistedBuiltInSelectionDrivesMenuCheckmark() {
        withExtensionsBeta(false) {
            for builtInID in Self.builtInViewIDs {
                withSelectedProvider(builtInID) {
                    let persisted = UserDefaults.standard.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
                        ?? CmuxExtensionSidebarSelection.defaultProviderId
                    let effective = CmuxExtensionSidebarSelection.effectiveProviderId(
                        persisted,
                        extensionsEnabled: CmuxExtensionSidebarSelection.isEnabled
                    )
                    let checkedID = CmuxExtensionSidebarSelection.descriptor(for: effective).id
                    #expect(
                        checkedID == builtInID,
                        "Persisted selection \(builtInID) did not drive the menu checkmark (got \(checkedID))"
                    )
                }
            }
        }
    }

    /// The hosted-extensions provider belongs to the experimental Extensions
    /// feature, so the effective selection (which the menu checkmark tracks)
    /// downgrades it to the default sidebar while the beta is off and honors it
    /// while the beta is on. Built-in views resolve to themselves either way —
    /// they are never gated by the flag.
    @Test
    func effectiveSelectionGatesHostedExtensionButNotBuiltInViews() {
        let projectWorktrees = "com.example.cmux.sidebar.project-worktrees"
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(projectWorktrees, extensionsEnabled: false) == projectWorktrees
        )
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(projectWorktrees, extensionsEnabled: true) == projectWorktrees
        )

        let hosted = CmuxExtensionSidebarSelection.hostedExtensionsProviderId
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(hosted, extensionsEnabled: true) == hosted
        )
        #expect(
            CmuxExtensionSidebarSelection.effectiveProviderId(hosted, extensionsEnabled: false) == CmuxExtensionSidebarSelection.defaultProviderId
        )
    }
}
