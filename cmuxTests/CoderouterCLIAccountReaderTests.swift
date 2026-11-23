import AppKit
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
        await #expect(throws: CoderouterCLIFailure.unavailable) {
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
    }

    @Test("A CLI without team-scoped commands reports that it is outdated and never switches orgs")
    func oldCLIIsOutdated() async throws {
        let commands = CommandRecorder()
        await #expect(throws: CoderouterCLIFailure.outdated) {
            try await CoderouterCLIAccountReader.snapshot(
                for: Self.cmuxTeamID,
                name: nil,
                run: { arguments in
                    await commands.append(arguments)
                    // coderouter 0.3.15's reply to `accounts --json --team`.
                    throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "coderouter: usage: coderouter accounts [--watch | --json]",
                    ])
                }
            )
        }
        #expect(await commands.value == [["accounts", "--json", "--team", Self.cmuxTeamID]])
    }

    @Test("CLI errors map to an actionable failure", arguments: [
        ("coderouter: refresh coderouter session: your authorization expired or was revoked; run `coderouter login` and retry [HTTP 401]", CoderouterCLIFailure.signInRequired),
        ("coderouter: not signed in; run `coderouter login`", .signInRequired),
        ("coderouter: list coderouter accounts: your account does not have permission for this team [HTTP 403]", .notMember),
        ("coderouter: organization `17a2ba34-5a88-412e-8380-0ea4118139c3` was not found; run `coderouter org list`", .notMember),
        ("coderouter: hosted coderouter requires cmux Pro or Team; upgrade at https://cmux.com/pricing [HTTP 402]", .planRequired),
        ("coderouter: list coderouter accounts: could not connect; check DNS, your network, and the configured server", .unreachable),
        ("coderouter: list coderouter accounts: coderouter is temporarily unavailable; retry shortly [HTTP 503]", .unreachable),
        ("coderouter: usage: coderouter remove [account-id-or-label] [--yes]", .outdated),
        ("coderouter: something new", .unavailable),
    ])
    func classifiesCLIErrors(stderr: String, expected: CoderouterCLIFailure) {
        let error = NSError(domain: "CoderouterCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: stderr])
        #expect(CoderouterCLIFailure.classify(error) == expected)
        #expect(!expected.message.isEmpty)
    }

    @Test("A failed removal never says accounts didn't load")
    func removalCopyNamesRemoval() async {
        // An invalid ID is rejected before the CLI runs and classifies as unavailable.
        do {
            try await CoderouterCLIAccountReader.remove(
                accountID: "bad id;",
                for: Self.cmuxTeamID,
                name: nil,
                run: { _ in Data() }
            )
            Issue.record("An invalid account ID was accepted")
        } catch {
            #expect(CoderouterCLIFailure.classify(error) == .unavailable)
        }
        for failure in [CoderouterCLIFailure.unavailable, .outdated, .sessionChanging] {
            #expect(failure.removalMessage != failure.message)
        }
        for failure in [CoderouterCLIFailure.notInstalled, .signInRequired, .notMember, .planRequired, .unreachable] {
            #expect(failure.removalMessage == failure.message)
        }

        for failure in [CoderouterCLIFailure.unavailable, .outdated, .sessionChanging] {
            #expect(failure.addMessage != failure.message)
        }
        for failure in [CoderouterCLIFailure.notInstalled, .signInRequired, .notMember, .planRequired, .unreachable] {
            #expect(failure.addMessage == failure.message)
        }
    }

    @Test("Runtime errors do not trigger an unscoped fallback")
    func runtimeFailureDoesNotFallback() async {
        let commands = CommandRecorder()
        await #expect(throws: CoderouterCLIFailure.unreachable) {
            try await CoderouterCLIAccountReader.snapshot(
                for: Self.cmuxTeamID,
                name: nil,
                run: { arguments in
                    await commands.append(arguments)
                    throw NSError(domain: "CoderouterCLI", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "coderouter: list coderouter accounts: coderouter is temporarily unavailable; retry shortly [HTTP 503]",
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
