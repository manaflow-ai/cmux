import AppKit
import Bonsplit
import CmuxAuthRuntime
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs the sidebar's CodeRouter commands through real child processes: a fake
/// `coderouter` script reports the configuration and environment it was given.
@Suite("CodeRouter app-session CLI")
struct CoderouterAppCLISessionTests {
    private static let teamA = "17a2ba34-5a88-412e-8380-0ea4118139c3"
    private static let teamB = "d13acd51-c77d-438a-9610-5369455e2a2f"
    private static let endpoints = CoderouterCLIEndpoints(
        apiURL: "https://coderouter.example",
        stackAPIURL: "https://signin.example/api/v1",
        stackProjectID: "project-1"
    )

    /// A scratch directory holding the fake CLI, a session root and the
    /// user's own `cr login` configuration.
    private struct Fixture {
        let directory: URL
        let executable: String
        let sessionRoot: URL
        let userDataDirectory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-coderouter-tests-\(UUID().uuidString)", isDirectory: true)
            sessionRoot = directory.appendingPathComponent("sessions", isDirectory: true)
            userDataDirectory = directory.appendingPathComponent("user", isDirectory: true)
            let userConfig = userDataDirectory.appendingPathComponent("coderouter", isDirectory: true)
            try FileManager.default.createDirectory(at: userConfig, withIntermediateDirectories: true)
            // The terminal's own sign-in: another user, another team.
            try Data(#"{"stackAccessToken":"user-access","teamId":"other-team"}"#.utf8)
                .write(to: userConfig.appendingPathComponent("config.json"))
            let script = directory.appendingPathComponent("coderouter")
            // Prints the config it would use, its arguments and the overrides
            // that would replace the app session.
            try Data("""
                #!/bin/sh
                printf '{"args":"%s","apiKey":"%s","teamPin":"%s","stackURL":"%s","dataDir":"%s","config":' "$*" "${CODEROUTER_API_KEY-unset}" "${CODEROUTER_TEAM_ID-unset}" "${CODEROUTER_STACK_API_URL-unset}" "$CODEROUTER_DATA_DIR"
                cat "$CODEROUTER_DATA_DIR/coderouter/config.json"
                printf '}'

                """.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            executable = script.path
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        /// The app's launch environment, carrying overrides the sidebar must drop.
        var environment: [String: String] {
            [
                "PATH": "/usr/bin:/bin",
                "HOME": directory.path,
                "CODEROUTER_DATA_DIR": userDataDirectory.path,
                "CODEROUTER_API_KEY": "crk_user",
                "CODEROUTER_TEAM_ID": "other-team",
                "CODEROUTER_STACK_API_URL": "https://other-signin.example",
                "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            ]
        }
    }

    private struct Report: Decodable {
        let args: String
        let apiKey: String
        let teamPin: String
        let stackURL: String
        let dataDir: String
        let config: [String: String]
    }

    private actor Credentials: CoderouterAppCredentialProviding {
        var accountID = "user-1"
        var requests = 0

        func signIn(as accountID: String) { self.accountID = accountID }

        func credentials(expectedAccountID: String?) async throws -> CoderouterAppCredentials {
            requests += 1
            if let expectedAccountID, expectedAccountID != accountID {
                throw CoderouterCLIFailure.unavailable
            }
            return CoderouterAppCredentials(
                accountID: accountID,
                accessToken: "\(accountID)-access",
                refreshToken: "\(accountID)-refresh"
            )
        }
    }

    private func session(
        credentials: any CoderouterAppCredentialProviding,
        executable: String?,
        fixture: Fixture,
        commandTimeout: TimeInterval = CoderouterAppCLISession.defaultCommandTimeout
    ) -> CoderouterAppCLISession {
        CoderouterAppCLISession(
            credentials: credentials,
            executable: executable,
            endpoints: Self.endpoints,
            environment: fixture.environment,
            baseDirectory: fixture.sessionRoot,
            commandTimeout: commandTimeout
        )
    }

    private func read(
        team: String,
        expectedAccountID: String? = "user-1",
        credentials: Credentials,
        fixture: Fixture
    ) async throws -> Report {
        let output = try await session(credentials: credentials, executable: fixture.executable, fixture: fixture).withSession(
            teamID: team,
            teamName: "Team",
            expectedAccountID: expectedAccountID
        ) { run in
            try await run(["accounts", "--json", "--team", team])
        }
        return try JSONDecoder().decode(Report.self, from: output)
    }

    @Test("Commands run as the app's account, never the CLI's own sign-in")
    func usesAppSessionNotUserConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let report = try await read(team: Self.teamA, credentials: Credentials(), fixture: fixture)

        #expect(report.args == "accounts --json --team \(Self.teamA)")
        #expect(report.config["stackAccessToken"] == "user-1-access")
        #expect(report.config["stackRefreshToken"] == "user-1-refresh")
        #expect(report.config["teamId"] == Self.teamA)
        #expect(report.config["apiUrl"] == "https://coderouter.example")
        #expect(report.config["stackApiUrl"] == "https://signin.example/api/v1")
        #expect(report.config["stackProjectId"] == "project-1")
        #expect(report.dataDir != fixture.userDataDirectory.path)
        #expect(report.dataDir.hasPrefix(fixture.sessionRoot.path))
        // An inherited API key or team pin would replace the app session.
        #expect(report.apiKey == "unset")
        #expect(report.teamPin == "unset")
        #expect(report.stackURL == "unset")
        // The private configuration is gone; the user's is untouched.
        #expect(!FileManager.default.fileExists(atPath: report.dataDir))
        let userConfig = try String(contentsOf: fixture.userDataDirectory.appendingPathComponent("coderouter/config.json"), encoding: .utf8)
        #expect(userConfig.contains("user-access"))
    }

    @Test("Switching team or account re-scopes the next command")
    func teamAndAccountSwitchRescope() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credentials = Credentials()

        let first = try await read(team: Self.teamA, credentials: credentials, fixture: fixture)
        let second = try await read(team: Self.teamB, credentials: credentials, fixture: fixture)
        await credentials.signIn(as: "user-2")
        let third = try await read(team: Self.teamB, expectedAccountID: "user-2", credentials: credentials, fixture: fixture)

        #expect(first.config["teamId"] == Self.teamA)
        #expect(second.config["teamId"] == Self.teamB)
        #expect(third.config["stackAccessToken"] == "user-2-access")
        #expect(Set([first.dataDir, second.dataDir, third.dataDir]).count == 3)
    }

    @Test("A read for an account that is no longer signed in never runs the CLI")
    func mismatchedAccountDoesNotRun() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credentials = Credentials()
        await credentials.signIn(as: "user-2")

        await #expect(throws: CoderouterCLIFailure.unavailable) {
            _ = try await read(team: Self.teamA, expectedAccountID: "user-1", credentials: credentials, fixture: fixture)
        }
        let reads = CoderouterAppCLISession.readSession.root(in: fixture.sessionRoot)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: reads.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("A missing CLI is reported before any session is captured")
    func missingCLIIsNotInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credentials = Credentials()

        await #expect(throws: CoderouterCLIFailure.notInstalled) {
            try await session(credentials: credentials, executable: nil, fixture: fixture).withSession(
                teamID: Self.teamA, teamName: nil, expectedAccountID: nil
            ) { run in try await run(["accounts", "--json"]) }
        }
        #expect(await credentials.requests == 0)

        // A resolved CLI that disappeared before launch is also not installed.
        await #expect(throws: CoderouterCLIFailure.notInstalled) {
            try await session(
                credentials: credentials,
                executable: fixture.directory.appendingPathComponent("missing").path,
                fixture: fixture
            ).withSession(teamID: Self.teamA, teamName: nil, expectedAccountID: nil) { run in
                try await run(["accounts", "--json"])
            }
        }
    }

    @Test("The sidebar reads accounts end to end through the app session")
    func readerRunsThroughSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let script = fixture.directory.appendingPathComponent("accounts-cli")
        try Data("""
            #!/bin/sh
            team=$(sed -n 's/.*"teamId":"\\([^"]*\\)".*/\\1/p' "$CODEROUTER_DATA_DIR/coderouter/config.json")
            [ "$4" = "$team" ] || { echo "coderouter: organization \\`$4\\` was not found; run \\`coderouter org list\\`" >&2; exit 1; }
            printf '{"teamId":"%s","accounts":[{"id":"a1","provider":"codex","label":"me@example.com","state":"active"}]}' "$team"

            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let reader = session(credentials: Credentials(), executable: script.path, fixture: fixture)
        let snapshot = try await reader.withSession(teamID: Self.teamA, teamName: nil, expectedAccountID: "user-1") { run in
            try await CoderouterCLIAccountReader.snapshot(for: Self.teamA, name: nil, run: run)
        }
        #expect(snapshot.organizationID == Self.teamA)
        #expect(snapshot.accounts.map(\.label) == ["me@example.com"])

        // The CLI's "not found" for a team the account cannot see is actionable.
        await #expect(throws: CoderouterCLIFailure.notMember) {
            try await reader.withSession(teamID: Self.teamA, teamName: nil, expectedAccountID: "user-1") { run in
                try await CoderouterCLIAccountReader.snapshot(for: Self.teamB, name: nil, run: run)
            }
        }
    }

    @Test("New Account runs the CLI's add as the app session and removes it on exit")
    func addAccountCommandUsesSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let adder = session(credentials: Credentials(), executable: fixture.executable, fixture: fixture)
        let directory = try adder.makeSessionDirectory(
            kind: CoderouterAppCLISession.addSession,
            credentials: CoderouterAppCredentials(accountID: "user-1", accessToken: "user-1-access", refreshToken: "user-1-refresh"),
            teamID: Self.teamA,
            teamName: nil
        )
        #expect(directory.path.hasPrefix(CoderouterAppCLISession.addSession.root(in: fixture.sessionRoot).path))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("coderouter/config.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let command = try adder.addAccountCommand(
            provider: .opencodeGo,
            organizationID: "team's-id",
            sessionDirectory: directory
        )
        // Run it the way the setup terminal does, with a login profile's overrides.
        let output = try await CoderouterCLIAccountReader.runProcess(
            executable: "/bin/sh",
            arguments: ["-c", command],
            environment: fixture.environment
        ).stdout
        let report = try JSONDecoder().decode(Report.self, from: output)

        #expect(report.args == "add opencode --team team's-id")
        #expect(report.dataDir == directory.path)
        #expect(report.config["stackAccessToken"] == "user-1-access")
        // The same rule as background reads: no CodeRouter override survives.
        #expect(report.apiKey == "unset")
        #expect(report.teamPin == "unset")
        #expect(report.stackURL == "unset")
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // Without a CLI there is no command to run.
        #expect(throws: CoderouterCLIFailure.notInstalled) {
            _ = try session(credentials: Credentials(), executable: nil, fixture: fixture)
                .addAccountCommand(provider: .codex, organizationID: Self.teamA, sessionDirectory: directory)
        }
    }

    @Test("A command that hangs is stopped and reported unreachable")
    func hungCommandTimesOut() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let script = fixture.directory.appendingPathComponent("hung-cli")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let reader = session(credentials: Credentials(), executable: script.path, fixture: fixture, commandTimeout: 0.2)

        await #expect(throws: CoderouterCLIFailure.unreachable) {
            try await reader.withSession(teamID: Self.teamA, teamName: nil, expectedAccountID: "user-1") { run in
                try await run(["accounts", "--json", "--team", Self.teamA])
            }
        }
        let reads = CoderouterAppCLISession.readSession.root(in: fixture.sessionRoot)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: reads.path)) ?? []).isEmpty)
        // No sweep can remove a configuration while its command may still run.
        #expect(CoderouterAppCLISession.defaultCommandTimeout < CoderouterAppCLISession.readSession.staleAge)
    }

    @Test("Stale session directories are swept at each kind's age; fresh ones stay")
    func sweepsStaleSessions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credentials = CoderouterAppCredentials(accountID: "u", accessToken: "a", refreshToken: "r")
        let maker = session(credentials: Credentials(), executable: fixture.executable, fixture: fixture)
        func make(_ kind: CoderouterAppCLISession.SessionKind, age: TimeInterval, owner: pid_t? = nil) throws -> URL {
            let directory = try maker.makeSessionDirectory(kind: kind, credentials: credentials, teamID: Self.teamA, teamName: nil)
            if let owner {
                try Data("\(owner)\n".utf8).write(to: directory.appendingPathComponent(CoderouterAppCLISession.ownerFileName))
            }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: directory.path)
            return directory
        }
        let read = CoderouterAppCLISession.readSession
        let add = CoderouterAppCLISession.addSession
        let crashedRead = try make(read, age: read.staleAge + 60)
        let runningAdd = try make(add, age: read.staleAge + 60)
        let killedAdd = try make(add, age: add.staleAge + 60)
        // A sign-in left open for more than a day is still in use.
        let longAdd = try make(add, age: add.staleAge + 60, owner: getpid())
        let deadOwnerAdd = try make(add, age: add.staleAge + 60, owner: pid_t.max)

        CoderouterAppCLISession.sweepAllStaleSessions(base: fixture.sessionRoot)

        #expect(!FileManager.default.fileExists(atPath: crashedRead.path))
        #expect(FileManager.default.fileExists(atPath: runningAdd.path))
        #expect(!FileManager.default.fileExists(atPath: killedAdd.path))
        #expect(FileManager.default.fileExists(atPath: longAdd.path))
        #expect(!FileManager.default.fileExists(atPath: deadOwnerAdd.path))
    }
}

@Suite("CodeRouter app credentials")
struct CoderouterAppCredentialSourceTests {
    private actor Auth: CoderouterAppSessionAuth {
        var failure: AuthError?
        var accountID = "user-1"
        var current = true
        var cancelled = false

        func configure(failure: AuthError? = nil, accountID: String = "user-1", current: Bool = true, cancelled: Bool = false) {
            self.cancelled = cancelled
            self.failure = failure
            self.accountID = accountID
            self.current = current
        }

        func authenticatedSessionSnapshot() async throws -> AuthenticatedSessionSnapshot {
            if let failure { throw failure }
            return AuthenticatedSessionSnapshot(generation: 1, accountID: accountID, accessToken: "access", refreshToken: "refresh")
        }

        func isAuthenticatedSessionCurrent(_ snapshot: AuthenticatedSessionSnapshot) async -> Bool { current }
        /// The app's resolver refreshes a stale stored token before handing it over.
        func coherentTokenPair() async throws -> (accessToken: String, refreshToken: String) {
            // A team switch cancels the read while the token is resolving.
            if cancelled { throw CancellationError() }
            return ("fresh-access", "refresh")
        }
    }

    @Test("The app's session is handed over only for the expected, current account")
    func credentialRules() async throws {
        let auth = Auth()
        let source = CoderouterAppCredentialSource(auth: auth)

        let credentials = try await source.credentials(expectedAccountID: "user-1")
        #expect(credentials.accessToken == "fresh-access")
        #expect(credentials.refreshToken == "refresh")
        #expect(!String(describing: credentials).contains("fresh-access"))

        await auth.configure(accountID: "user-2")
        await #expect(throws: CoderouterCLIFailure.unavailable) {
            _ = try await source.credentials(expectedAccountID: "user-1")
        }
        await auth.configure(current: false)
        await #expect(throws: CoderouterCLIFailure.sessionChanging) {
            _ = try await source.credentials(expectedAccountID: "user-1")
        }
        await auth.configure(cancelled: true)
        await #expect(throws: CancellationError.self) {
            _ = try await source.credentials(expectedAccountID: "user-1")
        }
        await auth.configure(failure: .unauthorized)
        await #expect(throws: CoderouterCLIFailure.signInRequired) {
            _ = try await source.credentials(expectedAccountID: "user-1")
        }
        await auth.configure(failure: .offline)
        await #expect(throws: CoderouterCLIFailure.unreachable) {
            _ = try await source.credentials(expectedAccountID: "user-1")
        }
    }
}

@MainActor
@Suite("CodeRouter sidebar failure row")
struct CoderouterFailureRowTests {
    @Test("A failed read leads the section with a retry row naming the problem")
    func failureRowRetries() throws {
        let section = CloudTreeCoderouterSection(accounts: [], isRefreshing: false, failure: .notMember)
        let root = try #require(CloudTreeCreateActionBuilder.add(to: [CloudTreeNodeBuilder.coderouterNode(section)]).first)

        let first = try #require(root.children.first)
        #expect(first.kind == .createAction(.retryCoderouter(.notMember)))
        #expect(first.searchableTitle == CoderouterCLIFailure.notMember.message)
        #expect(root.children.dropFirst().map(\.searchableTitle) == ["Codex", "Claude", "OpenCode"])

        final class Refreshed { var count = 0 }
        let refreshed = Refreshed()
        var actions = CloudTreeNodeActions(
            project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {}
        )
        actions.refreshCoderouter = { refreshed.count += 1 }
        CloudTreeCreateAction.retryCoderouter(.notMember).perform(actions)
        #expect(refreshed.count == 1)

        let healthy = try #require(CloudTreeNodeBuilder.coderouterNode(CloudTreeCoderouterSection()).children.first)
        #expect(healthy.kind == .coderouterProviderGroup(.codex, count: 0))
    }
}
