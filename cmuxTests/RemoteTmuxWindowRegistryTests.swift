import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for ``RemoteTmuxWindowRegistry``'s kill-on-close marker — the
/// seam that decides whether closing a remote-tmux window's last tab kills the
/// remote session (an explicit tab/session close) or merely detaches it (a plain
/// app-window/quit close). These exercise the mark → consume → clear state machine
/// directly, with no AppKit window involved.
@MainActor
@Suite struct RemoteTmuxWindowRegistryTests {
    /// A marked window is consumed exactly once: the commit handler sees `true`, and
    /// any later consume (e.g. a redundant call) sees `false`, so it can't kill twice.
    @Test func markedWindowIsConsumedExactlyOnce() {
        let registry = RemoteTmuxWindowRegistry()
        let windowId = UUID()
        registry.markKillSessionsOnClose(windowId: windowId)
        #expect(registry.consumeKillSessionsOnClose(windowId: windowId) == true)
        #expect(registry.consumeKillSessionsOnClose(windowId: windowId) == false)
    }

    /// An unmarked window (a plain window/quit close) consumes to `false`, so the
    /// close-commit handler detaches instead of killing the remote session.
    @Test func unmarkedWindowConsumesToFalse() {
        let registry = RemoteTmuxWindowRegistry()
        #expect(registry.consumeKillSessionsOnClose(windowId: UUID()) == false)
    }

    /// The marker is scoped per window id: marking one window does not make another
    /// window's close kill, and the marked window still consumes to `true`.
    @Test func markerIsScopedPerWindow() {
        let registry = RemoteTmuxWindowRegistry()
        let marked = UUID()
        let other = UUID()
        registry.markKillSessionsOnClose(windowId: marked)
        #expect(registry.consumeKillSessionsOnClose(windowId: other) == false)
        #expect(registry.consumeKillSessionsOnClose(windowId: marked) == true)
    }

    /// Consuming a marked window on a close veto clears it, so a later (real)
    /// window/quit close of the same window detaches rather than killing.
    @Test func consumingOnVetoClearsTheMarker() {
        let registry = RemoteTmuxWindowRegistry()
        let windowId = UUID()
        registry.markKillSessionsOnClose(windowId: windowId)
        // Veto path: consume to clear (result ignored in production).
        _ = registry.consumeKillSessionsOnClose(windowId: windowId)
        // A subsequent close commit must not kill.
        #expect(registry.consumeKillSessionsOnClose(windowId: windowId) == false)
    }
}
