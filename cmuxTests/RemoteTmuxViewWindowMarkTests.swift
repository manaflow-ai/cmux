import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Which windows found in the view at bringup are cmux's to clean up.
///
/// A window cmux linked into the view whose home session is later killed stays alive, linked
/// into the view alone, and must be destroyed. A window created next to a mirrored window by a
/// command that named it only by id also sits in the view alone, but cmux never linked it, and
/// it belongs in a real session instead. After a reconnect tmux shows both the same way, so
/// cmux marks every window it links and reads the mark back.
@Suite struct RemoteTmuxViewWindowMarkTests {
    private let view = "cmux-view-v1-OWNER-abc"

    @Test func aMarkedWindowLeftInTheViewAloneIsCmuxsToDestroy() {
        // @9 was linked by cmux; its home session was killed.
        let read = RemoteTmuxViewConnection.readMarkedBringupRows(
            ["@1 0 ", "@5 1 1", "@9 0 1"])
        #expect(read.placeholder == "@1")
        #expect(read.adopted == ["@5", "@9"])
    }

    @Test func anUnmarkedWindowInTheViewAloneIsNotCmuxs() {
        // @12 was created next to a mirrored window and never linked by cmux.
        let read = RemoteTmuxViewConnection.readMarkedBringupRows(
            ["@1 0 ", "@5 1 1", "@12 0 "])
        #expect(read.placeholder == "@1")
        #expect(read.adopted == ["@5"])
    }

    @Test func aMarkedOrphanBeforeThePlaceholderIsNotTakenForIt() {
        let read = RemoteTmuxViewConnection.readMarkedBringupRows(
            ["@9 0 1", "@1 0 ", "@5 1 1"])
        #expect(read.placeholder == "@1")
        #expect(read.adopted == ["@5", "@9"])
    }

    @Test func aLinkedWindowIsCmuxsEvenWithoutAMark() {
        // Linked before marking existed: it is in a real session, so unlinking the view's copy
        // cannot destroy it.
        let read = RemoteTmuxViewConnection.readMarkedBringupRows(
            ["@1 0 ", "@5 1 ", "@6 1 1"])
        #expect(read.adopted == ["@5", "@6"])
    }

    @Test func aViewWithNoMarksAtAllKeepsTheOldRule() {
        // A view left by a cmux that did not mark windows: everything but the placeholder is
        // treated as cmux's, as before.
        let read = RemoteTmuxViewConnection.readMarkedBringupRows(
            ["@1 0 ", "@5 1 ", "@9 0 "])
        #expect(read.placeholder == "@1")
        #expect(read.adopted == ["@5", "@9"])
    }

    @Test func theLinkCommandMarksTheWindowForThisView() {
        #expect(RemoteTmuxViewConnection.linkCommands(windowId: "@12", viewSessionName: view) == [
            "link-window -s @12 -t '\(view)'",
            "set-option -w -t @12 '@cmux_link_\(view)' 1",
        ])
    }

    @Test func theReconcileDestroysAMarkedOrphanAndLeavesAnUnmarkedOne() {
        let read = RemoteTmuxViewConnection.readMarkedBringupRows(
            ["@1 0 ", "@5 1 1", "@9 0 1", "@12 0 "])
        let actions = RemoteTmuxViewReconciler.actions(
            desiredWindowIds: ["@5"],
            actualWindowIds: ["@1", "@5", "@9", "@12"],
            placeholderWindowId: read.placeholder,
            cmuxOwnedWindowIds: read.adopted)
        #expect(actions == [.unlinkFromView(windowId: "@9")])
    }
}
