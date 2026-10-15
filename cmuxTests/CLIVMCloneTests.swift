import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Black-box coverage for `cmux vm clone` / `cmux vm repo clone`: the real CLI binary
/// runs against a mock control socket that plays the app's side of `vm.secrets_sync`,
/// `vm.exec`, `vm.workspace_new`, `vm.terminal_write`, and `surface.new_terminal`. The
/// repository-spec parser (URL forms, `.`, branches, project keys) is exercised through
/// `--dry-run --json`, which computes the plan without opening the socket. CLI-target
/// code is not linked into this bundle (see CLIVMTransferTests), so the static helpers
/// are verified through their observable JSON and command lines.
extension CLINotifyProcessIntegrationRegressionTests {
    private final class VMCloneRequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []

        func append(_ request: [String: Any]) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func snapshot() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        var methods: [String] { snapshot().compactMap { $0["method"] as? String } }

        func params(ofFirst method: String) -> [String: Any]? {
            snapshot().first { ($0["method"] as? String) == method }?["params"] as? [String: Any]
        }
    }

    private func vmCloneEnvironment(socketPath: String, home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // `vm clone` binds the repository to the machine in ~/.cmuxterm; keep that out of
        // the developer's home. The developer's git config (url.insteadOf rewrites) must
        // not change what `.` resolves to.
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        return environment
    }

    private func vmCloneScratch(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-clone-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.cmuxterm"), withIntermediateDirectories: true)
        return root
    }

    /// One CLI run, optionally from `directory` (through `/bin/sh -c 'cd …'`, since the
    /// shared process runner has no working-directory parameter).
    private func runVMCloneCLI(arguments: [String], home: URL, socketPath: String, directory: URL? = nil) throws -> ProcessRunResult {
        let cliPath = try bundledCLIPath()
        let environment = vmCloneEnvironment(socketPath: socketPath, home: home)
        if let directory {
            return runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", "cd \"$1\" && shift && exec \"$@\"", "sh", directory.path, cliPath] + arguments,
                environment: environment,
                timeout: 60
            )
        }
        return runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 60)
    }

    /// `--dry-run --json`: the plan, computed without a socket.
    private func vmCloneDryRunPlan(_ arguments: [String], home: URL, directory: URL? = nil) throws -> (plan: [String: Any], result: ProcessRunResult) {
        let result = try runVMCloneCLI(
            arguments: ["vm", "clone"] + arguments + ["--dry-run", "--json"],
            home: home,
            socketPath: makeSocketPath("vcd"),
            directory: directory
        )
        XCTAssertFalse(result.timedOut, "\(arguments) timed out")
        XCTAssertEqual(result.status, 0, "\(arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
        let plan = result.stdout.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertNotNil(plan, "\(arguments): dry-run did not print a JSON plan: \(result.stdout)")
        return (plan ?? [:], result)
    }

    /// One `cmux vm clone …` against the mock. `respond` returns nil for a method the
    /// app does not know (answered as `method_not_found`).
    private func runVMCloneAgainstMock(
        _ name: String,
        arguments: [String],
        home: URL,
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> [String: Any]?
    ) throws -> (result: ProcessRunResult, log: VMCloneRequestLog) {
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMCloneRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard let result = respond(method, params) else {
                return self.v2Response(id: id, ok: false, error: ["code": "method_not_found", "message": "Unknown method"])
            }
            return self.v2Response(id: id, ok: true, result: result)
        }
        let result = try runVMCloneCLI(arguments: arguments, home: home, socketPath: socketPath)
        wait(for: [handled], timeout: 60)
        XCTAssertFalse(result.timedOut, "\(arguments) timed out: \(result.stderr)")
        return (result, log)
    }

    // MARK: - Repository specs (dry run, no socket)

    func testVMCloneDryRunParsesEveryRepositoryForm() throws {
        struct Case {
            let arguments: [String]
            let url: String
            let name: String
            let owner: String?
            let branch: String?
            let project: String
            let dir: String
        }
        let cases: [Case] = [
            Case(arguments: ["manaflow-ai/cmux"], url: "https://github.com/manaflow-ai/cmux.git", name: "cmux", owner: "manaflow-ai", branch: nil, project: "github.com/manaflow-ai/cmux", dir: "work/cmux"),
            Case(arguments: ["Acme/Api.git"], url: "https://github.com/Acme/Api.git", name: "Api", owner: "Acme", branch: nil, project: "github.com/acme/api", dir: "work/Api"),
            Case(arguments: ["https://github.com/vercel/next.js"], url: "https://github.com/vercel/next.js.git", name: "next.js", owner: "vercel", branch: nil, project: "github.com/vercel/next.js", dir: "work/next.js"),
            Case(arguments: ["https://github.com/vercel/next.js/"], url: "https://github.com/vercel/next.js.git", name: "next.js", owner: "vercel", branch: nil, project: "github.com/vercel/next.js", dir: "work/next.js"),
            Case(arguments: ["https://github.com/vercel/next.js/tree/canary"], url: "https://github.com/vercel/next.js.git", name: "next.js", owner: "vercel", branch: "canary", project: "github.com/vercel/next.js", dir: "work/next.js"),
            Case(arguments: ["https://github.com/o/r/tree/feat/deep-branch"], url: "https://github.com/o/r.git", name: "r", owner: "o", branch: "feat/deep-branch", project: "github.com/o/r", dir: "work/r"),
            Case(arguments: ["https://github.com/o/r/tree/canary", "--branch", "main"], url: "https://github.com/o/r.git", name: "r", owner: "o", branch: "main", project: "github.com/o/r", dir: "work/r"),
            // GitHub over ssh clones over https, so the machine's GH_TOKEN helper applies.
            Case(arguments: ["git@github.com:acme/api.git"], url: "https://github.com/acme/api.git", name: "api", owner: "acme", branch: nil, project: "github.com/acme/api", dir: "work/api"),
            Case(arguments: ["ssh://git@github.com/acme/api.git"], url: "https://github.com/acme/api.git", name: "api", owner: "acme", branch: nil, project: "github.com/acme/api", dir: "work/api"),
            // Any other host clones exactly what was given.
            Case(arguments: ["https://gitlab.com/group/sub/proj.git"], url: "https://gitlab.com/group/sub/proj.git", name: "proj", owner: "group/sub", branch: nil, project: "gitlab.com/group/sub/proj", dir: "work/proj"),
            Case(arguments: ["git@git.example.com:team/svc.git", "--branch", "release/1.2"], url: "git@git.example.com:team/svc.git", name: "svc", owner: "team", branch: "release/1.2", project: "git.example.com/team/svc", dir: "work/svc"),
            Case(arguments: ["o/r", "--dir", "~/src/r/"], url: "https://github.com/o/r.git", name: "r", owner: "o", branch: nil, project: "github.com/o/r", dir: "src/r"),
            Case(arguments: ["o/r", "--dir", "/srv/app"], url: "https://github.com/o/r.git", name: "r", owner: "o", branch: nil, project: "github.com/o/r", dir: "/srv/app"),
        ]
        let root = try vmCloneScratch("forms")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        for testCase in cases {
            let label = testCase.arguments.joined(separator: " ")
            let (plan, _) = try vmCloneDryRunPlan(testCase.arguments, home: home)
            XCTAssertEqual(plan["dry_run"] as? Bool, true, label)
            let repo = try XCTUnwrap(plan["repo"] as? [String: Any], label)
            XCTAssertEqual(repo["url"] as? String, testCase.url, label)
            XCTAssertEqual(repo["name"] as? String, testCase.name, label)
            XCTAssertEqual(repo["owner"] as? String, testCase.owner, label)
            XCTAssertEqual(repo["project"] as? String, testCase.project, label)
            if let branch = testCase.branch {
                XCTAssertEqual(repo["branch"] as? String, branch, label)
            } else {
                XCTAssertTrue(repo["branch"] is NSNull, "\(label): expected the default branch, got \(String(describing: repo["branch"]))")
            }
            XCTAssertEqual(plan["dir"] as? String, testCase.dir, label)
            XCTAssertEqual(plan["workspace_name"] as? String, testCase.name, label)
        }
    }

    func testVMCloneDryRunAgentPlanUsesTheOneShotForm() throws {
        let root = try vmCloneScratch("agent")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (oneShot, _) = try vmCloneDryRunPlan(["o/r", "--agent", "claude", "--", "fix", "the", "tests"], home: home)
        XCTAssertEqual(oneShot["agent"] as? String, "claude")
        XCTAssertEqual(oneShot["agent_command"] as? [String], ["claude", "-p", "fix the tests"])
        let (interactive, _) = try vmCloneDryRunPlan(["o/r", "--agent", "codex", "--no-open"], home: home)
        XCTAssertEqual(interactive["agent_command"] as? [String], ["codex"])
        XCTAssertEqual(interactive["open"] as? Bool, false)
    }

    func testVMCloneDotResolvesOriginAndTrackedBranch() throws {
        let root = try vmCloneScratch("dot")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let repo = root.appendingPathComponent("widget", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let gitEnvironment = vmCloneEnvironment(socketPath: "/dev/null", home: home)
        func git(_ arguments: [String]) {
            let result = runProcess(
                executablePath: "/usr/bin/env",
                arguments: ["git", "-C", repo.path, "-c", "user.name=cmux", "-c", "user.email=cmux@example.invalid"] + arguments,
                environment: gitEnvironment,
                timeout: 30
            )
            XCTAssertEqual(result.status, 0, "git \(arguments): \(result.stderr)")
        }
        git(["init", "-q"])
        git(["remote", "add", "origin", "git@github.com:Acme/Widget.git"])
        git(["commit", "-q", "--allow-empty", "-m", "init"])
        git(["checkout", "-q", "-b", "feature/login"])
        git(["update-ref", "refs/remotes/origin/feature/login", "HEAD"])
        git(["branch", "--set-upstream-to=origin/feature/login"])

        let (tracked, _) = try vmCloneDryRunPlan(["."], home: home, directory: repo)
        let trackedRepo = try XCTUnwrap(tracked["repo"] as? [String: Any])
        XCTAssertEqual(trackedRepo["url"] as? String, "https://github.com/Acme/Widget.git")
        XCTAssertEqual(trackedRepo["project"] as? String, "github.com/acme/widget")
        XCTAssertEqual(trackedRepo["branch"] as? String, "feature/login")
        XCTAssertEqual(tracked["dir"] as? String, "work/Widget")

        // A branch origin does not have: the default branch, with a note saying why.
        git(["checkout", "-q", "-b", "local-only"])
        let (untracked, untrackedResult) = try vmCloneDryRunPlan(["."], home: home, directory: repo)
        let untrackedRepo = try XCTUnwrap(untracked["repo"] as? [String: Any])
        XCTAssertTrue(untrackedRepo["branch"] is NSNull, "\(String(describing: untrackedRepo["branch"]))")
        XCTAssertTrue(untrackedResult.stderr.contains("local-only"), untrackedResult.stderr)
        XCTAssertTrue(untrackedResult.stderr.contains("git push -u origin local-only"), untrackedResult.stderr)

        // An explicit --branch wins over the tracked one.
        let (overridden, _) = try vmCloneDryRunPlan([".", "--branch", "main"], home: home, directory: repo)
        XCTAssertEqual((overridden["repo"] as? [String: Any])?["branch"] as? String, "main")
    }

    func testVMCloneRejectsBadInputBeforeTheSocket() throws {
        let root = try vmCloneScratch("bad")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let notARepo = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        // The socket path does not exist: reaching it would fail with a connection error
        // instead of the message under test.
        let missingSocket = root.appendingPathComponent("absent.sock").path
        let cases: [(arguments: [String], directory: URL?, expected: String)] = [
            (["https://ghp_secret@github.com/o/r"], nil, "carries credentials"),
            (["https://user:pass@gitlab.com/o/r.git"], nil, "carries credentials"),
            (["not a repo"], nil, "is not a repository"),
            (["ftp://example.com/r.git"], nil, "is not a repository"),
            (["o/r", "--branch", "bad..branch"], nil, "is not a valid branch name"),
            (["o/r", "--dir", "../escape"], nil, "is not a usable directory"),
            (["o/r", "--machine", "brave-otter", "--new"], nil, "--machine and --new are exclusive"),
            (["o/r", "--agent", "vim"], nil, "--agent must be one of"),
            (["o/r", "--", "a prompt"], nil, "needs --agent"),
            (["o/r", "--size", "huge"], nil, "unknown size"),
            (["o/r", "--bogus"], nil, "unknown flag '--bogus'"),
            (["."], notARepo, "is not a git checkout with an origin remote"),
        ]
        for testCase in cases {
            let label = testCase.arguments.joined(separator: " ")
            let result = try runVMCloneCLI(
                arguments: ["vm", "clone"] + testCase.arguments,
                home: home,
                socketPath: missingSocket,
                directory: testCase.directory
            )
            XCTAssertFalse(result.timedOut, label)
            XCTAssertNotEqual(result.status, 0, "\(label): stdout=\(result.stdout)")
            XCTAssertTrue(result.stderr.contains(testCase.expected), "\(label): expected '\(testCase.expected)' in:\n\(result.stderr)")
            XCTAssertFalse(result.stderr.contains("ghp_secret"), "\(label): the credential must not be echoed")
        }
    }

    func testVMCloneHelpPrintsItsUsageWithoutASocket() throws {
        let root = try vmCloneScratch("help")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        for arguments in [["vm", "clone", "--help"], ["vm", "clone", "-h"], ["vm", "repo", "clone", "--help"], ["vm", "repo", "--help"]] {
            let result = try runVMCloneCLI(arguments: arguments, home: home, socketPath: makeSocketPath("vch"))
            XCTAssertFalse(result.timedOut, "\(arguments) timed out")
            XCTAssertEqual(result.status, 0, "\(arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
            for expected in ["Usage: cmux vm clone <repo>", "cmux vm repo clone", "--branch", "cmux vm secrets import --gh"] {
                XCTAssertTrue(result.stdout.contains(expected), "\(arguments) should mention '\(expected)':\n\(result.stdout)")
            }
        }
    }

    // MARK: - The socket sequence

    func testVMCloneClonesOpensAWorkspaceAndStartsTheAgent() throws {
        let root = try vmCloneScratch("full")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, log) = try runVMCloneAgainstMock(
            "vcf",
            arguments: ["vm", "repo", "clone", "git@github.com:acme/api.git", "--machine", "brave-otter", "--branch", "main", "--no-open", "--json", "--agent", "claude", "--", "fix", "it"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return ["machine": "brave-otter", "sent": ["GH_TOKEN"], "removed": [], "noop": false]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": "Cloning into 'work/api'...\n"]
            case "vm.workspace_new": return ["machine": "brave-otter", "remote_workspace_id": "ws_9", "existing": false, "opened": false, "terminal_id": "term_starter"]
            case "vm.terminal_write": return ["wrote": 20]
            case "surface.new_terminal": return ["terminal_id": "term_agent", "remote_workspace_id": "ws_9"]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        // --machine pins the machine: no routing traffic, secrets before git.
        XCTAssertEqual(
            log.methods,
            ["vm.secrets_sync", "vm.exec", "vm.workspace_new", "vm.terminal_write", "surface.new_terminal"],
            log.methods.description
        )
        let secrets = try XCTUnwrap(log.params(ofFirst: "vm.secrets_sync"))
        XCTAssertEqual(secrets["id"] as? String, "brave-otter")
        XCTAssertEqual(secrets["project"] as? String, "github.com/acme/api")

        let exec = try XCTUnwrap(log.params(ofFirst: "vm.exec"))
        let command = try XCTUnwrap(exec["command"] as? String)
        XCTAssertTrue(command.contains("git clone --branch main -- \"$u\" \"$d\""), command)
        XCTAssertTrue(command.contains("u=https://github.com/acme/api.git") || command.contains("u='https://github.com/acme/api.git'"), command)
        XCTAssertTrue(command.contains("GIT_TERMINAL_PROMPT=0"), "a missing credential must fail, not prompt: \(command)")
        XCTAssertFalse(command.contains("GH_TOKEN"), "no credential in the command: \(command)")
        XCTAssertEqual(exec["timeout_ms"] as? Int, 900_000)

        let workspace = try XCTUnwrap(log.params(ofFirst: "vm.workspace_new"))
        XCTAssertEqual(workspace["name"] as? String, "api")
        XCTAssertEqual(workspace["reuse"] as? Bool, true)
        XCTAssertEqual(workspace["open"] as? Bool, false)

        let write = try XCTUnwrap(log.params(ofFirst: "vm.terminal_write"))
        XCTAssertEqual(write["terminal_id"] as? String, "term_starter")
        let cd = try XCTUnwrap(write["text"] as? String)
        XCTAssertTrue(cd.hasPrefix("cd \"$HOME\"/"), cd)
        XCTAssertTrue(cd.contains("work/api"), cd)
        XCTAssertEqual(write["keys"] as? [String], ["enter"])

        let agent = try XCTUnwrap(log.params(ofFirst: "surface.new_terminal"))
        XCTAssertEqual(agent["machine"] as? String, "brave-otter")
        XCTAssertEqual(agent["remote_workspace_id"] as? String, "ws_9")
        XCTAssertEqual(agent["open"] as? Bool, false)
        let agentCommand = try XCTUnwrap(agent["command"] as? [String])
        XCTAssertEqual(agentCommand.prefix(2), ["bash", "-lc"])
        XCTAssertTrue(agentCommand.last?.contains("work/api") == true, agentCommand.description)
        XCTAssertTrue(agentCommand.last?.contains("exec claude -p 'fix it'") == true, agentCommand.description)

        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual(payload["machine"] as? String, "brave-otter")
        XCTAssertEqual(payload["result"] as? String, "cloned")
        XCTAssertEqual(payload["dir"] as? String, "work/api")
        XCTAssertEqual(payload["workspace_id"] as? String, "ws_9")
        XCTAssertEqual(payload["agent_terminal_id"] as? String, "term_agent")
        XCTAssertEqual(payload["secrets_synced"] as? Bool, true)
        XCTAssertEqual(payload["open"] as? String, "cmux vm open brave-otter/ws_9")
        let timings = try XCTUnwrap(payload["timings"] as? [String: Any])
        XCTAssertEqual(Set(timings.keys), ["machine", "secrets", "clone", "workspace", "agent"])
        // One progress line per phase on stderr.
        for phase in ["Machine", "Secrets", "Clone", "Workspace", "Agent"] {
            XCTAssertTrue(result.stderr.contains("[cmux vm clone] \(phase) "), "missing \(phase) progress in:\n\(result.stderr)")
        }
        XCTAssertFalse(result.stderr.contains("cmux vm secrets import --gh"), "no tip after a successful sync: \(result.stderr)")
    }

    func testVMCloneReusesAnExistingCheckoutAndWorkspace() throws {
        let root = try vmCloneScratch("again")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, log) = try runVMCloneAgainstMock(
            "vcu",
            arguments: ["vm", "clone", "o/r", "--machine", "brave-otter", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return ["machine": "brave-otter", "sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=updated\n", "stderr": ""]
            case "vm.workspace_new": return ["machine": "brave-otter", "remote_workspace_id": "ws_3", "existing": true, "opened": false]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        // The existing workspace keeps its terminals: nothing is typed into them.
        XCTAssertEqual(log.methods, ["vm.secrets_sync", "vm.exec", "vm.workspace_new"], log.methods.description)
        let command = try XCTUnwrap(log.params(ofFirst: "vm.exec")?["command"] as? String)
        XCTAssertTrue(command.contains("fetch --prune origin"), "an existing checkout is fetched: \(command)")
        XCTAssertTrue(command.contains("k=github.com/o/r") || command.contains("k='github.com/o/r'"), command)
        XCTAssertTrue(result.stdout.contains("Updated github.com/o/r in work/r on brave-otter."), result.stdout)
        XCTAssertTrue(result.stdout.contains("Open: cmux vm open brave-otter/ws_3"), result.stdout)
        XCTAssertTrue(result.stderr.contains("Machine") && result.stderr.contains(" \u{00B7} Secrets"), "summary line: \(result.stderr)")
    }

    func testVMCloneExplainsAuthFailuresAndMissingSecrets() throws {
        let root = try vmCloneScratch("auth")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, log) = try runVMCloneAgainstMock(
            "vca",
            arguments: ["vm", "clone", "https://github.com/acme/private", "--machine", "brave-otter", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            // An app without Cloud Secrets: `vm.secrets_sync` is unknown (nil → method_not_found).
            case "vm.exec":
                return [
                    "exit_code": 128,
                    "stdout": "",
                    "stderr": "Cloning into 'work/private'...\nfatal: could not read Username for 'https://github.com': terminal prompts disabled\n",
                ]
            default: return nil
            }
        }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(log.methods, ["vm.secrets_sync", "vm.exec"], "nothing is opened after a failed clone: \(log.methods)")
        XCTAssertTrue(
            result.stderr.contains("Tip: add a GitHub token with `cmux vm secrets import --gh` to clone private repos."),
            result.stderr
        )
        XCTAssertTrue(result.stderr.contains("could not read https://github.com/acme/private.git"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm secrets import --gh`, then run this again"), result.stderr)
    }

    func testVMCloneRefusesADirectoryHoldingSomethingElse() throws {
        let root = try vmCloneScratch("conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, log) = try runVMCloneAgainstMock(
            "vcc",
            arguments: ["vm", "clone", "o/r", "--machine", "brave-otter", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return ["machine": "brave-otter", "sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 3, "stdout": "", "stderr": "cmux-clone-conflict: a checkout of github.com/other/r\n"]
            default: return nil
            }
        }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(log.methods, ["vm.secrets_sync", "vm.exec"], log.methods.description)
        XCTAssertTrue(result.stderr.contains("work/r on brave-otter already holds a checkout of github.com/other/r"), result.stderr)
        XCTAssertTrue(result.stderr.contains("--dir"), result.stderr)
    }
}
