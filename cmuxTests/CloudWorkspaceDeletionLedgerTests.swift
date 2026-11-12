import CmuxSurfaceCatalogModel
import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud workspace deletion ledger", .serialized)
struct CloudWorkspaceDeletionLedgerTests {
    private let machine = SurfaceMachineID.cloud("gcp-machine")

    @Test("begin hides immediately and success survives a stale refresh")
    func successTombstoneSurvivesStaleRefresh() throws {
        let ledger = CloudWorkspaceDeletionLedger()
        let token = ledger.begin(machine: machine, workspaceID: "workspace-7")
        #expect(token != nil)
        #expect(ledger.hides(machine: machine, workspaceID: "workspace-7"))
        #expect(ledger.isPending(machine: machine, workspaceID: "workspace-7"))

        let request = try #require(token)
        #expect(ledger.succeed(machine: machine, workspaceID: "workspace-7", token: request))
        #expect(!ledger.isPending(machine: machine, workspaceID: "workspace-7"))
        #expect(ledger.hides(machine: machine, workspaceID: "workspace-7"))
        ledger.reconcile(try graph(["workspace-7"], revision: 1))
        #expect(ledger.hides(machine: machine, workspaceID: "workspace-7"))
        ledger.reconcile(try graph([], revision: 2))
        ledger.reconcile(try graph(["workspace-7"], revision: 1))
        #expect(ledger.hides(machine: machine, workspaceID: "workspace-7"), "A stale snapshot cannot undo confirmed absence")
        ledger.reconcile(try graph(["workspace-7"], revision: 3))
        #expect(!ledger.hides(machine: machine, workspaceID: "workspace-7"), "A genuinely newer workspace operation can reuse the ID")
    }

    @Test("failure restores the row and ignores stale request completions")
    func failureRollsBackAndRepeatedDeleteIsIgnored() throws {
        let ledger = CloudWorkspaceDeletionLedger()
        let token = try #require(ledger.begin(machine: machine, workspaceID: "workspace-8"))
        #expect(ledger.begin(machine: machine, workspaceID: "workspace-8") == nil)
        #expect(ledger.fail(machine: machine, workspaceID: "workspace-8", token: UUID()) == false)
        #expect(ledger.fail(machine: machine, workspaceID: "workspace-8", token: token))
        #expect(!ledger.hides(machine: machine, workspaceID: "workspace-8"))
        #expect(ledger.succeed(machine: machine, workspaceID: "workspace-8", token: token) == false)
    }

    @Test("independent workspaces can be deleted concurrently")
    func concurrentDeletesHaveIndependentIdentity() throws {
        let ledger = CloudWorkspaceDeletionLedger()
        let first = try #require(ledger.begin(machine: machine, workspaceID: "workspace-4"))
        let second = try #require(ledger.begin(machine: machine, workspaceID: "workspace-9"))
        #expect(first != second)
        #expect(ledger.hides(machine: machine, workspaceID: "workspace-4"))
        #expect(ledger.hides(machine: machine, workspaceID: "workspace-9"))
        #expect(ledger.succeed(machine: machine, workspaceID: "workspace-4", token: first))
        #expect(ledger.fail(machine: machine, workspaceID: "workspace-9", token: second))
        #expect(ledger.hides(machine: machine, workspaceID: "workspace-4"))
        #expect(!ledger.hides(machine: machine, workspaceID: "workspace-9"))
    }
    @Test("A different generation cannot itself resurrect a deleted workspace")
    func generationChangeRequiresAbsenceBeforeReuse() throws {
        let ledger = CloudWorkspaceDeletionLedger()
        let token = try #require(ledger.begin(machine: machine, workspaceID: "old"))
        #expect(ledger.succeed(machine: machine, workspaceID: "old", token: token))
        ledger.reconcile(try graph([], revision: 4))
        ledger.reconcile(try graph(["old"], revision: 100, generation: "other"))
        #expect(ledger.hides(machine: machine, workspaceID: "old"))
        ledger.reconcile(try graph([], revision: 101, generation: "other"))
        ledger.reconcile(try graph(["old"], revision: 102, generation: "other"))
        #expect(!ledger.hides(machine: machine, workspaceID: "old"))
    }

    private func graph(_ ids: [String], revision: Int, generation: String = "delete") throws -> CloudVMState {
        try #require(CmuxTuiSnapshotParser.state(fromSnapshot: [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": ids.map { ["id": $0, "name": $0] },
            "screens": [], "panes": [], "tabs": [], "terminals": [], "browsers": [], "agents": []
        ], machine: machine))
    }

}
