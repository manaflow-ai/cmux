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
    /// The cmux team ID never equals the CodeRouter organization ID; the reader
    /// maps "Austin Wang's Team" to the "Austin Wang" organization by name.
    private static let cmuxTeamID = "fa8d2c52-5c8b-4ee5-97c4-f123e320f08f"
    private static let austinOrganizationID = "17a2ba34-5a88-412e-8380-0ea4118139c3"
    private static let cmuxOrganizationID = "d13acd51-c77d-438a-9610-5369455e2a2f"

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

    @Test("The account snapshot retains the organization ID for team-scoped creates")
    func snapshotRetainsOrganizationID() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.austinOrganizationID)

        let snapshot = try await CoderouterCLIAccountReader.snapshot(
            for: Self.cmuxTeamID,
            name: "Austin Wang's Team",
            run: { try await cli.run($0) }
        )

        #expect(snapshot.organizationID == Self.austinOrganizationID)
        #expect(snapshot.accounts.map(\.label) == ["austin+10@manaflow.com", "austin+3@manaflow.com"])
    }

    @Test("Refresh leaves the terminal's CodeRouter organization alone when it already matches")
    func matchingOrganizationIsNotSwitched() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.austinOrganizationID)

        _ = try await CoderouterCLIAccountReader.accounts(
            for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
        )

        #expect(await cli.commands.allSatisfy { $0.prefix(2) != ["org", "switch"] })
    }

    @Test("Selected team switches the CLI away from another organization")
    func otherOrganizationIsSwitched() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.cmuxOrganizationID)

        let accounts = try await CoderouterCLIAccountReader.accounts(
            for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
        )

        #expect(accounts.map(\.label) == ["austin+10@manaflow.com", "austin+3@manaflow.com"])
        #expect(await cli.commands.contains(["org", "switch", Self.austinOrganizationID]))
    }

    @Test("Accounts from another organization never reach the sidebar")
    func concurrentSwitchIsRejected() async throws {
        let cli = FakeCoderouterCLI(
            activeOrganizationID: Self.cmuxOrganizationID,
            switchOverride: Self.cmuxOrganizationID
        )

        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.accounts(
                for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
            )
        }
    }

    @Test("Removing an account selects the team's organization before the CLI removes it")
    func removeRunsOnSelectedOrganization() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.cmuxOrganizationID)
        let accountID = "a10a7f6a-27b5-4e36-9a71-005d2c0539df"

        try await CoderouterCLIAccountReader.remove(
            accountID: accountID, for: Self.cmuxTeamID, name: "Austin Wang's Team", run: { try await cli.run($0) }
        )

        let commands = await cli.commands
        let switchIndex = try #require(commands.firstIndex(of: ["org", "switch", Self.austinOrganizationID]))
        let removeIndex = try #require(commands.firstIndex(of: ["remove", accountID, "--yes"]))
        #expect(switchIndex < removeIndex)
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
        case ["accounts", "--json"]:
            let accounts = (Self.accountLabels[activeOrganizationID] ?? []).enumerated().map { index, label in
                var account: [String: Any] = ["id": "account-\(index)", "provider": "codex", "label": label, "state": "active"]
                // The first account reports a rate-limit window, as Codex does.
                if index == 0 {
                    account["usage"] = ["rate_limit": ["primary_window": ["used_percent": 7, "limit_window_seconds": 604800]]]
                }
                return account
            }
            let payload: [String: Any] = ["teamId": activeOrganizationID, "accounts": accounts]
            return try JSONSerialization.data(withJSONObject: payload) + Data("\n".utf8)
        default:
            throw NSError(domain: "FakeCoderouterCLI", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "coderouter: unexpected arguments \(arguments)",
            ])
        }
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
        #expect(root.children.map(\.searchableTitle) == ["Codex", "Claude", "OpenCode Go", "Gemini"])
        let codex = root.children[0]
        #expect(codex.kind == .coderouterProviderGroup(.codex, count: 2))
        #expect(codex.children.map(\.searchableTitle) == ["New Codex Account", "a@example.com", "b@example.com"])
        // An empty addable type still offers its New Account row.
        #expect(root.children[1].children.map(\.searchableTitle) == ["New Claude Account"])
        #expect(root.children[2].children.map(\.searchableTitle) == ["New OpenCode Go Account"])
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
        let teamScopedCodex = CoderouterProvider.codex.addCommand(for: "17a2ba34-5a88-412e-8380-0ea4118139c3")
        #expect(teamScopedCodex.contains("cmux cr org switch '17a2ba34-5a88-412e-8380-0ea4118139c3'"))
        #expect(teamScopedCodex.contains("cmux cr add codex"))
        #expect(teamScopedCodex.contains("CODEROUTER_DATA_DIR=\"$tmp\""))
        let quotedTeam = CoderouterProvider.claude.addCommand(for: "team's-id")
        #expect(quotedTeam.contains("cmux cr org switch 'team'\\''s-id'"))
        #expect(teamScopedCodex.hasPrefix("/bin/sh -c "))
        #expect(!teamScopedCodex.contains("status=0"))
        // The server names OpenCode Go accounts `opencode-go`; the CLI verb is `opencode`.
        #expect(CoderouterProvider(id: "opencode-go") == .opencodeGo)
        #expect(CoderouterProvider.opencodeGo.addCommand == "cmux cr add opencode")
    }

    @Test("Team-scoped add runs in a child shell and cleans its copied config")
    func teamScopedAddCommandIsContained() throws {
        let organizationID = "17a2ba34-5a88-412e-8380-0ea4118139c3"
        for shell in ["/bin/zsh", "/bin/bash"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-coderouter-add-\(UUID().uuidString)")
            let configDirectory = root.appendingPathComponent("coderouter")
            let binDirectory = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try Data("{}\n".utf8).write(to: configDirectory.appendingPathComponent("config.json"))
            let log = root.appendingPathComponent("cmux.log")
            let fakeCmux = binDirectory.appendingPathComponent("cmux")
            try """
            #!/bin/sh
            printf '%s\\n' "$CODEROUTER_DATA_DIR" >> "$CMUX_TEST_LOG"
            printf '%s\\n' "$*" >> "$CMUX_TEST_LOG"
            test -f "$CODEROUTER_DATA_DIR/coderouter/config.json"
            """.write(to: fakeCmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCmux.path)

            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let terminated = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-fc", "\(CoderouterProvider.codex.addCommand(for: organizationID)); printf '%s\\n' sentinel"]
            process.environment = [
                "PATH": "\(binDirectory.path):/usr/bin:/bin",
                "HOME": root.path,
                "CODEROUTER_DATA_DIR": root.path,
                "CMUX_TEST_LOG": log.path,
            ]
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { _ in terminated.signal() }
            try process.run()
            #expect(terminated.wait(timeout: .now() + 5) == .success, "\(shell) timed out")
            if process.isRunning { process.terminate() }

            #expect(process.terminationStatus == 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("sentinel\n"))
            let lines = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            #expect(lines.count == 4)
            #expect(lines[1] == "cr org switch \(organizationID)")
            #expect(lines[3] == "cr add codex")
            #expect(lines[0] == lines[2])
            #expect(!FileManager.default.fileExists(atPath: lines[0] + "/coderouter/config.json"))
        }
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
