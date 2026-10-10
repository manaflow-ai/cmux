import CmuxCloud
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("CodeRouter CLI account reader")
struct CoderouterCLIAccountReaderTests {
    /// CodeRouter's team-scoped API uses the Stack team UUID directly.
    private static let cmuxTeamID = "17a2ba34-5a88-412e-8380-0ea4118139c3"
    private static let austinOrganizationID = "17a2ba34-5a88-412e-8380-0ea4118139c3"
    private static let cmuxOrganizationID = "d13acd51-c77d-438a-9610-5369455e2a2f"

    @Test("Account reads pass the selected team directly and verify the response scope")
    func accountReadUsesSelectedTeam() async throws {
        let commands = CommandRecorder()
        let expected = Self.cmuxTeamID

        let accounts = try await CoderouterCLIAccountReader.accounts(
            for: expected,
            name: nil,
            run: { arguments in
                await commands.append(arguments)
                #expect(arguments == ["accounts", "--json", "--team", expected])
                return Data("{\"teamId\":\"\(expected)\",\"accounts\":[]}".utf8)
            }
        )
        #expect(accounts.isEmpty)

        #expect(await commands.value == [["accounts", "--json", "--team", expected]])
    }

    @Test("Account reads reject a payload from another organization")
    func accountReadRejectsWrongOrganization() async {
        let commands = CommandRecorder()
        let expected = Self.cmuxTeamID

        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.accounts(
                for: expected,
                name: nil,
                run: { arguments in
                    await commands.append(arguments)
                    return Data("{\"teamId\":\"\(Self.cmuxOrganizationID)\",\"accounts\":[]}".utf8)
                }
            )
        }

        #expect(await commands.value == [["accounts", "--json", "--team", expected]])
    }

    @Test("Account removal carries the selected team and does not switch the shared organization")
    func accountRemovalUsesSelectedTeam() async throws {
        let accountID = "a10a7f6a-27b5-4e36-9a71-005d2c0539df"
        let commands = CommandRecorder()

        try await CoderouterCLIAccountReader.remove(
            accountID: accountID,
            for: Self.cmuxTeamID,
            name: nil,
            run: { arguments in
                await commands.append(arguments)
                #expect(arguments == ["remove", accountID, "--yes", "--team", Self.cmuxTeamID])
                return Data()
            }
        )

        #expect(await commands.value == [["remove", accountID, "--yes", "--team", Self.cmuxTeamID]])
    }

    @Test("Selected team loads the accounts of its active CodeRouter organization")
    func activeOrganizationLoadsAccounts() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.austinOrganizationID)

        let accounts = try await CoderouterCLIAccountReader.accounts(
            for: Self.cmuxTeamID,
            name: "Austin Wang's Team",
            run: { try await cli.run($0) }
        )

        #expect(accounts.map(\.label) == ["austin+10@manaflow.com", "austin+3@manaflow.com"])
        #expect(accounts.map(\.provider) == [.codex, .codex])
        #expect(accounts.map(\.remainingPercent) == [93, nil])
    }

    @Test("Refresh leaves the terminal's CodeRouter organization alone")
    func matchingOrganizationIsNotSwitched() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.austinOrganizationID)

        _ = try await CoderouterCLIAccountReader.accounts(
            for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
        )

        #expect(await cli.commands == [["accounts", "--json", "--team", Self.austinOrganizationID]])
    }

    @Test("Selected team reads directly without switching another organization")
    func otherOrganizationIsNotSwitched() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.cmuxOrganizationID)

        let accounts = try await CoderouterCLIAccountReader.accounts(
            for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
        )

        #expect(accounts.map(\.label) == ["austin+10@manaflow.com", "austin+3@manaflow.com"])
        #expect(await cli.commands == [["accounts", "--json", "--team", Self.austinOrganizationID]])
    }

    @Test("Accounts from another organization never reach the sidebar")
    func wrongScopedPayloadIsRejected() async throws {
        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.accounts(
                for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { arguments in
                    #expect(arguments == ["accounts", "--json", "--team", Self.austinOrganizationID])
                    return Data("{\"teamId\":\"\(Self.cmuxOrganizationID)\",\"accounts\":[]}".utf8)
                }
            )
        }
    }

    @Test("Removing an account carries its team without a redundant account read")
    func removeRunsOnSelectedOrganization() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.cmuxOrganizationID)
        let accountID = "a10a7f6a-27b5-4e36-9a71-005d2c0539df"

        try await CoderouterCLIAccountReader.remove(
            accountID: accountID, for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
        )

        let commands = await cli.commands
        #expect(commands == [["remove", accountID, "--yes", "--team", Self.austinOrganizationID]])
    }

    @Test("A snapshot retains the organization and command scope for account creation")
    func snapshotRetainsDestination() async throws {
        let snapshot = try await CoderouterCLIAccountReader.snapshot(
            for: Self.cmuxTeamID,
            name: nil,
            run: { arguments in
                #expect(arguments == ["accounts", "--json", "--team", Self.cmuxTeamID])
                return Data("{\"teamId\":\"\(Self.cmuxTeamID)\",\"accounts\":[]}".utf8)
            }
        )

        #expect(snapshot.organizationID == Self.cmuxTeamID)
        #expect(snapshot.scope == .teamOption)
    }

    @Test("An unsupported team option uses a private legacy sequence")
    func unsupportedTeamOptionUsesLegacyFallback() async throws {
        let commands = CommandRecorder()
        let snapshot = try await CoderouterCLIAccountReader.snapshot(
            for: Self.cmuxTeamID,
            name: nil,
            run: { arguments in
                await commands.append(arguments)
                if arguments == ["accounts", "--json", "--team", Self.cmuxTeamID] {
                    throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "coderouter: usage: coderouter accounts [--watch | --json]",
                    ])
                }
                if arguments == ["org", "switch", Self.cmuxTeamID] { return Data() }
                if arguments == ["accounts", "--json"] {
                    return Data("{\"teamId\":\"\(Self.cmuxTeamID)\",\"accounts\":[]}".utf8)
                }
                throw NSError(domain: "UnexpectedCLICommand", code: 1)
            }
        )

        #expect(snapshot.scope == .isolatedConfiguration)
        #expect(await commands.value == [
            ["accounts", "--json", "--team", Self.cmuxTeamID],
            ["org", "switch", Self.cmuxTeamID],
            ["accounts", "--json"],
        ])
    }

    @Test("Runtime errors do not trigger an unscoped fallback")
    func runtimeFailureDoesNotFallback() async {
        let commands = CommandRecorder()
        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.snapshot(
                for: Self.cmuxTeamID,
                name: nil,
                run: { arguments in
                    await commands.append(arguments)
                    throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "coderouter: server returned HTTP 503",
                    ])
                }
            )
        }
        #expect(await commands.value == [["accounts", "--json", "--team", Self.cmuxTeamID]])
    }

    @Test("Legacy organization matching prefers exact IDs and rejects ambiguous names")
    func legacyOrganizationMatchingRules() throws {
        let catalog = "Example\t\(Self.cmuxOrganizationID)\nExample's Team\t\(Self.austinOrganizationID)\n"
        #expect(try CoderouterCLIAccountReader.organizationID(
            matching: Self.austinOrganizationID,
            name: nil,
            inCatalog: catalog
        ) == Self.austinOrganizationID)
        #expect(try CoderouterCLIAccountReader.organizationID(
            matching: "legacy-team",
            name: "Solo's Team",
            inCatalog: "Solo\te220a9b9-64f7-4005-a8c3-3f5f34a25b2c\n"
        ) == "e220a9b9-64f7-4005-a8c3-3f5f34a25b2c")
        #expect(throws: NSError.self) {
            try CoderouterCLIAccountReader.organizationID(matching: "legacy-team", name: "Example", inCatalog: catalog)
        }
    }

    @Test("Legacy organization matching follows the current catalog")
    func legacyOrganizationMatchingDoesNotReuseAnOldID() throws {
        #expect(try CoderouterCLIAccountReader.organizationID(
            matching: "legacy-team",
            name: "Shared Team",
            inCatalog: "Shared Team\t11111111-1111-4111-8111-111111111111\n"
        ) == "11111111-1111-4111-8111-111111111111")
        #expect(try CoderouterCLIAccountReader.organizationID(
            matching: "legacy-team",
            name: "Shared Team",
            inCatalog: "Shared Team\t22222222-2222-4222-8222-222222222222\n"
        ) == "22222222-2222-4222-8222-222222222222")
    }

    @Test("The sidebar runs the same CodeRouter CLI as cmux cr: bundled, then PATH, then the installer's")
    func resolvesTheSameCLIAsCmuxCR() {
        let app = URL(fileURLWithPath: "/Applications/cmux.app")
        let bundled = "/Applications/cmux.app/Contents/Resources/bin/coderouter"
        let onPath = "/opt/homebrew/bin/coderouter"
        let installed = "/Users/u/.coderouter/bin/coderouter"
        let environment = ["PATH": "/usr/bin:/opt/homebrew/bin", "HOME": "/Users/u"]
        func resolve(_ executables: Set<String>) -> String? {
            CoderouterCLIAccountReader.resolvedExecutable(bundleURL: app, environment: environment, isExecutable: executables.contains)
        }

        #expect(resolve([bundled, onPath, installed]) == bundled)
        #expect(resolve([onPath, installed]) == onPath)
        #expect(resolve([installed]) == installed)
        #expect(resolve([]) == nil)
    }

    @Test("CLI output drains both pipes before waiting for a chatty child")
    func drainsLargeOutputWithoutDeadlock() async throws {
        let result = try await CoderouterCLIAccountReader.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null; dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null"],
            environment: ["PATH": "/usr/bin:/bin"]
        )

        #expect(result.stdout.count == 256 * 1024)
        #expect(result.stderr.count == 256 * 1024)
    }

    @Test("Canceling a running CLI terminates the child and unblocks its readers")
    func cancellationTerminatesRunningProcess() async throws {
        let readyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readyURL) }
        let task = Task {
            try await CoderouterCLIAccountReader.runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "touch \"$CMUX_TEST_READY\"; exec sleep 1000"],
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "CMUX_TEST_READY": readyURL.path,
                ]
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: readyURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: readyURL.path))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("A malformed account ID never reaches the CLI")
    func malformedRemoveIsRejected() async {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.austinOrganizationID)

        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.remove(
                accountID: "--all", for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
            )
        }
        #expect(await cli.commands.isEmpty)
    }
}

private actor CommandRecorder {
    private(set) var value: [[String]] = []

    func append(_ command: [String]) {
        value.append(command)
    }
}

/// Replays the byte-exact output of coderouter 0.3.11, including the trailing
/// newline every command prints.
private actor FakeCoderouterCLI {
    private static let organizations: [(name: String, id: String)] = [
        ("Benjamin Swerdlow's Team", "e220a9b9-64f7-4005-a8c3-3f5f34a25b2c"),
        ("cmux", "d13acd51-c77d-438a-9610-5369455e2a2f"),
        ("AUSTIN", "8e288bf9-264c-44a3-9d85-f22cbff2a6ad"),
        ("Austin Wang", "17a2ba34-5a88-412e-8380-0ea4118139c3"),
    ]
    private static let accountLabels: [String: [String]] = [
        "17a2ba34-5a88-412e-8380-0ea4118139c3": ["austin+10@manaflow.com", "austin+3@manaflow.com"],
        "d13acd51-c77d-438a-9610-5369455e2a2f": ["team@manaflow.com"],
    ]

    private var activeOrganizationID: String
    /// Organization `org switch` lands on instead of the requested one, to model
    /// another process switching the CLI concurrently.
    private let switchOverride: String?
    private(set) var commands: [[String]] = []

    init(activeOrganizationID: String, switchOverride: String? = nil) {
        self.activeOrganizationID = activeOrganizationID
        self.switchOverride = switchOverride
    }

    func run(_ arguments: [String]) throws -> Data {
        commands.append(arguments)
        switch arguments {
        case ["org", "list"]:
            return Data(Self.organizations.map { organization in
                let marker = organization.id == activeOrganizationID ? "*" : " "
                return "\(marker)\t\(organization.name)\t\(organization.id)\n"
            }.joined().utf8)
        case ["org", "current"]:
            let name = Self.organizations.first { $0.id == activeOrganizationID }?.name ?? ""
            return Data("\(name) (\(activeOrganizationID))\n".utf8)
        case _ where arguments.count == 3 && arguments[0] == "org" && arguments[1] == "switch":
            activeOrganizationID = switchOverride ?? arguments[2]
            return Data("Switched organization.\n".utf8)
        case _ where arguments.count == 3 && arguments[0] == "remove" && arguments[2] == "--yes":
            return Data("Removed.\n".utf8)
        case _ where arguments.count == 5 && arguments[0] == "remove" && arguments[2] == "--yes" && arguments[3] == "--team":
            return Data("Removed.\n".utf8)
        case _ where arguments.count == 4 && arguments[0] == "accounts" && arguments[1] == "--json" && arguments[2] == "--team":
            return try accountPayload(for: arguments[3])
        case ["accounts", "--json"]:
            return try accountPayload(for: activeOrganizationID)
        default:
            throw NSError(domain: "FakeCoderouterCLI", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "coderouter: unexpected arguments \(arguments)",
            ])
        }
    }

    private func accountPayload(for organizationID: String) throws -> Data {
        let accounts = (Self.accountLabels[organizationID] ?? []).enumerated().map { index, label in
                var account: [String: Any] = ["id": "account-\(index)", "provider": "codex", "label": label, "state": "active"]
                // The first account reports a rate-limit window, as Codex does.
                if index == 0 {
                    account["usage"] = ["rate_limit": ["primary_window": ["used_percent": 7, "limit_window_seconds": 604800]]]
                }
                return account
            }
        let payload: [String: Any] = ["teamId": organizationID, "accounts": accounts]
        return try JSONSerialization.data(withJSONObject: payload) + Data("\n".utf8)
    }
}

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
        #expect(CoderouterProvider.claude.addCommand(for: "team's-id", scope: .teamOption) == "cmux cr add claude --team 'team'\\''s-id'")
        #expect(CoderouterProvider.codex.addCommand(for: "team-a", scope: .teamOption) == "cmux cr add codex --team 'team-a'")
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
            teamScope: .teamOption,
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
            teamScope: .teamOption,
            for: Self.teamA
        )

        #expect(!applied)
        #expect(state.accounts.isEmpty)
        #expect(state.isLoadingScope)
    }

    @Test("A same-team failure keeps rows but disables account creation")
    func failureKeepsRowsWithoutDestination() {
        var state = loaded(Self.teamA, ["a1"])
        state.fail(for: Self.teamA)

        #expect(state.accounts.map(\.id) == ["a1"])
        #expect(state.destination(for: Self.teamA) == nil)
        #expect(!state.isLoadingScope)
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
            teamScope: .teamOption,
            for: Self.teamA
        )
        #expect(state.accounts.map(\.id) == ["a1"])
    }

    @Test("A stale post-removal read stays hidden until absence is confirmed")
    func postRemovalReadDoesNotReinsertAccount() {
        var state = loaded(Self.teamA, ["a1", "a2"])
        let inFlightRead = state.beginRefresh(for: Self.teamA)
        #expect(state.removeOptimistically(accountID: "a2", for: Self.teamA) == 1)
        #expect(
            !state.apply(
                accounts: [account("a1"), account("a2")],
                organizationID: "org-team-a",
                teamScope: .teamOption,
                for: Self.teamA,
                startedAt: inFlightRead
            )
        )

        // The CLI write succeeded, but the first read can still observe its
        // old account list. Keep the row pending until a later read omits it.
        state.finishRemoval(accountID: "a2", for: Self.teamA)
        #expect(state.pendingRemovalIDs == ["a2"])
        let staleRead = state.beginRefresh(for: Self.teamA)
        #expect(
            state.apply(
                accounts: [account("a1"), account("a2")],
                organizationID: "org-team-a",
                teamScope: .teamOption,
                for: Self.teamA,
                startedAt: staleRead
            )
        )
        #expect(state.accounts.map(\.id) == ["a1"])
        #expect(state.pendingRemovalIDs == ["a2"])

        let confirmedRead = state.beginRefresh(for: Self.teamA)
        #expect(
            state.apply(
                accounts: [account("a1")],
                organizationID: "org-team-a",
                teamScope: .teamOption,
                for: Self.teamA,
                startedAt: confirmedRead
            )
        )
        #expect(state.accounts.map(\.id) == ["a1"])
        #expect(state.pendingRemovalIDs.isEmpty)
    }

    @Test("A team switch keeps an unconfirmed removal scoped to that team")
    func teamRoundTripKeepsRemovalHidden() {
        var state = loaded(Self.teamA, ["a2"])
        #expect(state.removeOptimistically(accountID: "a2", for: Self.teamA) == 0)
        state.finishRemoval(accountID: "a2", for: Self.teamA)

        state.select(Self.teamB)
        #expect(state.pendingRemovalIDs.isEmpty)
        state.select(Self.teamA)
        #expect(state.pendingRemovalIDs == ["a2"])

        let read = state.beginRefresh(for: Self.teamA)
        #expect(
            state.apply(
                accounts: [account("a2")],
                organizationID: "org-team-a",
                teamScope: .teamOption,
                for: Self.teamA,
                startedAt: read
            )
        )
        #expect(state.accounts.isEmpty)
        #expect(state.pendingRemovalIDs == ["a2"])
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
