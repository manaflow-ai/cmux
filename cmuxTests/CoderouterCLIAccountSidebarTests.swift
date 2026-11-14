import AppKit
import CmuxCloud
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("CodeRouter sidebar section")
struct CoderouterSidebarSectionTests {
    private func account(_ id: String, _ provider: CoderouterProvider, state: String = "active", remaining: Int? = nil) -> CloudTreeNode.CoderouterAccount {
        CloudTreeNode.CoderouterAccount(id: id, provider: provider, label: "\(id)@example.com", state: state, remainingPercent: remaining)
    }

    @Test("Accounts group by type, each addable type led by its New Account row")
    func groupsByProviderWithCreateRows() throws {
        let section = CloudTreeCoderouterSection(accounts: [
            account("a", .codex, remaining: 93),
            account("b", .codex),
            account("c", CoderouterProvider(id: "gemini")),
        ])

        let root = try #require(CloudTreeCreateActionBuilder.add(to: [CloudTreeNodeBuilder.coderouterNode(section)]).first)

        #expect(root.kind == .coderouterSection(count: 3, refresh: CloudTreeSectionRefresh()))
        #expect(root.children.map(\.searchableTitle) == ["Codex", "Claude", "OpenCode", "Gemini"])
        let codex = root.children[0]
        #expect(codex.kind == .coderouterProviderGroup(.codex, count: 2))
        #expect(codex.children.map(\.searchableTitle) == ["New Codex Account", "a@example.com", "b@example.com"])
        // An empty addable type still offers its New Account row.
        #expect(root.children[1].children.map(\.searchableTitle) == ["New Claude Account"])
        #expect(root.children[2].children.map(\.searchableTitle) == ["New OpenCode Account"])
        // A type CodeRouter can't add lists its accounts without a create row.
        #expect(root.children[3].children.map(\.searchableTitle) == ["c@example.com"])
    }

    @Test("New Account rows run the CLI add flow for their type")
    func createRowAddsItsType() {
        final class Added { var providers: [CoderouterProvider] = [] }
        let added = Added()
        var actions = CloudTreeNodeActions(
            project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {}
        )
        actions.addCoderouterAccount = { added.providers.append($0) }

        CloudTreeCreateAction.newCoderouterAccount(.claude).perform(actions)

        #expect(added.providers == [.claude])
        #expect(CoderouterProvider.claude.addCommand == "cmux cr add claude")
        // The server names OpenCode Go accounts `opencode-go`; the CLI verb is `opencode`.
        #expect(CoderouterProvider(id: "opencode-go") == .opencodeGo)
        #expect(CoderouterProvider.opencodeGo.addCommand == "cmux cr add opencode")
    }

    @Test("New Account launches a dedicated focused terminal")
    func focusedAgentUsesDedicatedTerminal() {
        let launch = CoderouterAccountTerminalLaunch(provider: .codex)

        #expect(launch.command == ["sh", "-lc", "cmux cr add codex"])
        #expect(launch.name == "CodeRouter")
        #expect(launch.focus)
    }

    @Test("An unlabeled key account reads as its type and key suffix")
    func unlabeledAccountTitle() {
        let claude = CloudTreeNode.CoderouterAccount(
            id: "c", provider: .claude, label: "", state: "active", identifier: "sk-ant-oat01-...JF1g"
        )
        #expect(claude.title == "Claude \u{2026}JF1g")
        #expect(account("a", .codex).title == "a@example.com")
        #expect(CloudTreeNode.CoderouterAccount(id: "d", provider: .codex, label: nil, state: nil).title == "Codex")
    }

    @Test("Account rows show usage left, or a state that is not active")
    func usageDetail() {
        #expect(CloudTreeRowContentView.usageDetail(for: account("a", .codex, remaining: 93)) == "93% left")
        #expect(CloudTreeRowContentView.usageDetail(for: account("a", .codex, state: "cooldown", remaining: 93)) == "Cooldown")
        #expect(CloudTreeRowContentView.usageDetail(for: account("a", .claude)) == nil)
    }
}

@Suite("CodeRouter sidebar account state")
struct CoderouterAccountStateTests {
    private static let teamA = CoderouterAccountScope(teamID: "team-a", identityID: "user-1")!
    private static let teamB = CoderouterAccountScope(teamID: "team-b", identityID: "user-1")!

    private func account(_ id: String) -> CloudTreeNode.CoderouterAccount {
        CloudTreeNode.CoderouterAccount(id: id, provider: .codex, label: "\(id)@example.com", state: "active")
    }

    private func loaded(_ scope: CoderouterAccountScope, _ ids: [String]) -> CoderouterAccountState {
        var state = CoderouterAccountState()
        state.select(scope)
        state.apply(
            accounts: ids.map(account),
            organizationID: "org-\(scope.teamID)",
            for: scope
        )
        return state
    }

    @Test("Selecting a different team clears rows and requires a new read")
    func teamChangeClearsRows() {
        var state = loaded(Self.teamA, ["a1", "a2"])
        state.select(Self.teamB)

        #expect(state.accounts.isEmpty)
        #expect(state.isLoadingScope)
        #expect(state.destination(for: Self.teamB) == nil)
    }

    @Test("A cloud scope notification drops rows before the confirmed team changes")
    func scopeChangeNotificationClearsRows() {
        var state = loaded(Self.teamA, ["a1"])
        state.resetForTeamScopeChange()

        #expect(state.scope == nil)
        #expect(state.accounts.isEmpty)
        #expect(state.destination(for: Self.teamA) == nil)
        #expect(!state.isLoadingScope)
    }

    @Test("Changing the signed-in identity clears rows even when the team is unchanged")
    func identityChangeClearsRows() {
        var state = loaded(Self.teamA, ["a1"])
        state.select(CoderouterAccountScope(teamID: "team-a", identityID: "user-2"))
        #expect(state.accounts.isEmpty)
    }

    @Test("A late read for an old team cannot repopulate the new team")
    func staleResultsAreDropped() {
        var state = loaded(Self.teamA, ["a1"])
        state.select(Self.teamB)

        let applied = state.apply(
            accounts: [account("a2")],
            organizationID: "org-team-a",
            for: Self.teamA
        )

        #expect(!applied)
        #expect(state.accounts.isEmpty)
        #expect(state.isLoadingScope)
    }

    @Test("A same-team failure keeps rows but disables account creation")
    func failureKeepsRowsWithoutDestination() {
        var state = loaded(Self.teamA, ["a1"])
        state.fail(.unreachable, for: Self.teamA)

        #expect(state.accounts.map(\.id) == ["a1"])
        #expect(state.destination(for: Self.teamA) == nil)
        #expect(!state.isLoadingScope)
    }

    @Test("A failed read keeps its reason until a read succeeds")
    func failureIsRetainedUntilSuccess() {
        var state = CoderouterAccountState()
        state.select(Self.teamA)
        #expect(state.addAvailability(for: Self.teamA) == .loading)

        let revision = state.beginRefresh(for: Self.teamA)
        state.fail(.notMember, for: Self.teamA, startedAt: revision)
        #expect(state.failure == .notMember)
        #expect(state.addAvailability(for: Self.teamA) == .failed(.notMember))

        // A retry in flight still names the last failure, not "loading".
        _ = state.beginRefresh(for: Self.teamA)
        #expect(state.addAvailability(for: Self.teamA) == .failed(.notMember))

        state.apply(accounts: [account("a1")], organizationID: "org-team-a", for: Self.teamA)
        #expect(state.failure == nil)
        #expect(state.addAvailability(for: Self.teamA) == .ready(CoderouterAccountDestination(organizationID: "org-team-a")))
    }

    @Test("Switching teams drops the old team's failure and ignores its late result")
    func teamSwitchClearsFailure() {
        var state = CoderouterAccountState()
        state.select(Self.teamA)
        let revisionA = state.beginRefresh(for: Self.teamA)
        state.fail(.notMember, for: Self.teamA, startedAt: revisionA)

        state.select(Self.teamB)
        #expect(state.failure == nil)
        #expect(state.addAvailability(for: Self.teamB) == .loading)
        // The old team's scope can never report a failure or destination.
        #expect(state.addAvailability(for: Self.teamA) == .loading)

        state.fail(.signInRequired, for: Self.teamA, startedAt: revisionA)
        #expect(state.failure == nil)
        #expect(state.isLoadingScope)

        state.resetForTeamScopeChange()
        #expect(state.failure == nil)
    }

    @Test("An explicit refresh invalidates the last valid add destination")
    func explicitRefreshInvalidatesDestination() {
        var state = loaded(Self.teamA, ["a1"])
        let destination = state.destination(for: Self.teamA)

        #expect(state.destination(for: Self.teamA) == destination)
        state.invalidateDestination(for: Self.teamA)
        #expect(state.destination(for: Self.teamA) == nil)
    }

    @Test("An optimistic removal stays hidden from an earlier refresh")
    func pendingRemovalWinsOverEarlierRead() {
        var state = loaded(Self.teamA, ["a1", "a2"])
        let index = state.removeOptimistically(accountID: "a2", for: Self.teamA)
        #expect(index == 1)

        _ = state.apply(
            accounts: [account("a1"), account("a2")],
            organizationID: "org-team-a",
            for: Self.teamA
        )
        #expect(state.accounts.map(\.id) == ["a1"])
    }

    @Test("A stale post-removal read stays hidden until absence is confirmed")
    func postRemovalReadDoesNotReinsertAccount() {
        var state = loaded(Self.teamA, ["a1", "a2"])
        let inFlightRead = state.beginRefresh(for: Self.teamA)
        let removedIndex = state.removeOptimistically(accountID: "a2", for: Self.teamA)
        #expect(removedIndex == 1)
        let rejectedRead = state.apply(
            accounts: [account("a1"), account("a2")],
            organizationID: "org-team-a",
            for: Self.teamA,
            startedAt: inFlightRead
        )
        #expect(!rejectedRead)

        // The CLI write succeeded, but the first read can still observe its
        // old account list. Keep the row pending until a later read omits it.
        state.finishRemoval(accountID: "a2", for: Self.teamA)
        #expect(state.pendingRemovalIDs == ["a2"])
        let staleRead = state.beginRefresh(for: Self.teamA)
        let staleReadApplied = state.apply(
            accounts: [account("a1"), account("a2")],
            organizationID: "org-team-a",
            for: Self.teamA,
            startedAt: staleRead
        )
        #expect(staleReadApplied)
        #expect(state.accounts.map(\.id) == ["a1"])
        #expect(state.pendingRemovalIDs == ["a2"])

        let confirmedRead = state.beginRefresh(for: Self.teamA)
        let confirmedReadApplied = state.apply(
            accounts: [account("a1")],
            organizationID: "org-team-a",
            for: Self.teamA,
            startedAt: confirmedRead
        )
        #expect(confirmedReadApplied)
        #expect(state.accounts.map(\.id) == ["a1"])
        #expect(state.pendingRemovalIDs.isEmpty)
    }

    @Test("A team switch keeps an unconfirmed removal scoped to that team")
    func teamRoundTripKeepsRemovalHidden() {
        var state = loaded(Self.teamA, ["a2"])
        let removedIndex = state.removeOptimistically(accountID: "a2", for: Self.teamA)
        #expect(removedIndex == 0)
        state.finishRemoval(accountID: "a2", for: Self.teamA)

        state.select(Self.teamB)
        #expect(state.pendingRemovalIDs.isEmpty)
        state.select(Self.teamA)
        #expect(state.pendingRemovalIDs == ["a2"])

        let read = state.beginRefresh(for: Self.teamA)
        let readApplied = state.apply(
            accounts: [account("a2")],
            organizationID: "org-team-a",
            for: Self.teamA,
            startedAt: read
        )
        #expect(readApplied)
        #expect(state.accounts.isEmpty)
        #expect(state.pendingRemovalIDs == ["a2"])
    }
}

@MainActor
@Suite("CodeRouter sidebar store")
struct CoderouterAccountStoreTests {
    @Test("Scope transitions clear retained rows while Machines is unmounted")
    func scopeTransitionClearsRetainedState() {
        let store = CoderouterAccountStore()
        let scope = CoderouterAccountScope(teamID: "team-a", identityID: "user-1")!
        store.state.select(scope)
        _ = store.state.apply(
            accounts: [CloudTreeNode.CoderouterAccount(id: "a1", provider: .codex, label: "a1@example.com", state: "active")],
            organizationID: "org-team-a",
            for: scope
        )

        store.resetForTeamScopeChange()

        #expect(store.state.accounts.isEmpty)
        #expect(store.state.scope == nil)
        #expect(store.isRefreshing)
        #expect(store.refreshRequest == 1)
    }

    @Test("A team scope transition invalidates a pending New Account operation")
    func teamScopeTransitionInvalidatesPendingAdd() {
        let store = CoderouterAccountStore()
        let generation = store.beginAddTask()

        #expect(store.isCurrentAddTask(generation))
        store.resetForTeamScopeChange()
        #expect(!store.isCurrentAddTask(generation))
        #expect(store.isRefreshing)
        #expect(store.isCurrentAddTask(store.beginAddTask()))
    }

    @Test("A team scope transition cancels the running setup operation")
    func teamScopeTransitionCancelsRunningAdd() async {
        let store = CoderouterAccountStore()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (suspended, release) = AsyncStream<Void>.makeStream()
        let (finished, finish) = AsyncStream<Void>.makeStream()
        defer { start.finish(); release.finish(); finish.finish() }
        var sawCancellation = false
        var couldLaunch = true

        store.startAddTask { generation in
            start.yield()
            for await _ in suspended { break }
            sawCancellation = Task.isCancelled
            couldLaunch = store.isCurrentAddTask(generation)
            finish.yield()
        }
        for await _ in started { break }

        store.resetForTeamScopeChange()
        for await _ in finished { break }

        #expect(sawCancellation)
        #expect(!couldLaunch)
    }

    @Test("Remounted machine panels reuse the CodeRouter state owner")
    func remountedPanelsKeepStore() {
        let store = CoderouterAccountStore()
        let activationCoordinator = CloudActivationCoordinator.unconfigured()
        let firstPanel = MachinesPanelView(
            chromeBackgroundColor: .windowBackgroundColor,
            activationCoordinator: activationCoordinator,
            coderouterStore: store
        )
        let remountedPanel = MachinesPanelView(
            chromeBackgroundColor: .windowBackgroundColor,
            activationCoordinator: activationCoordinator,
            coderouterStore: store
        )

        #expect(firstPanel.coderouterStore === remountedPanel.coderouterStore)
        #expect(firstPanel.coderouterStore.lane === remountedPanel.coderouterStore.lane)
        #expect(CoderouterAccountStore().lane === CoderouterAccountStore().lane)
    }
}

@MainActor
@Suite("CodeRouter CLI operation lane")
struct CoderouterCLIOperationLaneTests {
    @MainActor
    private final class Log {
        var events: [String] = []
        var running = 0
        var maxRunning = 0
    }

    @Test("Operations run in order and never overlap")
    func operationsAreSerial() async {
        let lane = CoderouterCLIOperationLane()
        let log = Log()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (gate, openGate) = AsyncStream<Void>.makeStream()

        let first = lane.enqueue {
            log.running += 1
            log.maxRunning = max(log.maxRunning, log.running)
            log.events.append("start")
            startedContinuation.yield()
            for await _ in gate { break }
            log.events.append("end")
            log.running -= 1
        }
        let second = lane.enqueue {
            log.running += 1
            log.maxRunning = max(log.maxRunning, log.running)
            log.events.append("second")
            log.running -= 1
        }

        for await _ in started { break }
        openGate.yield()
        openGate.finish()
        await first.value
        await second.value

        #expect(log.events == ["start", "end", "second"])
        #expect(log.maxRunning == 1)
    }
}
