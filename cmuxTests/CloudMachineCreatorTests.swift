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

    /// Every hop above carries the author and the sidebar still does not show
    /// it, which is the whole complaint: on a team the fleet reads as a list of
    /// generated three-word names with no way to tell whose is whose. The row's
    /// second line already holds the machine's other identity facts (its id,
    /// its kind, its age) and the tooltip repeats that line, so the author
    /// belongs there rather than behind a new control.
    @Test("the machine row says who made it")
    func rowSubtitleNamesTheAuthor() {
        let content = CloudTreeMachineRowContent(machine: Self.machine(
            createdBy: VMCreator(userId: "user-a", displayName: "Ada Lovelace")
        ))
        #expect(content.subtitle.contains("by Ada Lovelace"))
        // The tooltip is how a single-line row reaches the same facts, so the
        // default preset must not be the one that hides the author.
        #expect(content.toolTip.contains("by Ada Lovelace"))
        // Still the machine's own line: the author is added to the identity
        // facts, not put in place of them.
        #expect(content.subtitle.contains("vm-1"))
        #expect(content.subtitle.contains("Base"))
    }

    /// The two ways there is no name to show. A known account with no recorded
    /// name is the interesting one: the account id is not a name, and a row
    /// reading "by 7f3a91c2" is one more generated token in the pile this is
    /// meant to clear, so the row says nothing rather than something opaque.
    @Test("a machine with no named author says nothing about one")
    func rowStaysQuietWithoutAName() {
        let unnamed = CloudTreeMachineRowContent(machine: Self.machine(
            createdBy: VMCreator(userId: "7f3a91c2", displayName: nil)
        ))
        #expect(unnamed.subtitle.contains("by ") == false)
        #expect(unnamed.subtitle.contains("7f3a91c2") == false)

        let anonymous = CloudTreeMachineRowContent(machine: Self.machine(createdBy: nil))
        #expect(anonymous.subtitle.contains("by ") == false)
        // The separator is not left dangling either way.
        #expect(anonymous.subtitle.hasSuffix("·") == false)
    }

    @Test("a name of only whitespace is not a name")
    func blankNameShowsNoAuthor() {
        #expect(CloudMachineCreatorLabel.text(creator: VMCreator(userId: "u", displayName: "   ")) == nil)
        #expect(CloudMachineCreatorLabel.text(creator: nil) == nil)
        #expect(CloudMachineCreatorLabel.text(creator: VMCreator(userId: "u", displayName: "Ada")) == "by Ada")
    }

    /// Labelled, so the subtitle also carries the id, and old enough that the
    /// relative age is a stable string rather than "in 0 seconds".
    private static func machine(createdBy: VMCreator?) -> MachineSnapshot {
        MachineSnapshot(
            id: "vm-1",
            provider: "fixture",
            image: "devbox",
            isDesktop: false,
            activity: .ready,
            createdAt: Date(timeIntervalSinceNow: -3 * 60 * 60),
            createdBy: createdBy,
            label: "build box"
        )
    }
}
