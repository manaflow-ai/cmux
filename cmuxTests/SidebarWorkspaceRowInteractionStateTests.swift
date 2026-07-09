import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Sidebar row interaction tests extracted from the primary sidebar snapshot refresh test file, which sits at its file-length budget.
@Suite struct SidebarWorkspaceRowInteractionStateTests {
    @Test func appKitMenuTrackingEndClearsStaleContextMenuVisibility() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        #expect(state.contextMenuVisible)

        let didEndTracking = state.contextMenuTrackingDidEnd(pointerInsideRow: true)
        #expect(didEndTracking)
        state.setPointerHovering(true)

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "AppKit menu tracking ending must clear stale SwiftUI context-menu visibility so later hover can reveal row affordances."
        )
    }

    @Test func appKitMenuTrackingEndUsesReconciledPointerExit() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()

        let didEndTracking = state.contextMenuTrackingDidEnd(pointerInsideRow: false)
        #expect(didEndTracking)

        #expect(
            !state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "If the pointer leaves through the context menu, AppKit menu tracking reconciliation must keep the row affordance hidden."
        )
    }

    @Test @MainActor func menuTrackingReconcilerIgnoresSubmenuEndNotifications() {
        let rootMenu = NSMenu()
        let submenu = NSMenu()
        let item = NSMenuItem(title: "submenu", action: nil, keyEquivalent: "")
        rootMenu.addItem(item)
        rootMenu.setSubmenu(submenu, for: item)

        #expect(SidebarWorkspaceRowMenuTrackingReconcilerView.shouldReconcileMenuEnd(object: rootMenu))
        #expect(!SidebarWorkspaceRowMenuTrackingReconcilerView.shouldReconcileMenuEnd(object: submenu))
        #expect(!SidebarWorkspaceRowMenuTrackingReconcilerView.shouldReconcileMenuEnd(object: nil))
    }

    @Test func hoverDuringContextMenuStaysHiddenUntilDismissal() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.setPointerHovering(true)

        #expect(
            !state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Pointer hover updates observed during the context-menu lifecycle must not reveal the close affordance under the menu."
        )

        state.contextMenuDidDisappear()

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Once the context menu dismisses, the last observed pointer position may reveal the close affordance."
        )
    }

    @Test func contextMenuDismissalRestoresHoverWithoutPointerMovement() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.contextMenuDidDisappear()

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Closing a context menu without moving the pointer must restore the row hover affordance."
        )
    }

    @Test func pointerExitWhileContextMenuIsVisibleStaysHiddenAfterDismissal() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.contextMenuTrackingObserverDidInstall()
        state.setPointerHovering(false)
        state.contextMenuDidDisappear()

        #expect(
            !state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Pointer exit remains authoritative even when it is observed during the context-menu lifecycle."
        )
    }

    @Test func swiftUIOnlyFastContextMenuDismissalKeepsInitialHoverFallback() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.setPointerHovering(false)
        state.contextMenuDidDisappear()

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A SwiftUI hover-exit caused by the menu taking focus must not erase the initial hover fallback before the AppKit reconciler mounts."
        )
    }

    @Test func noHoverDoesNotRevealCloseButtonWhileContextMenuIsVisible() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.setPointerHovering(false)

        #expect(
            !state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A visible context menu must not make the close affordance visible when the pointer is not hovering."
        )
    }

    @Test @MainActor func hoverReconcilerRestoresCloseButtonAfterLifecycleHoverReset() {
        var state = SidebarWorkspaceRowInteractionState()

        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        view.onPointerHoverChanged = { state.setPointerHovering($0) }

        view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))
        #expect(state.shouldShowCloseButton(canCloseWorkspace: true, shortcutHintModeActive: false))

        state.setPointerHovering(false)
        #expect(!state.shouldShowCloseButton(canCloseWorkspace: true, shortcutHintModeActive: false))

        view.reconcilePointerLocation(pointInView: NSPoint(x: 60, y: 14))

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "When sidebar updates or row reuse clear SwiftUI hover state while the pointer is still inside the row, the AppKit hover reconciler must restore the close affordance without waiting for another mouse move."
        )
    }

    @Test func contextMenuAppearanceHidesExistingCloseButtonUntilPointerIsReconciled() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        #expect(state.shouldShowCloseButton(canCloseWorkspace: true, shortcutHintModeActive: false))

        state.contextMenuDidAppear()

        #expect(
            !state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Opening a context menu must clear the row close affordance until tracking reports the pointer is still inside."
        )
    }

    @Test func contextMenuDismissalCanRevealAfterPointerReconciliation() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.contextMenuDidDisappear()
        state.setPointerHovering(true)

        #expect(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Closing the context menu may reveal the close affordance again only after pointer tracking reconciles inside the row."
        )
    }

    @Test func closeButtonHiddenWhenWorkspaceCannotBeClosed() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)

        #expect(!state.shouldShowCloseButton(
            canCloseWorkspace: false,
            shortcutHintModeActive: false
        ))
    }

    @Test func closeButtonHiddenDuringShortcutHintMode() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)

        #expect(!state.shouldShowCloseButton(
            canCloseWorkspace: true,
            shortcutHintModeActive: true
        ))
    }
}
