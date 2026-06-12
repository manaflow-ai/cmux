import Observation
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for https://github.com/manaflow-ai/cmux/issues/5732.
///
/// Toggling minimal mode re-evaluates the window-root `ContentView` body
/// (the titlebar band mounts/unmounts there). Each mounted workspace is
/// rebuilt with a fresh `onThemeRefreshRequest` closure, which defeats
/// SwiftUI's implicit diffing and used to re-evaluate the entire Bonsplit
/// subtree (every pane tab bar, portal, and terminal chrome) on the main
/// thread in one synchronous AttributeGraph transaction — the
/// `AGGraphSetOutputValue` / `TabBarView.splitButtons` Sentry hang family.
///
/// The fix mounts `WorkspaceContentView` behind `.equatable()`. That only
/// works while `==` ignores closure identity and still detects every
/// render-relevant input change, which is the contract pinned here.
@MainActor
final class WorkspaceContentViewEquatableTests: XCTestCase {
    private func makeView(
        workspace: Workspace,
        isWorkspaceVisible: Bool = true,
        isWorkspaceInputActive: Bool = true,
        isFullScreen: Bool = false,
        workspacePortalPriority: Int = 2,
        onThemeRefreshRequest: ((String, UInt64?, String?, String?) -> Void)? = nil
    ) -> WorkspaceContentView {
        WorkspaceContentView(
            workspace: workspace,
            isWorkspaceVisible: isWorkspaceVisible,
            isWorkspaceInputActive: isWorkspaceInputActive,
            isFullScreen: isFullScreen,
            workspacePortalPriority: workspacePortalPriority,
            onThemeRefreshRequest: onThemeRefreshRequest
        )
    }

    func testEqualityIgnoresClosureIdentitySoChromeOnlyRendersSkipBonsplit() {
        let workspace = Workspace()
        let left = makeView(workspace: workspace, onThemeRefreshRequest: { _, _, _, _ in })
        let right = makeView(workspace: workspace, onThemeRefreshRequest: { _, _, _, _ in _ = 1 })

        XCTAssertEqual(
            left,
            right,
            "Workspace mounts with identical inputs must compare equal even though the parent rebuilds onThemeRefreshRequest each render; otherwise .equatable() cannot skip the Bonsplit subtree on chrome-only window-root re-renders and the minimal-mode toggle hang (#5732) is back."
        )
    }

    /// The sidebar can't observe `cmuxExtensionSidebar.providerId` via
    /// @AppStorage (the dotted key breaks per-key KVO, so SwiftUI falls back to
    /// invalidating the holder on every UserDefaults write — which is exactly
    /// the whole-sidebar re-render on each minimal-mode toggle). The @Observable
    /// model must mutate `providerId` only when it actually changes, so
    /// Observation-tracked sidebar bodies re-render only on real changes.
    func testExtensionSidebarProviderSelectionModelMutatesOnlyOnRealChange() {
        let suiteName = "cmuxTests.providerSelection.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = ExtensionSidebarProviderSelectionModel(defaults: defaults)
        XCTAssertEqual(model.providerId, CmuxExtensionSidebarSelection.defaultProviderId)

        func observeMutation() -> () -> Bool {
            var fired = false
            withObservationTracking {
                _ = model.providerId
            } onChange: {
                fired = true
            }
            return { fired }
        }

        // Unrelated defaults writes (the minimal-mode toggle path) must not mutate.
        var didMutate = observeMutation()
        defaults.set("minimal", forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set("standard", forKey: WorkspacePresentationModeSettings.modeKey)
        XCTAssertFalse(didMutate(), "Unrelated UserDefaults writes must not re-render the sidebar (#5732).")

        // A real provider change mutates and updates the value.
        defaults.set("cmux.sidebar.extensions", forKey: CmuxExtensionSidebarSelection.defaultsKey)
        XCTAssertTrue(didMutate())
        XCTAssertEqual(model.providerId, "cmux.sidebar.extensions")

        // Rewriting the same value must not mutate again.
        didMutate = observeMutation()
        defaults.set("cmux.sidebar.extensions", forKey: CmuxExtensionSidebarSelection.defaultsKey)
        XCTAssertFalse(didMutate(), "Re-writing an unchanged provider id must not re-render the sidebar.")
    }

    func testEqualityDetectsEachRenderRelevantInputChange() {
        let workspace = Workspace()
        let base = makeView(workspace: workspace)

        XCTAssertNotEqual(
            base,
            makeView(workspace: Workspace()),
            "A different workspace instance must re-render: the Bonsplit tree renders that workspace's panes."
        )
        XCTAssertNotEqual(
            base,
            makeView(workspace: workspace, isWorkspaceVisible: false),
            "Visibility drives panel mounting and hibernation presentation; changes must re-render."
        )
        XCTAssertNotEqual(
            base,
            makeView(workspace: workspace, isWorkspaceInputActive: false),
            "Input-activity drives focus wiring and bonsplit interactivity; changes must re-render."
        )
        XCTAssertNotEqual(
            base,
            makeView(workspace: workspace, isFullScreen: true),
            "Fullscreen flips the minimal-mode safe-area cancellation; changes must re-render."
        )
        XCTAssertNotEqual(
            base,
            makeView(workspace: workspace, workspacePortalPriority: 0),
            "Portal priority orders portal-hosted AppKit surfaces; changes must re-render."
        )
    }
}
