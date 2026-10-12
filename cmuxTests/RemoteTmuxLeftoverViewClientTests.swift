import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A reconnect kills the local transport. Over a transport whose remote half outlives
/// its client, the old `tmux -CC` client stays attached to the view, one more per
/// reconnect (74 on one host, most of them days old). The new stream detaches them.
@Suite struct RemoteTmuxLeftoverViewClientTests {
    private let view = "cmux-view-v1-OWNER-abc"

    @Test func detachesOtherControlClientsOnTheView() {
        let rows = [
            "/dev/pts/3 1 \(view)",
            "/dev/pts/9 1 \(view)",
            "/dev/pts/12 1 \(view)",
        ]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/12") == ["/dev/pts/3", "/dev/pts/9"])
    }

    @Test func leavesClientsOnOtherSessionsAlone() {
        let rows = [
            "/dev/pts/1 0 main",
            "/dev/pts/2 1 main",
            "/dev/pts/4 1 cmux-view-v1-OTHER-def",
            "/dev/pts/5 1 \(view)",
        ]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/5").isEmpty)
    }

    @Test func leavesAPersonAttachedToTheViewAlone() {
        // A terminal someone attached to the view by hand is not a control client.
        let rows = ["/dev/pts/6 0 \(view)", "/dev/pts/7 1 \(view)"]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/7").isEmpty)
    }

    @Test func detachesNothingWithoutItsOwnName() {
        // Without its own name the stream cannot tell itself from a leftover.
        let rows = ["/dev/pts/3 1 \(view)", "/dev/pts/9 1 \(view)"]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "").isEmpty)
    }

    @Test func ignoresMalformedRows() {
        let rows = ["", "/dev/pts/3", "/dev/pts/4 1", "/dev/pts/5 1 \(view)"]
        #expect(RemoteTmuxViewConnection.leftoverViewClients(
            rows: rows, viewSessionName: view, ownClientName: "/dev/pts/9") == ["/dev/pts/5"])
    }
}
