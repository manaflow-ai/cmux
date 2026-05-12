import AppKit
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceSnapshotRefreshPolicyTests: XCTestCase {
    func testContextMenuPinChangeUpdatesDisplayedFieldsAndDefersNoisyFields() {
        let current = Self.snapshot(
            title: "lmao",
            isPinned: false,
            customColorHex: nil,
            remoteConnectionStatusText: "Connected",
            latestSubmittedMessage: "old message",
            listeningPorts: [3000]
        )
        let next = Self.snapshot(
            title: "lmao",
            isPinned: true,
            customColorHex: nil,
            remoteConnectionStatusText: "Disconnected",
            latestSubmittedMessage: "new message",
            listeningPorts: [3000, 4000]
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        var expectedDisplayed = current
        expectedDisplayed = expectedDisplayed.applyingContextMenuImmediateFields(from: next)
        XCTAssertEqual(decision.workspaceSnapshotStorage, expectedDisplayed)
        XCTAssertTrue(decision.workspaceSnapshotStorage?.isPinned == true)
        XCTAssertEqual(decision.workspaceSnapshotStorage?.remoteConnectionStatusText, "Connected")
        XCTAssertEqual(decision.workspaceSnapshotStorage?.latestSubmittedMessage, "old message")
        XCTAssertEqual(decision.workspaceSnapshotStorage?.listeningPorts, [3000])
        XCTAssertEqual(decision.pendingWorkspaceSnapshot, next)
        XCTAssertTrue(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    func testContextMenuImmediateOnlyChangeDoesNotCreateDeferredFlush() {
        let current = Self.snapshot(
            title: "old",
            customDescription: nil,
            isPinned: false,
            customColorHex: nil
        )
        let next = Self.snapshot(
            title: "new",
            customDescription: "description",
            isPinned: true,
            customColorHex: "#C0392B"
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        XCTAssertEqual(decision.workspaceSnapshotStorage, next)
        XCTAssertNil(decision.pendingWorkspaceSnapshot)
        XCTAssertFalse(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    func testClosedContextMenuStoresNextAndClearsPending() {
        let current = Self.snapshot(title: "old", isPinned: false)
        let next = Self.snapshot(title: "new", isPinned: true)

        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: false
        )

        XCTAssertEqual(decision.workspaceSnapshotStorage, next)
        XCTAssertNil(decision.pendingWorkspaceSnapshot)
        XCTAssertFalse(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    private static func snapshot(
        title: String = "workspace",
        customDescription: String? = nil,
        isPinned: Bool = false,
        customColorHex: String? = nil,
        remoteConnectionStatusText: String = "Disconnected",
        latestSubmittedMessage: String? = nil,
        listeningPorts: [Int] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: customColorHex,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: "",
            copyableSidebarSSHError: nil,
            latestSubmittedMessage: latestSubmittedMessage,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            compactGitBranchSummaryText: nil,
            compactBranchDirectoryRow: nil,
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: listeningPorts
        )
    }
}

final class SidebarWorkspaceRowInteractionStateTests: XCTestCase {
    func testHoverRevealIsIndependentFromStaleContextMenuVisibility() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.contextMenuTrackingDidEnd()
        state.setPointerHovering(true)

        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A stale SwiftUI context-menu lifecycle flag must not permanently suppress hover-only close affordances after AppKit menu tracking has ended."
        )

        state.setPointerHovering(false)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "The stale SwiftUI menu flag must not make the close affordance visible when the pointer is no longer hovering."
        )
    }

    func testContextMenuTrackingBeginHidesExistingCloseButtonBeforeSwiftUIMenuAppears() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            )
        )

        state.contextMenuTrackingDidBegin()

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Right-click menu tracking must hide an already-visible close affordance even before SwiftUI reports the context menu appearance."
        )
    }

    func testHoverDuringContextMenuTrackingStaysHiddenUntilTrackingEnds() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.setPointerHovering(true)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Pointer hover updates observed during context-menu tracking must not reveal the close affordance under the menu."
        )

        state.contextMenuTrackingDidEnd()

        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Once AppKit menu tracking ends, the last reconciled pointer position may reveal the close affordance even if SwiftUI menu state is stale."
        )
    }

    func testCoordinatorPreservesHoverExitWhileMenuTrackingSuppressesCloseButton() {
        var state = SidebarWorkspaceRowInteractionState()
        let binding = Binding<SidebarWorkspaceRowInteractionState>(
            get: { state },
            set: { state = $0 }
        )
        let coordinator = SidebarWorkspaceRowHoverTracker.Coordinator(
            rowInteractionState: binding
        )

        coordinator.menuTrackingChanged(true)
        coordinator.pointerHoverChanged(true)
        coordinator.pointerHoverChanged(false)
        coordinator.menuTrackingChanged(false)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A pointer exit observed during menu tracking must overwrite any earlier deferred hover enter before the menu dismisses."
        )
    }

    func testMenuTrackingSuppressionOnlyAppliesToPointerMenusInsideRow() {
        XCTAssertTrue(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: true,
                eventType: .rightMouseDown,
                modifierFlags: []
            )
        )
        XCTAssertTrue(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: true,
                eventType: .leftMouseDown,
                modifierFlags: .control
            )
        )
        XCTAssertFalse(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: false,
                eventType: .rightMouseDown,
                modifierFlags: []
            ),
            "A menu opened outside this row must not suppress this row's hover state."
        )
        XCTAssertFalse(
            SidebarWorkspaceRowMenuTrackingScope.shouldSuppressCloseButton(
                pointerInsideRow: true,
                eventType: .keyDown,
                modifierFlags: []
            ),
            "Keyboard-driven or app-level menu tracking must not be treated like this row's pointer context menu."
        )
    }

    func testPointerExitWhileContextMenuIsVisibleStaysHiddenAfterDismissal() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.setPointerHovering(false)
        state.contextMenuDidDisappear()

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Pointer exit remains authoritative even when it is observed during the context-menu lifecycle."
        )
    }

    func testNoHoverDoesNotRevealCloseButtonWhileContextMenuIsVisible() {
        var state = SidebarWorkspaceRowInteractionState()

        state.contextMenuDidAppear()
        state.setPointerHovering(false)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "A visible context menu must not make the close affordance visible when the pointer is not hovering."
        )
    }

    func testContextMenuAppearanceHidesExistingCloseButtonUntilPointerIsReconciled() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            )
        )

        state.contextMenuDidAppear()

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Opening a context menu must clear the row close affordance until tracking reports the pointer is still inside."
        )
    }

    func testContextMenuDismissalCanRevealAfterPointerReconciliation() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)
        state.contextMenuDidAppear()
        state.contextMenuDidDisappear()
        state.setPointerHovering(true)

        XCTAssertTrue(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: false
            ),
            "Closing the context menu may reveal the close affordance again only after pointer tracking reconciles inside the row."
        )
    }

    func testCloseButtonHiddenWhenWorkspaceCannotBeClosed() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: false,
                shortcutHintModeActive: false
            )
        )
    }

    func testCloseButtonHiddenDuringShortcutHintMode() {
        var state = SidebarWorkspaceRowInteractionState()

        state.setPointerHovering(true)

        XCTAssertFalse(
            state.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: true
            )
        )
    }
}
