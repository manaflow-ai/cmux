import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the pure linked-view reconciler (`remoteTmux.linkedView` beta). These
/// assert the link/unlink policy and its safety invariants — never touch the
/// placeholder, never touch windows cmux does not own — with no tmux/SSH.
@Suite struct RemoteTmuxViewReconcilerTests {
    private typealias R = RemoteTmuxViewReconciler
    private typealias A = RemoteTmuxViewReconciler.Action

    @Test func linksAllDesiredIntoEmptyView() {
        let actions = R.actions(
            desiredWindowIds: ["@1", "@2", "@3"],
            actualWindowIds: ["@0"],          // only the placeholder present
            placeholderWindowId: "@0",
            cmuxOwnedWindowIds: []
        )
        #expect(actions == [.link(windowId: "@1"), .link(windowId: "@2"), .link(windowId: "@3")])
    }

    @Test func noActionsWhenAlreadyReconciled() {
        let actions = R.actions(
            desiredWindowIds: ["@1", "@2"],
            actualWindowIds: ["@0", "@1", "@2"],
            placeholderWindowId: "@0",
            cmuxOwnedWindowIds: ["@1", "@2"]
        )
        #expect(actions.isEmpty)
    }

    @Test func unlinksCmuxOwnedWindowThatIsNoLongerDesired() {
        // @2's session was closed → @2 leaves `desired`; cmux owns it → unlink it.
        let actions = R.actions(
            desiredWindowIds: ["@1"],
            actualWindowIds: ["@0", "@1", "@2"],
            placeholderWindowId: "@0",
            cmuxOwnedWindowIds: ["@1", "@2"]
        )
        #expect(actions == [.unlinkFromView(windowId: "@2")])
    }

    @Test func neverUnlinksThePlaceholder() {
        // Placeholder is present, not desired, but must never be unlinked
        // (it's the view's last-resort window; unlinking it kills the session).
        let actions = R.actions(
            desiredWindowIds: ["@1"],
            actualWindowIds: ["@0", "@1"],
            placeholderWindowId: "@0",
            cmuxOwnedWindowIds: ["@0", "@1"]   // even if mislabeled owned
        )
        #expect(actions.isEmpty)
    }

    @Test func neverTouchesWindowsCmuxDoesNotOwn() {
        // @9 is in the view but cmux didn't link it (e.g. user put it there).
        // It is not desired, but cmux must leave it alone.
        let actions = R.actions(
            desiredWindowIds: ["@1"],
            actualWindowIds: ["@0", "@1", "@9"],
            placeholderWindowId: "@0",
            cmuxOwnedWindowIds: ["@1"]
        )
        #expect(actions.isEmpty)
    }

    @Test func mixedLinkAndUnlinkAreBothEmittedDeterministically() {
        // Desired adds @3, @4; @2 is owned + no longer desired → unlink.
        let actions = R.actions(
            desiredWindowIds: ["@1", "@3", "@4"],
            actualWindowIds: ["@0", "@1", "@2"],
            placeholderWindowId: "@0",
            cmuxOwnedWindowIds: ["@1", "@2"]
        )
        // Links first (sorted), then unlinks (sorted) — stable order.
        #expect(actions == [
            .link(windowId: "@3"),
            .link(windowId: "@4"),
            .unlinkFromView(windowId: "@2"),
        ])
    }

    @Test func handlesMissingPlaceholder() {
        // After cmux closes the placeholder, an owned undesired window still unlinks.
        let actions = R.actions(
            desiredWindowIds: [],
            actualWindowIds: ["@2"],
            placeholderWindowId: nil,
            cmuxOwnedWindowIds: ["@2"]
        )
        #expect(actions == [.unlinkFromView(windowId: "@2")])
    }

    @Test func reconcileIsIdempotentAcrossRepeatedRuns() {
        // Applying the actions then reconciling again yields no further actions.
        let desired: Set<String> = ["@1", "@2"]
        var actual: Set<String> = ["@0"]
        let owned = desired
        let first = R.actions(desiredWindowIds: desired, actualWindowIds: actual,
                              placeholderWindowId: "@0", cmuxOwnedWindowIds: owned)
        for case let .link(id) in first { actual.insert(id) }
        let second = R.actions(desiredWindowIds: desired, actualWindowIds: actual,
                               placeholderWindowId: "@0", cmuxOwnedWindowIds: owned)
        #expect(second.isEmpty)
    }

    @Test func viewHasNoMirroredWindowsDetectsEmptyMirror() {
        #expect(R.viewHasNoMirroredWindows(actualWindowIds: ["@0"], placeholderWindowId: "@0"))
        #expect(R.viewHasNoMirroredWindows(actualWindowIds: [], placeholderWindowId: nil))
        #expect(!R.viewHasNoMirroredWindows(actualWindowIds: ["@0", "@1"], placeholderWindowId: "@0"))
    }
}
