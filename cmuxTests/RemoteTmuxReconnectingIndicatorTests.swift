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

        indicator.connectionStateChanged(.reconnecting, workspace: workspace)
        let presentation = try #require(indicator.pendingPresentation)
        #expect(workspace.statusEntries[key] == nil)

        indicator.connectionStateChanged(.connected, workspace: workspace)
        await presentation.value

        #expect(indicator.pendingPresentation == nil)
        #expect(workspace.statusEntries[key] == nil)
    }

    @Test func aLongReconnectShowsReconnectingUntilTheConnectionIsBack() async throws {
        let workspace = Workspace()
        let indicator = RemoteTmuxReconnectingIndicator(delay: .milliseconds(10))

        indicator.connectionStateChanged(.reconnecting, workspace: workspace)
        await indicator.pendingPresentation?.value

        let entry = try #require(workspace.statusEntries[key])
        #expect(!entry.value.isEmpty)
        #expect(entry.icon == "arrow.triangle.2.circlepath")
        #expect(!workspace.sessionSnapshot(includeScrollback: false).statusEntries.contains { $0.key == key })

        // Each failed attempt reports reconnecting again; the row keeps its one entry.
        indicator.connectionStateChanged(.reconnecting, workspace: workspace)
        #expect(indicator.pendingPresentation == nil)
        #expect(workspace.statusEntries[key] == entry)

        indicator.connectionStateChanged(.connected, workspace: workspace)
        #expect(workspace.statusEntries[key] == nil)
    }

    @Test func aSessionThatEndsWhileReconnectingDropsTheEntry() async throws {
        let workspace = Workspace()
        let indicator = RemoteTmuxReconnectingIndicator(delay: .milliseconds(10))

        indicator.connectionStateChanged(.reconnecting, workspace: workspace)
        await indicator.pendingPresentation?.value
        #expect(workspace.statusEntries[key] != nil)

        indicator.connectionStateChanged(.ended, workspace: workspace)
        #expect(workspace.statusEntries[key] == nil)
    }
}
