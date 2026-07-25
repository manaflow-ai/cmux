import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A multiplexed session channel is one session's filtered view of the host's
/// shared control stream. Most events carry a pane or window id and are fanned
/// out only to the session that owns them. Reconnect readiness carries neither:
/// it fires once per shared stream after reconnect attach drainage, and every
/// session's mirror listens for it to schedule its post-reconnect force-resize.
/// A channel that drops it leaves every mirror on the host at its pre-reconnect
/// size until some unrelated event repaints it.
@MainActor
@Suite struct RemoteTmuxSessionChannelTests {
    @Test func channelFansReconnectReadyToItsObservers() {
        let source = ReconnectFanOutFakeSource()
        let channel = RemoteTmuxSessionChannel(
            underlying: source, sessionName: "alpha", sessionId: 1, windowIds: [10]
        )

        var readyCount = 0
        _ = channel.addObserver(RemoteTmuxSessionObservers(onReconnectReady: { readyCount += 1 }))

        source.fireReconnectReady()
        #expect(
            readyCount == 1,
            "the shared stream's reconnect-ready must reach the channel's observers"
        )

        channel.detach()
        source.fireReconnectReady()
        #expect(readyCount == 1, "a detached channel forwards nothing")
    }
}

/// Inert `RemoteTmuxSessionSource` that only records observers, so a test can
/// fire shared-stream events and watch what the channel forwards.
@MainActor
private final class ReconnectFanOutFakeSource: RemoteTmuxSessionSource {
    var connectionState: RemoteTmuxConnectionState = .connected
    var exited = false
    var sessionId: Int? = 1
    var windowsByID: [Int: RemoteTmuxWindow] = [:]
    var windowOrder: [Int] = []
    var activePaneByWindow: [Int: Int] = [:]
    var paneForegroundStates: [Int: RemoteTmuxPaneForegroundState] = [:]
    var paneIDsRetainedUntilWindowList: Set<Int> = []
    var pendingLayouts: [Int: RemoteTmuxPendingLayout] = [:]
    var publishedWindowIdByPane: [Int: Int] = [:]
    var paneHeaderLabels: [Int: String] = [:]
    var windowTitleRowPlacements: [Int: RemoteTmuxPaneTitleRowPlacement] = [:]
    var lastWindowSizes: [Int: (Int, Int)] = [:]
    func hasPendingLayout(windowId: Int) -> Bool { false }

    private var observers: [UUID: RemoteTmuxSessionObservers] = [:]
    func addObserver(_ observers: RemoteTmuxSessionObservers) -> UUID {
        let token = UUID()
        self.observers[token] = observers
        return token
    }
    func removeObserver(_ token: UUID) { observers[token] = nil }
    func fireReconnectReady() {
        for o in Array(observers.values) { o.onReconnectReady?() }
    }

    func releaseMirror() {}
    func endSession(kill: Bool) {}
    @discardableResult func send(_ command: String) -> Bool { true }
    @discardableResult func sendTracked(_ command: String, completion: @escaping (Bool) -> Void) -> Bool {
        completion(true)
        return true
    }
    @discardableResult func repaintPaneVisibleScreen(paneId: Int) -> UUID? { nil }
    func retainWindowSizeClaims(for liveWindowIDs: Set<Int>) {}
    func removeWindowSizeClaim(windowId: Int) {}
    @discardableResult func sendNewWindow(_ command: String, completion: @escaping (Int?) -> Void) -> Bool {
        completion(nil)
        return true
    }
    @discardableResult func sendWindowReorder(_ commands: [String], verification: ((Bool) -> Void)?) -> Bool {
        verification?(true)
        return true
    }
    @discardableResult func sendKeys(paneId: Int, data: Data) -> Bool { true }
    @discardableResult func seedPane(paneId: Int, clearScrollback: Bool) -> UUID? { nil }
    func unsubscribePanePath(paneId: Int) {}
    func unsubscribePaneReflow(paneId: Int) {}
    func unsubscribePaneHeader(paneId: Int) {}
    func setWindowSize(windowId: Int, columns: Int, rows: Int) {}
    func setSessionName(_ name: String) {}
    func applyWindowReorder(_ reordered: [Int]) {}
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) {
        completion(nil)
    }
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: RemoteTmuxPaneForegroundState]?) -> Void) {
        completion(nil)
    }
    @discardableResult func pastePane(paneId: Int, text: String) -> Bool { true }
    func record(_ event: String) {}
}
