import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests view-session identity/ownership for the linked-view beta: naming,
/// option stamping, row parsing, and the classification predicates that keep cmux
/// from ever reusing/garbage-collecting a session it does not own.
@Suite struct RemoteTmuxViewSessionTests {
    private func v(_ owner: String = "owner-ABC") -> RemoteTmuxViewSession {
        RemoteTmuxViewSession(ownerId: owner)
    }

    @Test func sessionNameIsPrefixedAndSanitized() {
        let s = RemoteTmuxViewSession(ownerId: "ab.cd ef:gh")
        #expect(s.sessionName == "cmux-view-ab-cd-ef-gh")  // . : space → -
        #expect(s.sessionName.hasPrefix(RemoteTmuxViewSession.namePrefix))
    }

    @Test func createCommandsUseExplicitSizeAndStampOwnership() {
        let cmds = v("o1").createCommands(cols: 120, rows: 40)
        #expect(cmds[0].contains("new-session -d -s 'cmux-view-o1' -x 120 -y 40"))
        #expect(cmds.contains { $0.contains("@cmux_view 1") })
        #expect(cmds.contains { $0.contains("@cmux_view_owner 'o1'") })
        #expect(cmds.contains { $0.contains("@cmux_view_version 1") })
    }

    @Test func parsesListRows() {
        let out = [
            "cmux-view-o1\u{1f}1\u{1f}o1\u{1f}1",
            "work\u{1f}\u{1f}\u{1f}",          // a normal session: no view options
            "cmux-view-other\u{1f}1\u{1f}o2\u{1f}1",
        ].joined(separator: "\n")
        let rows = RemoteTmuxViewSession.parseRows(out)
        #expect(rows.count == 3)
        #expect(rows[0] == .init(name: "cmux-view-o1", isView: true, owner: "o1", version: 1))
        #expect(rows[1] == .init(name: "work", isView: false, owner: "", version: nil))
        #expect(rows[2].owner == "o2")
    }

    @Test func isOwnViewOnlyForExactOwnerNameAndVersion() {
        let s = v("o1")
        #expect(s.isOwnView(.init(name: "cmux-view-o1", isView: true, owner: "o1", version: 1)))
        // wrong owner
        #expect(!s.isOwnView(.init(name: "cmux-view-o1", isView: true, owner: "o2", version: 1)))
        // not tagged a view
        #expect(!s.isOwnView(.init(name: "cmux-view-o1", isView: false, owner: "o1", version: 1)))
        // wrong version
        #expect(!s.isOwnView(.init(name: "cmux-view-o1", isView: true, owner: "o1", version: 99)))
    }

    @Test func staleViewIsOnlyOurOwnNonCurrent() {
        let s = v("o1")
        // our owner, old version → stale (collectible)
        #expect(s.isOwnStaleView(.init(name: "cmux-view-o1-old", isView: true, owner: "o1", version: 0)))
        // our current view → NOT stale
        #expect(!s.isOwnStaleView(.init(name: "cmux-view-o1", isView: true, owner: "o1", version: 1)))
        // another owner's view → NEVER stale-collectible by us
        #expect(!s.isOwnStaleView(.init(name: "cmux-view-o2", isView: true, owner: "o2", version: 0)))
        // a normal session → not a view, not collectible
        #expect(!s.isOwnStaleView(.init(name: "work", isView: false, owner: "", version: nil)))
    }

    @Test func foreignViewDetection() {
        #expect(RemoteTmuxViewSession.isForeignView(
            .init(name: "cmux-view-o2", isView: true, owner: "o2", version: 1), ownerId: "o1"))
        #expect(!RemoteTmuxViewSession.isForeignView(
            .init(name: "cmux-view-o1", isView: true, owner: "o1", version: 1), ownerId: "o1"))
        // a view with no owner stamped is not attributed to anyone → not foreign
        #expect(!RemoteTmuxViewSession.isForeignView(
            .init(name: "cmux-view-x", isView: true, owner: "", version: 1), ownerId: "o1"))
        // a normal session is never foreign-view
        #expect(!RemoteTmuxViewSession.isForeignView(
            .init(name: "work", isView: false, owner: "", version: nil), ownerId: "o1"))
    }

    @Test func ownerAndForeignAreMutuallyExclusive() {
        let s = v("o1")
        let mine = RemoteTmuxViewSession.SessionRow(name: "cmux-view-o1", isView: true, owner: "o1", version: 1)
        let theirs = RemoteTmuxViewSession.SessionRow(name: "cmux-view-o2", isView: true, owner: "o2", version: 1)
        #expect(s.isOwnView(mine) && !RemoteTmuxViewSession.isForeignView(mine, ownerId: "o1"))
        #expect(RemoteTmuxViewSession.isForeignView(theirs, ownerId: "o1") && !s.isOwnView(theirs))
    }
}
