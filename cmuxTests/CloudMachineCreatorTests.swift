import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `/api/vm` publishes who made each machine. The sidebar's whole complaint is
/// that a team's fleet reads as a pile of generated three-word names with no
/// way to tell whose is whose, so the author has to survive both hops between
/// the response and the row: the list decode and the snapshot the row renders
/// from. The socket payload is the third place the same facts are published,
/// to the CLI and remote clients rather than to the sidebar.
/// `.serialized` because the network tests here drive the same process-global
/// `CloudRefreshURLProtocol.responses` as `VMClientReadCoalescingTests`, which
/// carries the trait for the same reason: a `reset()` landing between another
/// test's `configure` and its request start serves the wrong body. The trait
/// only orders this suite's own tests; the two suites do not overlap because CI
/// runs with `-parallel-testing-enabled NO`.
@Suite("Cloud machine creator metadata", .serialized)
struct CloudMachineCreatorTests {
    @MainActor
    @Test("the machine list decodes the author the backend sends")
    func listDecodesCreator() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.authoredList)
        let page = try await fixture.client.listPage()
        let byID = Dictionary(uniqueKeysWithValues: page.vms.map { ($0.id, $0) })

        let named = try #require(byID["fixture-0"]?.createdBy)
        #expect(named.userId == "user-a")
        #expect(named.displayName == "Ada Lovelace")

        // An account nothing has recorded a name for. The id still arrives, so
        // rows by the same person group together even while they read
        // "Unknown"; dropping the creator here would lose that.
        let anonymous = try #require(byID["fixture-1"]?.createdBy)
        #expect(anonymous.userId == "user-b")
        #expect(anonymous.displayName == nil)

        // A control plane that predates the field. Absent, not "Unknown".
        #expect(byID["fixture-2"]?.createdBy == nil)
    }

    /// `create` and `status(id:)` each have exactly one caller, the matching
    /// socket method, so what they decode is what `cmux vm new --json` and
    /// `cmux vm status --json` print. Neither feeds the sidebar: the panel only
    /// ever assigns a whole list result. Pinned so the two endpoints stay
    /// consistent with the list rather than each carrying a different subset of
    /// the response.
    @MainActor
    @Test("the single-machine endpoints carry the author too")
    func singleMachineReadsCarryCreator() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.authoredList)

        let created = try await fixture.client.create(idempotencyKey: UUID().uuidString)
        #expect(created.createdBy?.userId == "user-a")
        #expect(created.createdBy?.displayName == "Ada Lovelace")

        let read = try await fixture.client.status(id: "fixture-9")
        #expect(read.createdBy?.userId == "user-a")
        #expect(read.createdBy?.displayName == "Ada Lovelace")
    }

    @Test("a blank author id decodes as no author")
    func blankCreatorIsNoCreator() {
        #expect(VMCreator(vmResponse: ["createdBy": ["userId": "  ", "displayName": "Ada"]]) == nil)
        #expect(VMCreator(vmResponse: ["createdBy": NSNull()]) == nil)
        #expect(VMCreator(vmResponse: [:]) == nil)
        // A name of only whitespace is no name, not a row that renders blank.
        #expect(VMCreator(vmResponse: ["createdBy": ["userId": "user-a", "displayName": " "]])?.displayName == nil)
    }

    @Test("the row's snapshot carries the author through the builder")
    func snapshotCarriesCreator() {
        let summary = VMSummary(
            id: "vm-1",
            provider: "fixture",
            status: "running",
            image: "desktop-vnc",
            createdAt: 1_700_000_000_000,
            createdBy: VMCreator(userId: "user-a", displayName: "Ada Lovelace")
        )
        let snapshot = MachineSnapshotBuilder.snapshot(from: summary)
        #expect(snapshot.createdBy?.userId == "user-a")
        #expect(snapshot.createdBy?.displayName == "Ada Lovelace")
        #expect(snapshot.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Machines the surface catalog found before the list named them have no
    /// author to show, and must not borrow one.
    @Test("catalog-discovered machines have no author")
    func catalogMachinesHaveNoCreator() {
        let summary = VMSummary(
            id: "vm-1", provider: "fixture", status: "running", image: "desktop-vnc", createdAt: 0
        )
        #expect(MachineSnapshotBuilder.snapshot(from: summary).createdBy == nil)
    }

    /// `vm.list` over the socket is how the CLI and remote clients see the
    /// fleet: they never touch `/api/vm` themselves, they get this. Dropping
    /// the author here would leave `cmux` on the command line unable to answer
    /// a question the sidebar beside it can.
    @Test("the socket payload re-publishes the author")
    func socketPayloadCarriesCreator() throws {
        let payload = TerminalController.socketWorkerVMSummaryPayload(
            VMSummary(
                id: "vm-1",
                provider: "fixture",
                status: "running",
                image: "desktop-vnc",
                createdAt: 0,
                createdBy: VMCreator(userId: "user-a", displayName: "Ada Lovelace")
            )
        )
        let createdBy = try #require(payload["createdBy"] as? [String: Any])
        #expect(createdBy["userId"] as? String == "user-a")
        #expect(createdBy["displayName"] as? String == "Ada Lovelace")

        // No author sends no key. The backend sends an explicit null here, and
        // both readers treat absent and null alike, so this is the narrower of
        // the two shapes rather than a different meaning.
        let anonymous = TerminalController.socketWorkerVMSummaryPayload(
            VMSummary(id: "vm-2", provider: "fixture", status: "running", image: "desktop-vnc", createdAt: 0)
        )
        #expect(anonymous["createdBy"] == nil)

        // A known account with no recorded name keeps the id and sends an
        // explicit null, so the relayed row still groups with its siblings.
        let unnamed = TerminalController.socketWorkerVMSummaryPayload(
            VMSummary(
                id: "vm-3",
                provider: "fixture",
                status: "running",
                image: "desktop-vnc",
                createdAt: 0,
                createdBy: VMCreator(userId: "user-b", displayName: nil)
            )
        )
        let unnamedCreator = try #require(unnamed["createdBy"] as? [String: Any])
        #expect(unnamedCreator["userId"] as? String == "user-b")
        #expect(unnamedCreator["displayName"] is NSNull)
    }

    @Test("the socket payload preserves attach transport capabilities")
    func socketPayloadCarriesAttachTransports() throws {
        let payload = TerminalController.socketWorkerVMSummaryPayload(
            VMSummary(
                id: "vm-ssh-only",
                provider: "fixture",
                status: "running",
                image: "desktop-vnc",
                createdAt: 0,
                capabilities: VMCapabilities(
                    snapshot: true,
                    restore: true,
                    fork: true,
                    attachTransports: ["ssh"]
                )
            )
        )
        let capabilities = try #require(payload["capabilities"] as? [String: Any])
        #expect(capabilities["attach_transports"] as? [String] == ["ssh"])
        #expect(capabilities["attachTransports"] == nil)

        let legacyPayload = TerminalController.socketWorkerVMSummaryPayload(
            VMSummary(
                id: "vm-legacy",
                provider: "fixture",
                status: "running",
                image: "desktop-vnc",
                createdAt: 0
            )
        )
        let legacyCapabilities = try #require(legacyPayload["capabilities"] as? [String: Any])
        #expect(legacyCapabilities["attach_transports"] == nil)
    }
}
