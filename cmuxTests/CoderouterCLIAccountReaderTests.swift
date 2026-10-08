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
    /// Current CodeRouter organization IDs are the Stack team UUIDs returned by
    /// the catalog, so the sidebar can issue a team-scoped read directly.
    private static let cmuxTeamID = "17a2ba34-5a88-412e-8380-0ea4118139c3"
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
        #expect(snapshot.supportsTeamOption)
        #expect(snapshot.accounts.map(\.label) == ["austin+10@manaflow.com", "austin+3@manaflow.com"])
    }

    @Test("A successful team mapping is reused without another organization catalog read")
    func knownOrganizationSkipsList() async throws {
        let cli = FakeCoderouterCLI(activeOrganizationID: Self.austinOrganizationID)

        _ = try await CoderouterCLIAccountReader.snapshot(
            for: Self.cmuxTeamID,
            name: "Austin Wang's Team",
            knownOrganizationID: Self.austinOrganizationID,
            run: { try await cli.run($0) }
        )

        #expect(await cli.commands == [["accounts", "--json", "--team", Self.austinOrganizationID]])
    }

    @Test("A valid Stack team UUID wins over a stale legacy organization mapping")
    func validTeamIDWinsOverStaleMapping() async throws {
        let staleOrganizationID = Self.cmuxOrganizationID
        let snapshot = try await CoderouterCLIAccountReader.snapshot(
            for: Self.cmuxTeamID,
            name: "Austin Wang's Team",
            knownOrganizationID: staleOrganizationID,
            run: { arguments in
                #expect(arguments == ["accounts", "--json", "--team", Self.cmuxTeamID])
                return Data("{\"teamId\":\"\(Self.cmuxTeamID)\",\"accounts\":[]}".utf8)
            }
        )

        #expect(snapshot.organizationID == Self.cmuxTeamID)
        #expect(snapshot.supportsTeamOption)
    }

    @Test("Runtime failures do not fall back to organization switching", arguments: [
        "network timeout while reading accounts",
        "coderouter: not signed in; run `coderouter login`",
        "coderouter: list coderouter accounts: HTTP 403",
        "coderouter: list coderouter accounts: HTTP 503",
        "coderouter: usage: coderouter accounts [--watch | --json [--team ID]]"
    ])
    func directReadFailureDoesNotMutateActiveOrganization(message: String) async {
        let commands = CommandRecorder()
        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.snapshot(
                for: Self.cmuxTeamID,
                name: "Austin Wang's Team",
                run: { arguments in
                    await commands.append(arguments)
                    throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: message
                    ])
                }
            )
        }
        #expect(await commands.value == [["accounts", "--json", "--team", Self.cmuxTeamID]])
    }

    @Test("An unsupported team option alone permits the legacy read fallback")
    func unsupportedTeamOptionUsesLegacyFallback() async throws {
        let commands = CommandRecorder()
        let snapshot = try await CoderouterCLIAccountReader.snapshot(
            for: Self.cmuxTeamID,
            name: "Austin Wang's Team",
            run: { arguments in
                await commands.append(arguments)
                switch arguments {
                case _ where arguments.count == 4 && Array(arguments.prefix(3)) == ["accounts", "--json", "--team"]:
                    throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "coderouter: usage: coderouter accounts [--watch | --json]"
                    ])
                case ["accounts", "--json"]:
                    return Data("{\"teamId\":\"\(Self.cmuxTeamID)\",\"accounts\":[]}".utf8)
                case ["org", "switch", Self.cmuxTeamID]:
                    return Data()
                default:
                    throw NSError(domain: "UnexpectedCLICommand", code: 1)
                }
            }
        )

        #expect(snapshot.organizationID == Self.cmuxTeamID)
        #expect(!snapshot.supportsTeamOption)
        #expect(await commands.value == [
            ["accounts", "--json", "--team", Self.cmuxTeamID],
            ["org", "switch", Self.cmuxTeamID],
            ["accounts", "--json"]
        ])
    }

    @Test("An exact team ID wins over an earlier team with the same name")
    func exactIDWinsOverName() async throws {
        let organizationID = Self.austinOrganizationID
        let snapshot = try await CoderouterCLIAccountReader.snapshot(
            for: organizationID, name: "Example",
            run: { arguments in
                switch arguments {
                case ["org", "list"]:
                    return Data("Example\t\(Self.cmuxOrganizationID)\nExample\t\(organizationID)\n".utf8)
                case ["accounts", "--json", "--team", organizationID]:
                    return Data("{\"teamId\":\"\(organizationID)\",\"accounts\":[]}".utf8)
                default:
                    throw NSError(domain: "UnexpectedCLICommand", code: 1)
                }
            }
        )
        #expect(snapshot.organizationID == organizationID)
    }

    @Test("Ambiguous normalized team names cannot select an account destination")
    func ambiguousNamesFailClosed() async {
        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.snapshot(
                for: "legacy-team", name: "Example",
                run: { arguments in
                    #expect(arguments == ["org", "list"])
                    return Data("Example\t\(Self.cmuxOrganizationID)\nExample's Team\t\(Self.austinOrganizationID)\n".utf8)
                }
            )
        }
    }

    @Test("Refresh leaves the terminal's CodeRouter organization alone when it already matches")
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

    @Test("A remove failure does not switch organization or retry unscoped")
    func removeFailureDoesNotMutateActiveOrganization() async {
        let accountID = "a10a7f6a-27b5-4e36-9a71-005d2c0539df"
        let commands = CommandRecorder()
        await #expect(throws: NSError.self) {
            try await CoderouterCLIAccountReader.remove(
                accountID: accountID,
                for: Self.cmuxTeamID,
                name: "Austin Wang's Team",
                run: { arguments in
                    await commands.append(arguments)
                    throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "server returned HTTP 503 while removing account"
                    ])
                }
            )
        }
        #expect(await commands.value == [
            ["remove", accountID, "--yes", "--team", Self.cmuxTeamID]
        ])
    }

    @Test("Canceled direct reads do not run the legacy path")
    func canceledReadDoesNotFallback() async {
        let commands = CommandRecorder()
        await #expect(throws: CancellationError.self) {
            try await CoderouterCLIAccountReader.snapshot(for: Self.cmuxTeamID, name: "Austin Wang") { arguments in
                await commands.append(arguments)
                throw CancellationError()
            }
        }
        #expect(await commands.value == [["accounts", "--json", "--team", Self.cmuxTeamID]])
    }

    @Test("Unsupported removal selects the team before the isolated legacy command")
    func unsupportedRemoveUsesLegacySequence() async throws {
        let commands = CommandRecorder()
        let accountID = "a10a7f6a-27b5-4e36-9a71-005d2c0539df"
        try await CoderouterCLIAccountReader.remove(accountID: accountID, for: Self.cmuxTeamID, name: nil) { arguments in
            await commands.append(arguments)
            if arguments.contains("--team") {
                throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "coderouter: usage: coderouter remove [account-id-or-label] [--yes]"
                ])
            }
            return Data()
        }
        #expect(await commands.value == [
            ["remove", accountID, "--yes", "--team", Self.cmuxTeamID],
            ["org", "switch", Self.cmuxTeamID],
            ["remove", accountID, "--yes"]
        ])
    }

    @Test("Legacy configuration is isolated and removed on success and failure", arguments: [false, true])
    func legacyConfigurationIsIsolated(fails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-coderouter-isolation-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("coderouter/config.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("{\"teamId\":\"terminal-team\"}".utf8)
        try original.write(to: source)
        var isolatedRoot: URL?
        do {
            try await CoderouterCLIAccountReader.withIsolatedConfiguration(environment: ["CODEROUTER_DATA_DIR": root.path]) { environment in
                let destination = URL(fileURLWithPath: try #require(environment["CODEROUTER_DATA_DIR"]))
                isolatedRoot = destination
                #expect(destination != root)
                let privateConfig = destination.appendingPathComponent("coderouter/config.json")
                #expect(try Data(contentsOf: privateConfig) == original)
                try Data("{\"teamId\":\"sidebar-team\"}".utf8).write(to: privateConfig)
                #expect(try Data(contentsOf: source) == original)
                if fails { throw CancellationError() }
            }
            #expect(!fails)
        } catch is CancellationError {
            #expect(fails)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: try #require(isolatedRoot).path))
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
        case _ where arguments.count == 4 && Array(arguments.prefix(3)) == ["accounts", "--json", "--team"]:
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
        #expect(CoderouterProvider.claude.addCommand(for: "team's-id", supportsTeamOption: true) == "cmux cr add claude --team 'team'\\''s-id'")
        #expect(CoderouterProvider.codex.addCommand(for: "team-a", supportsTeamOption: true) == "cmux cr add codex --team 'team-a'")
        // The server names OpenCode Go accounts `opencode-go`; the CLI verb is `opencode`.
        #expect(CoderouterProvider(id: "opencode-go") == .opencodeGo)
        #expect(CoderouterProvider.opencodeGo.addCommand == "cmux cr add opencode")
    }

    @Test("Direct team add uses the pinned CLI even when PATH has no cmux")
    func directTeamAddUsesPinnedCLI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pinned-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("a cli's cmux")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for provider in [CoderouterProvider.codex, .claude] {
            let command = provider.addCommand(
                for: "team's-id", supportsTeamOption: true, cmuxExecutable: executable.path
            )
            let result = try await CoderouterCLIAccountReader.runProcess(
                executable: "/bin/sh",
                arguments: ["-lc", command],
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path]
            )
            #expect(String(decoding: result.stdout, as: UTF8.self) == "cr\nadd\n\(provider.id)\n--team\nteam's-id\n")
        }
    }

    @Test("Team-scoped add preserves the parent shell and shared config")
    func teamScopedAddCommandIsContained() throws {
        let organizationID = "team's-id"
        for shell in ["/bin/zsh", "/bin/bash"] {
            for providerID in ["codex", "claude", "opencode-go"] {
                for switchResult in [0, 7] {
                    let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-coderouter-add-\(UUID().uuidString)")
            let configDirectory = root.appendingPathComponent("coderouter")
            let binDirectory = root.appendingPathComponent("a bin's")
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
            test -f "$CODEROUTER_DATA_DIR/coderouter/config.json" || exit 8
            if [ "$2" = org ]; then
                [ "$4" = "$CMUX_TEST_TEAM" ] || exit 9
                printf '%s' "$4" > "$CODEROUTER_DATA_DIR/coderouter/config.json"
                exit "$CMUX_TEST_SWITCH_RESULT"
            fi
            [ "$(cat "$CODEROUTER_DATA_DIR/coderouter/config.json")" = "$CMUX_TEST_TEAM" ]
            """.write(to: fakeCmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCmux.path)

            let process = Process()
            let output = Pipe()
            let error = Pipe()
            let terminated = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-fc", "\(CoderouterProvider(id: providerID).addCommand(for: organizationID, cmuxExecutable: fakeCmux.path)); printf 'sentinel:%s\\n' \"$?\""]
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": root.path,
                "CODEROUTER_DATA_DIR": root.path,
                "CMUX_TEST_LOG": log.path,
                "CMUX_TEST_TEAM": organizationID,
                "CMUX_TEST_SWITCH_RESULT": String(switchResult),
            ]
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { _ in terminated.signal() }
            try process.run()
            let completed = terminated.wait(timeout: .now() + 5) == .success
            if !completed { process.terminate() }
            try #require(completed, "\(shell) timed out")

            #expect(process.terminationStatus == 0, "\(String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
            #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "sentinel:\(switchResult)\n")
            let lines = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            try #require(lines.count == (switchResult == 0 ? 4 : 2))
            #expect(lines[1] == "cr org switch \(organizationID)")
            if switchResult == 0 {
                let verb = providerID == "opencode-go" ? "opencode" : providerID
                #expect(lines[3] == "cr add \(verb)")
                #expect(lines[0] == lines[2])
            }
            #expect(lines[0] != root.path)
                    #expect(!FileManager.default.fileExists(atPath: lines[0]))
                    #expect(try String(contentsOf: configDirectory.appendingPathComponent("config.json"), encoding: .utf8) == "{}\n")
                }
            }
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
