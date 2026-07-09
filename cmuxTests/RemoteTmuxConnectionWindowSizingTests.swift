import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxConnectionWindowSizingTests {
    private func makeConnection() -> RemoteTmuxControlConnection {
        RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
    }

    @Test func windowSizesAreTrackedPerWindow() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35)
        connection.setWindowSize(windowId: 7, columns: 60, rows: 20)
        #expect(connection.lastWindowSizes[0]?.0 == 98)
        #expect(connection.lastWindowSizes[7]?.0 == 60)
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35) // dedup no-op
        #expect(connection.lastWindowSizes[0]?.0 == 98)
    }

    @Test func perWindowRejectionFallsBackToSessionWide() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 98, rows: 35)
        connection.notePerWindowSizeRejected()
        #expect(connection.supportsPerWindowSize == false)
        // Requests keep flowing through the session-wide path (recorded for
        // the reconnect reseed even while not connected).
        connection.setWindowSize(windowId: 3, columns: 80, rows: 24)
        #expect(connection.lastRequestedClientSize?.columns == 80)
    }

    @Test func degenerateSizesAreIgnored() {
        let connection = makeConnection()
        connection.setWindowSize(windowId: 0, columns: 0, rows: 35)
        connection.setWindowSize(windowId: 0, columns: 98, rows: -1)
        #expect(connection.lastWindowSizes[0] == nil)
    }
}
