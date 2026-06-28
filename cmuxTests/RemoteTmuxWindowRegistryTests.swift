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

    // MARK: - Multi-host bindings ("multiple servers in one window")

    private func host(_ destination: String) -> RemoteTmuxHost { RemoteTmuxHost(destination: destination) }

    /// A window can hold several hosts (linked-view aggregation); each host still
    /// maps to that one window, and `hosts(forWindowId:)` returns them in attach order.
    @Test func aggregatesMultipleHostsInOneWindow() {
        let registry = RemoteTmuxWindowRegistry()
        let windowId = UUID()
        let a = host("user@a"), b = host("user@b")
        registry.bind(host: a, windowId: windowId)
        registry.bind(host: b, windowId: windowId)
        #expect(registry.windowId(forHostHash: a.connectionHash) == windowId)
        #expect(registry.windowId(forHostHash: b.connectionHash) == windowId)
        #expect(registry.hosts(forWindowId: windowId).map(\.connectionHash) == [a.connectionHash, b.connectionHash])
        #expect(registry.host(forWindowId: windowId)?.connectionHash == a.connectionHash)  // first
        #expect(registry.isDedicatedWindow(windowId))
    }

    /// Re-binding the same host to a window is idempotent (no duplicate entry).
    @Test func rebindingSameHostIsIdempotent() {
        let registry = RemoteTmuxWindowRegistry()
        let windowId = UUID()
        let a = host("user@a")
        registry.bind(host: a, windowId: windowId)
        registry.bind(host: a, windowId: windowId)
        #expect(registry.hosts(forWindowId: windowId).count == 1)
    }

    /// Unbinding one host leaves the other aggregated hosts (and the window) bound.
    @Test func unbindHostHashRemovesOnlyThatHost() {
        let registry = RemoteTmuxWindowRegistry()
        let windowId = UUID()
        let a = host("user@a"), b = host("user@b")
        registry.bind(host: a, windowId: windowId)
        registry.bind(host: b, windowId: windowId)
        registry.unbind(hostHash: a.connectionHash)
        #expect(registry.windowId(forHostHash: a.connectionHash) == nil)
        #expect(registry.windowId(forHostHash: b.connectionHash) == windowId)
        #expect(registry.hosts(forWindowId: windowId).map(\.connectionHash) == [b.connectionHash])
        #expect(registry.isDedicatedWindow(windowId))
    }

    /// Unbinding the last host drops the window entry entirely.
    @Test func unbindingLastHostClearsWindow() {
        let registry = RemoteTmuxWindowRegistry()
        let windowId = UUID()
        let a = host("user@a")
        registry.bind(host: a, windowId: windowId)
        registry.unbind(hostHash: a.connectionHash)
        #expect(registry.hosts(forWindowId: windowId).isEmpty)
        #expect(!registry.isDedicatedWindow(windowId))
    }

    /// Re-binding a host to a different window moves it (no stale entry left in the
    /// old window), keeping the two maps consistent.
    @Test func rebindingHostToAnotherWindowMovesIt() {
        let registry = RemoteTmuxWindowRegistry()
        let w1 = UUID(), w2 = UUID()
        let a = host("user@a")
        registry.bind(host: a, windowId: w1)
        registry.bind(host: a, windowId: w2)
        #expect(registry.windowId(forHostHash: a.connectionHash) == w2)
        #expect(registry.hosts(forWindowId: w1).isEmpty)
        #expect(!registry.isDedicatedWindow(w1))
        #expect(registry.hosts(forWindowId: w2).map(\.connectionHash) == [a.connectionHash])
    }

    /// Unbinding by window id removes ALL of the window's hosts in both directions.
    @Test func unbindWindowRemovesAllHosts() {
        let registry = RemoteTmuxWindowRegistry()
        let windowId = UUID()
        let a = host("user@a"), b = host("user@b")
        registry.bind(host: a, windowId: windowId)
        registry.bind(host: b, windowId: windowId)
        registry.unbind(windowId: windowId)
        #expect(registry.windowId(forHostHash: a.connectionHash) == nil)
        #expect(registry.windowId(forHostHash: b.connectionHash) == nil)
        #expect(registry.hosts(forWindowId: windowId).isEmpty)
    }
}
