import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A mirrored session's panes freeze while its connection reconnects. A short drop
/// should pass unannounced; a long one should say so on the sidebar row.
@MainActor
@Suite struct RemoteTmuxReconnectingIndicatorTests {
    private let key = Workspace.remoteTmuxReconnectingStatusKey

    @Test func aReconnectThatRecoversBeforeTheDelayShowsNothing() async throws {
        let workspace = Workspace()
        let indicator = RemoteTmuxReconnectingIndicator(delay: .seconds(60))

        indicator.connectionStateChanged(.reconnecting, reconnectingSince: nil, workspace: workspace)
        let presentation = try #require(indicator.pendingPresentation)
        #expect(workspace.statusEntries[key] == nil)

        indicator.connectionStateChanged(.connected, reconnectingSince: nil, workspace: workspace)
        await presentation.value

        #expect(indicator.pendingPresentation == nil)
        #expect(workspace.statusEntries[key] == nil)
    }

    @Test func aLongReconnectShowsReconnectingUntilTheConnectionIsBack() async throws {
        let workspace = Workspace()
        let indicator = RemoteTmuxReconnectingIndicator(delay: .milliseconds(10))

        indicator.connectionStateChanged(.reconnecting, reconnectingSince: nil, workspace: workspace)
        await indicator.pendingPresentation?.value

        let entry = try #require(workspace.statusEntries[key])
        #expect(!entry.value.isEmpty)
        #expect(entry.icon == "arrow.triangle.2.circlepath")
        #expect(!workspace.sessionSnapshot(includeScrollback: false).statusEntries.contains { $0.key == key })

        // Each failed attempt reports reconnecting again; the row keeps its one entry.
        indicator.connectionStateChanged(.reconnecting, reconnectingSince: nil, workspace: workspace)
        #expect(indicator.pendingPresentation == nil)
        #expect(workspace.statusEntries[key] == entry)

        indicator.connectionStateChanged(.connected, reconnectingSince: nil, workspace: workspace)
        #expect(workspace.statusEntries[key] == nil)
    }

    @Test func aSessionThatEndsWhileReconnectingDropsTheEntry() async throws {
        let workspace = Workspace()
        let indicator = RemoteTmuxReconnectingIndicator(delay: .milliseconds(10))

        indicator.connectionStateChanged(.reconnecting, reconnectingSince: nil, workspace: workspace)
        await indicator.pendingPresentation?.value
        #expect(workspace.statusEntries[key] != nil)

        indicator.connectionStateChanged(.ended, reconnectingSince: nil, workspace: workspace)
        #expect(workspace.statusEntries[key] == nil)
    }

    /// The delay counts from when the connection began reconnecting, not from when the indicator
    /// heard about it, so a reconnect already past the delay shows at once.
    @Test func aReconnectAlreadyPastTheDelayShowsAtOnce() async throws {
        let workspace = Workspace()
        let indicator = RemoteTmuxReconnectingIndicator(delay: .seconds(60))

        indicator.connectionStateChanged(
            .reconnecting, reconnectingSince: .now - .seconds(61), workspace: workspace
        )
        await indicator.pendingPresentation?.value

        #expect(workspace.statusEntries[key] != nil)
    }

    /// A mirror can attach to a source that is already reconnecting, such as a session opened
    /// while a shared stream is down. No state change arrives until the drop ends, so the mirror
    /// has to start the indicator from the state it finds.
    @Test func aMirrorAttachedDuringAReconnectStartsTheIndicator() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "reconnecting-attach.test"), sessionName: "work"
        )
        connection.beginReconnecting()
        defer { connection.stop() }
        try #require(connection.connectionState == .reconnecting)
        #expect(connection.reconnectingSince != nil)

        let mirror = RemoteTmuxSessionMirror(
            host: connection.host, sessionName: "work", connection: connection,
            tabManager: manager, workspace: workspace
        )
        defer {
            mirror.detachObserver()
            workspace.teardownAllPanels()
        }

        #expect(mirror.reconnectingIndicator.pendingPresentation != nil)
    }

    /// A sidebar reset or a `clear_status` can remove the row while it shows "Reconnecting". The
    /// connection is still reconnecting and reports no new state, so the row has to be derived
    /// again from the connection rather than stay gone for the rest of the drop.
    @Test func removingTheRowDuringAReconnectDerivesItAgain() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "reconnecting-reset.test"), sessionName: "work"
        )
        connection.beginReconnecting()
        defer { connection.stop() }
        let mirror = RemoteTmuxSessionMirror(
            host: connection.host, sessionName: "work", connection: connection,
            tabManager: manager, workspace: workspace
        )
        defer {
            mirror.detachObserver()
            workspace.teardownAllPanels()
        }
        // What a reset leaves behind once the row has shown: no entry and nothing scheduled.
        mirror.reconnectingIndicator.clear(workspace: workspace)

        workspace.resetSidebarContext(reason: "test")
        #expect(mirror.reconnectingIndicator.pendingPresentation != nil)

        // Clearing the key through the status API is the other way to remove the row.
        mirror.reconnectingIndicator.clear(workspace: workspace)
        workspace.clearStatusEntry(key: key, panelId: nil)
        #expect(mirror.reconnectingIndicator.pendingPresentation != nil)
    }
}
