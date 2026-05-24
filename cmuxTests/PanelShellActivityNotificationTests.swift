import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression for https://github.com/manaflow-ai/cmux/issues/1900 — the welcome
/// banner was typed into the user's shell with a fixed 0.5s delay, which raced
/// shell-init prompts (oh-my-zsh auto-update) and dropped the first character,
/// producing `mux welcome` / `zsh: command not found: mux`.
///
/// The fix waits for the shell-integration `promptIdle` state before typing.
/// To make that wait possible, `Workspace.updatePanelShellActivityState` now
/// posts `.panelShellActivityStateDidChange` whenever the state actually
/// changes. This test pins that contract.
final class PanelShellActivityNotificationTests: XCTestCase {
    /// Asserts the new `panelShellActivityStateDidChange` notification fires on
    /// a real state transition and carries the expected `workspaceId`,
    /// `panelId`, and `state` in `userInfo`. This is the wire-up that
    /// `Workspace.sendTextOnNextPromptIdle` listens on.
    @MainActor
    func testStateChangePostsNotificationWithWorkspaceAndPanelIds() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        let expectation = expectation(description: "panelShellActivityStateDidChange posted")
        var observedWorkspaceId: UUID?
        var observedPanelId: UUID?
        var observedState: Workspace.PanelShellActivityState?

        let observer = NotificationCenter.default.addObserver(
            forName: .panelShellActivityStateDidChange,
            object: nil,
            queue: .main
        ) { note in
            observedWorkspaceId = note.userInfo?[PanelShellActivityNotificationKey.workspaceId] as? UUID
            observedPanelId = note.userInfo?[PanelShellActivityNotificationKey.panelId] as? UUID
            observedState = note.userInfo?[PanelShellActivityNotificationKey.state] as? Workspace.PanelShellActivityState
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(observedWorkspaceId, workspace.id)
        XCTAssertEqual(observedPanelId, panelId)
        XCTAssertEqual(observedState, .promptIdle)
    }

    /// Idempotency: setting the same state twice in a row must not re-post the
    /// notification. Otherwise the `sendTextOnNextPromptIdle` observer would
    /// re-fire on every redundant promptIdle report and double-type the
    /// welcome.
    @MainActor
    func testDuplicateStateDoesNotPostNotification() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        // Move to promptIdle so the second call below is a no-op state-wise.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .panelShellActivityStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // No state change — must not post.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        XCTAssertEqual(notificationCount, 0)

        // Real transition — must post exactly once.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        XCTAssertEqual(notificationCount, 1)
    }

    /// `sendTextOnNextPromptIdle` is the single owner of the "wait for a real
    /// shell prompt before typing" state machine. Before the shell reports
    /// `.promptIdle` nothing should fire — that's what kept the `c` of
    /// `cmux welcome` alive in the oh-my-zsh bug. The `beforeSend` hook (used
    /// in production to mark the welcome banner as shown) must fire exactly
    /// when the panel first transitions to `.promptIdle`, and exactly once
    /// even if the panel later bounces in and out of that state.
    ///
    /// The observer is registered with `queue: nil`, so notification delivery
    /// is synchronous on the posting thread. The test asserts immediately after
    /// each `updatePanelShellActivityState` call without runloop spins — if
    /// this ever turns flaky, the production code introduced an async hop on
    /// the wait path and that needs to be investigated, not papered over with
    /// a longer wait in the test.
    @MainActor
    func testSendTextOnNextPromptIdleFiresExactlyOnceAtFirstPromptIdle() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        var sendCount = 0
        workspace.sendTextOnNextPromptIdle("cmux welcome\n") {
            sendCount += 1
        }
        XCTAssertEqual(sendCount, 0, "must not fire before any state report")

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        XCTAssertEqual(sendCount, 0, "commandRunning is not a prompt — must not fire")

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        XCTAssertEqual(sendCount, 1, "first promptIdle must fire the send")

        // Subsequent prompt bounces must not re-fire — the helper is one-shot.
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        XCTAssertEqual(sendCount, 1, "send must be one-shot")
    }

    /// Workspaces that are deallocated before `.promptIdle` ever fires (no
    /// shell integration installed, user closed the workspace, etc.) must not
    /// leak their NotificationCenter observer. Greptile flagged this on the
    /// first refactor: the observer block was kept alive by NotificationCenter
    /// and captured the workspace strongly, so the workspace was retained
    /// indefinitely. The deinit sweep in Workspace now removes the token, and
    /// the closure captures `self` weakly as a secondary safety net.
    @MainActor
    func testSendTextOnNextPromptIdleDoesNotLeakWorkspaceWhenPromptIdleNeverFires() throws {
        weak var weakWorkspace: Workspace?
        autoreleasepool {
            let workspace = Workspace()
            weakWorkspace = workspace
            workspace.sendTextOnNextPromptIdle("cmux welcome\n")
            // Workspace is dropped at the end of this autoreleasepool. The
            // pending observer must be cleaned up by Workspace.deinit; we
            // verify by reading `weakWorkspace` after the pool drains.
        }
        XCTAssertNil(weakWorkspace, "workspace must not be retained by the pending observer")
    }
}
