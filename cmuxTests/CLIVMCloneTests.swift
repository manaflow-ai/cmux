import CryptoKit
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
        // A setup follow without wait methods polls the output; keep that quick here.
        environment["CMUX_VM_CLONE_SETUP_POLL_SECONDS"] = "0.05"
        environment.removeValue(forKey: "CMUX_DEBUG")
        return environment
    }

    private func vmCloneScratch(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-clone-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.cmuxterm"), withIntermediateDirectories: true)
        return root
    }

    /// One CLI run, optionally from `directory` (through `/bin/sh -c 'cd …'`, since the
    /// shared process runner has no working-directory parameter). `terminalInput` runs
    /// it under `script(1)`, so stdin and stderr are a terminal (the setup prompt asks
    /// there) and this text is typed into it; both streams then arrive on stdout.
    private func runVMCloneCLI(arguments: [String], home: URL, socketPath: String, directory: URL? = nil, terminalInput: String? = nil) throws -> ProcessRunResult {
        let cliPath = try bundledCLIPath()
        let environment = vmCloneEnvironment(socketPath: socketPath, home: home)
        if let terminalInput {
            return runProcess(
                executablePath: "/usr/bin/script",
                arguments: ["-q", "/dev/null", cliPath] + arguments,
                environment: environment,
                standardInput: terminalInput,
                timeout: 60
            )
        }
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
        var invocation = arguments
        // The agent prompt follows `--`, so options appended after it would be
        // treated as prompt words instead of clone flags.
        if let separator = invocation.firstIndex(of: "--") {
            invocation.insert(contentsOf: ["--dry-run", "--json"], at: separator)
        } else {
            invocation += ["--dry-run", "--json"]
        }
        let result = try runVMCloneCLI(
            arguments: ["vm", "clone"] + invocation,
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
        terminalInput: String? = nil,
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
        let result = try runVMCloneCLI(arguments: arguments, home: home, socketPath: socketPath, terminalInput: terminalInput)
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
            /// The workspace name when the checkout is not the default `work/<name>`.
            var workspace: String? = nil
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
            Case(arguments: ["o/r", "--dir", "~/src/r/"], url: "https://github.com/o/r.git", name: "r", owner: "o", branch: nil, project: "github.com/o/r", dir: "src/r", workspace: "r (src/r)"),
            Case(arguments: ["o/r", "--dir", "/srv/app"], url: "https://github.com/o/r.git", name: "r", owner: "o", branch: nil, project: "github.com/o/r", dir: "/srv/app", workspace: "r (app)"),
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
            XCTAssertEqual(plan["workspace_name"] as? String, testCase.workspace ?? testCase.name, label)
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

    func testVMCloneDryRunNamesTheMachineItWouldUse() throws {
        let root = try vmCloneScratch("drymachine")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let cases: [(arguments: [String], expected: String)] = [
            (["o/r", "--machine", "brave-otter"], "plan: machine brave-otter (pinned with --machine)"),
            (["o/r", "--new", "--size", "16g"], "plan: machine a new 16g machine (--new)"),
            // No app to ask: the plan says how routing decides instead of failing.
            (["o/r"], "plan: machine the one this repository used last"),
        ]
        for testCase in cases {
            let result = try runVMCloneCLI(
                arguments: ["vm", "clone"] + testCase.arguments + ["--dry-run"],
                home: home,
                socketPath: makeSocketPath("vdm")
            )
            XCTAssertEqual(result.status, 0, "\(testCase.arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
            XCTAssertTrue(result.stdout.contains(testCase.expected), "\(testCase.arguments): \(result.stdout)")
        }
        let (pinned, _) = try vmCloneDryRunPlan(["o/r", "--machine", "brave-otter"], home: home)
        XCTAssertEqual(pinned["machine"] as? String, "brave-otter")
        XCTAssertEqual(pinned["machine_plan"] as? String, "brave-otter (pinned with --machine)")
        XCTAssertEqual(pinned["would_provision"] as? Bool, false)
    }

    // MARK: - Machine choice

    /// `vm clone o/r --dry-run --json` against a mock whose `vm.list` is `vms`: the
    /// machine the clone would use, read without creating one.
    private func vmCloneDryRunAgainstList(
        _ name: String,
        vms: [[String: Any]],
        home: URL
    ) throws -> (plan: [String: Any], result: ProcessRunResult, log: VMCloneRequestLog) {
        let (result, log) = try runVMCloneAgainstMock(
            name,
            arguments: ["vm", "clone", "o/r", "--dry-run", "--json"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.list": return ["vms": vms]
            case "vm.stats": return ["state": "running", "cpu_percent": 5.0]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let plan = result.stdout.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return (try XCTUnwrap(plan, result.stdout), result, log)
    }

    /// The sticky binding `vm clone` records for a repository (`vmRunWorkKey` over
    /// `vmCloneRoutingDirectory`), written the way the CLI writes it.
    private func writeVMCloneBinding(projectKey: String, machine: String, home: URL) throws {
        let digest = SHA256.hash(data: Data("/cmux-vm-clone/\(projectKey)".utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let store: [String: Any] = [key: ["machine": machine, "updatedAtUnix": Int(Date().timeIntervalSince1970)]]
        let url = home.appendingPathComponent(".cmuxterm/vm-run-bindings.json")
        try JSONSerialization.data(withJSONObject: store).write(to: url)
    }

    func testVMCloneUsesYourOnlyRunningMachineBeforeThePool() throws {
        let root = try vmCloneScratch("onlyrunning")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        // One machine made with `vm new` and left running; a paused one and Base are not
        // candidates, so it is the only running machine.
        let vms: [[String: Any]] = [
            ["id": "vm-brave", "displayName": "proud-white-sloth", "status": "running"],
            ["id": "vm-paused", "displayName": "old-box", "status": "paused"],
            ["id": "vm-base", "status": "running", "base": ["id": "b1", "name": "Base", "generation": 1]],
        ]
        let (plan, _, log) = try vmCloneDryRunAgainstList("vco1", vms: vms, home: home)
        XCTAssertEqual(plan["machine"] as? String, "vm-brave")
        XCTAssertEqual(plan["would_provision"] as? Bool, false)
        // People read the label `vm ls` shows; the JSON plan keeps the id for scripts.
        XCTAssertEqual(plan["machine_plan"] as? String, "proud-white-sloth (your only running machine)")
        XCTAssertEqual(plan["machine_label"] as? String, "proud-white-sloth")
        XCTAssertFalse(log.methods.contains("vm.create"), log.methods.description)

        // The real run says which machine it took and how to get a fresh one instead.
        let (result, runLog) = try runVMCloneAgainstMock(
            "vco2",
            arguments: ["vm", "clone", "o/r", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.list": return ["vms": vms]
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_4", "existing": false, "opened": false]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertFalse(runLog.methods.contains("vm.create"), runLog.methods.description)
        XCTAssertEqual(runLog.params(ofFirst: "vm.exec")?["id"] as? String, "vm-brave")
        XCTAssertTrue(
            result.stderr.contains("Using proud-white-sloth (your only running machine). Use --new for a fresh one."),
            result.stderr
        )
        XCTAssertTrue(result.stdout.contains("Cloned github.com/o/r into work/r on proud-white-sloth."), result.stdout)
        // The label is the address people copy (`cmux vm open` resolves it); no raw id.
        XCTAssertTrue(result.stdout.contains("Open: cmux vm open proud-white-sloth/ws_4"), result.stdout)
        XCTAssertFalse(result.stdout.contains("vm-brave"), "no raw id in the human summary: \(result.stdout)")

        // A label two machines share is no address: the id stays in the Open line.
        let twins: [[String: Any]] = [
            ["id": "vm-brave", "displayName": "twin", "status": "running"],
            ["id": "vm-other", "displayName": "twin", "status": "paused"],
        ]
        let (twinResult, _) = try runVMCloneAgainstMock(
            "vco3",
            arguments: ["vm", "clone", "o/r", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.list": return ["vms": twins]
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_4", "existing": false, "opened": false]
            default: return nil
            }
        }
        XCTAssertEqual(twinResult.status, 0, "stdout=\(twinResult.stdout) stderr=\(twinResult.stderr)")
        XCTAssertTrue(twinResult.stdout.contains("Open: cmux vm open vm-brave/ws_4"), twinResult.stdout)
    }

    func testVMCloneDoesNotGuessBetweenSeveralRunningMachines() throws {
        let root = try vmCloneScratch("severalrunning")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let vms: [[String: Any]] = [
            ["id": "vm-a", "displayName": "brave-otter", "status": "running"],
            ["id": "vm-b", "displayName": "vivid-newt", "status": "ready"],
        ]
        let (plan, _, _) = try vmCloneDryRunAgainstList("vcs4", vms: vms, home: home)
        // The router's policy is unchanged: it never drafts a machine made by hand.
        XCTAssertEqual(plan["would_provision"] as? Bool, true, "\(plan)")
        XCTAssertTrue(plan["machine"] is NSNull, "\(plan)")
    }

    func testVMCloneReturnsToTheMachineThisRepositoryUsedLast() throws {
        let root = try vmCloneScratch("sticky")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        // Two running machines would not be guessed between, but the repository was
        // cloned onto vm-b before (with --machine), so the clone goes back there.
        try writeVMCloneBinding(projectKey: "github.com/o/r", machine: "vm-b", home: home)
        let vms: [[String: Any]] = [
            ["id": "vm-a", "displayName": "brave-otter", "status": "running"],
            ["id": "vm-b", "displayName": "vivid-newt", "status": "standby"],
        ]
        let (plan, _, _) = try vmCloneDryRunAgainstList("vcs6", vms: vms, home: home)
        XCTAssertEqual(plan["machine"] as? String, "vm-b")
        XCTAssertEqual(plan["machine_plan"] as? String, "vivid-newt (reused, holds this repository's checkout)")
    }

    func testVMCloneNamesAFreshMachinesFirstWorkspaceForTheRepository() throws {
        let root = try vmCloneScratch("adopt")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        // No machines: the router provisions a pool machine, whose daemon already has
        // `workspace-1` with an idle home shell. The clone names that workspace for the
        // repository and replaces its shell with one in the checkout, instead of leaving
        // `workspace-1` beside a second `api` workspace.
        let (result, log) = try runVMCloneAgainstMock(
            "vcad",
            arguments: ["vm", "clone", "acme/api", "--no-open", "--json"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.list": return ["vms": []]
            case "vm.create": return ["id": "vm-new", "status": "running"]
            case "vm.rename": return ["id": "vm-new"]
            case "vm.status": return ["id": "vm-new", "status": "running"]
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\ncmux-clone-path=/home/cmux/work/api\n", "stderr": ""]
            case "vm.tree":
                return [
                    "machines": [[
                        "id": "vm-new",
                        "link_state": "connected",
                        "remote_workspaces": [["id": "ws_1", "name": "workspace-1", "focused": true]],
                    ]],
                    "resources": [[
                        "id": "vm-new/terminal/term_home",
                        "key": "term_home",
                        "kind": "terminal",
                        "machine": "vm-new",
                        "lifecycle": "running",
                        "remote_workspace": ["id": "ws_1"],
                    ]],
                ]
            case "vm.workspace_rename": return ["renamed": true, "remote_workspace_id": "ws_1"]
            // The get-or-create finds the renamed workspace.
            case "vm.workspace_new": return ["remote_workspace_id": "ws_1", "existing": true, "opened": false]
            case "surface.new_terminal": return ["terminal_id": "term_checkout", "remote_workspace_id": "ws_1"]
            case "vm.terminal_close": return ["closed": true]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(log.methods.contains("vm.create"), log.methods.description)
        let rename = try XCTUnwrap(log.params(ofFirst: "vm.workspace_rename"), log.methods.description)
        XCTAssertEqual(rename["workspace_id"] as? String, "ws_1")
        XCTAssertEqual(rename["name"] as? String, "api")
        let methods = log.methods
        let renameIndex = try XCTUnwrap(methods.firstIndex(of: "vm.workspace_rename"))
        let workspaceIndex = try XCTUnwrap(methods.firstIndex(of: "vm.workspace_new"))
        XCTAssertLessThan(renameIndex, workspaceIndex, "named before the get-or-create looks it up")
        XCTAssertEqual(log.params(ofFirst: "surface.new_terminal")?["cwd"] as? String, "/home/cmux/work/api")
        XCTAssertEqual(log.params(ofFirst: "vm.terminal_close")?["terminal_id"] as? String, "term_home")
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual(payload["machine"] as? String, "vm-new")
        XCTAssertEqual(payload["created"] as? Bool, true)
        XCTAssertEqual(payload["workspace_id"] as? String, "ws_1")
        XCTAssertEqual(payload["adopted_initial_workspace"] as? Bool, true)
        XCTAssertEqual(payload["existing_workspace"] as? Bool, false)
        XCTAssertEqual(payload["terminal_id"] as? String, "term_checkout")
    }

    func testVMCloneNeverRenamesAWorkspaceOnAMachineItDidNotCreate() throws {
        let root = try vmCloneScratch("noadopt")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, log) = try runVMCloneAgainstMock(
            "vcna",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_2", "existing": false, "opened": false, "terminal_id": "term_s"]
            case "vm.terminal_write": return [:]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertFalse(log.methods.contains("vm.tree"), log.methods.description)
        XCTAssertFalse(log.methods.contains("vm.workspace_rename"), log.methods.description)
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

        let (tracked, trackedResult) = try vmCloneDryRunPlan(["."], home: home, directory: repo)
        let trackedRepo = try XCTUnwrap(tracked["repo"] as? [String: Any])
        XCTAssertEqual(trackedRepo["url"] as? String, "https://github.com/Acme/Widget.git")
        XCTAssertEqual(trackedRepo["project"] as? String, "github.com/acme/widget")
        XCTAssertEqual(trackedRepo["branch"] as? String, "feature/login")
        XCTAssertEqual(tracked["dir"] as? String, "work/Widget")
        XCTAssertFalse(trackedResult.stderr.contains("uncommitted"), "a clean, pushed checkout has no note: \(trackedResult.stderr)")

        // Work that stays on this Mac is named: uncommitted edits and unpushed commits.
        try "draft".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        git(["commit", "-q", "--allow-empty", "-m", "local"])
        let (_, dirtyResult) = try vmCloneDryRunPlan(["."], home: home, directory: repo)
        XCTAssertTrue(
            dirtyResult.stderr.contains("Cloning origin/feature/login \u{2014} 1 uncommitted change in this checkout is not included. Use `cmux vm push` or `cmux vm dev`"),
            dirtyResult.stderr
        )
        XCTAssertTrue(dirtyResult.stderr.contains("1 local commit is not on origin/feature/login yet"), dirtyResult.stderr)

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
        ) { method, params in
            switch method {
            case "vm.secrets_sync": return ["machine": "brave-otter", "sent": ["GH_TOKEN"], "removed": [], "noop": false]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\ncmux-clone-path=/home/cmux/work/api\n", "stderr": "Cloning into 'work/api'...\n"]
            case "vm.workspace_new": return ["machine": "brave-otter", "remote_workspace_id": "ws_9", "existing": false, "opened": false, "terminal_id": "term_starter"]
            case "vm.terminal_close": return ["closed": true]
            case "surface.new_terminal":
                // The checkout shell has no command; the agent has one.
                let terminal = params["command"] == nil ? "term_shell" : "term_agent"
                return ["terminal_id": terminal, "remote_workspace_id": "ws_9"]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        // --machine pins the machine: one `vm.list` to resolve a label (this app does not
        // answer it, so the argument stands as typed), no routing, secrets before git. The starter
        // shell is replaced by one started in the checkout: nothing is typed into it.
        XCTAssertEqual(
            log.methods,
            ["vm.list", "vm.secrets_sync", "vm.exec", "vm.workspace_new", "surface.new_terminal", "vm.terminal_close", "vm.agent_readiness", "surface.new_terminal"],
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

        // The clone exec reports the absolute checkout path for native terminal cwds.
        XCTAssertTrue(command.contains("cmux-clone-path="), command)
        let terminals = log.snapshot()
            .filter { ($0["method"] as? String) == "surface.new_terminal" }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(terminals.count, 2, log.methods.description)
        let shell = terminals[0]
        XCTAssertNil(shell["command"], "the checkout terminal is a plain login shell: \(shell)")
        XCTAssertEqual(shell["cwd"] as? String, "/home/cmux/work/api")
        XCTAssertEqual(shell["remote_workspace_id"] as? String, "ws_9")
        XCTAssertEqual(log.params(ofFirst: "vm.terminal_close")?["terminal_id"] as? String, "term_starter")

        let agent = terminals[1]
        XCTAssertEqual(agent["machine"] as? String, "brave-otter")
        XCTAssertEqual(agent["remote_workspace_id"] as? String, "ws_9", "the agent is a tab in the repository's workspace")
        XCTAssertEqual(agent["cwd"] as? String, "/home/cmux/work/api")
        XCTAssertEqual(agent["open"] as? Bool, false)
        let agentCommand = try XCTUnwrap(agent["command"] as? [String])
        XCTAssertEqual(agentCommand.prefix(2), ["bash", "-lc"])
        XCTAssertTrue(agentCommand.last?.contains("work/api") == true, agentCommand.description)
        // Not exec'd: when the one-shot agent exits, a shell keeps the tab in the workspace.
        XCTAssertTrue(agentCommand.last?.hasSuffix("claude -p 'fix it'; exec \"${SHELL:-bash}\" -l") == true, agentCommand.description)

        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual(payload["machine"] as? String, "brave-otter")
        XCTAssertEqual(payload["result"] as? String, "cloned")
        XCTAssertEqual(payload["dir"] as? String, "work/api")
        XCTAssertEqual(payload["workspace_id"] as? String, "ws_9")
        XCTAssertEqual(payload["agent_terminal_id"] as? String, "term_agent")
        XCTAssertEqual(payload["terminal_id"] as? String, "term_shell")
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
        XCTAssertEqual(log.methods, ["vm.list", "vm.secrets_sync", "vm.exec", "vm.workspace_new"], log.methods.description)
        let command = try XCTUnwrap(log.params(ofFirst: "vm.exec")?["command"] as? String)
        XCTAssertTrue(command.contains("fetch --prune origin"), "an existing checkout is fetched: \(command)")
        XCTAssertTrue(command.contains("k=github.com/o/r") || command.contains("k='github.com/o/r'"), command)
        XCTAssertTrue(result.stdout.contains("Updated github.com/o/r in work/r on brave-otter."), result.stdout)
        XCTAssertTrue(result.stdout.contains("Open: cmux vm open brave-otter/ws_3"), result.stdout)
        XCTAssertTrue(result.stderr.contains("Machine") && result.stderr.contains(" \u{00B7} Secrets"), "summary line: \(result.stderr)")
    }

    func testVMCloneNamesTheWorkspaceForANonDefaultCheckoutDirectory() throws {
        let root = try vmCloneScratch("dirws")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        // The workspace is found again by name, so a second checkout of the same
        // repository must not share the first one's name (and so its workspace).
        let cases: [(arguments: [String], name: String)] = [
            (["o/r"], "r"),
            (["o/r", "--dir", "work/x"], "r (x)"),
            (["o/r", "--dir", "~/work/x/"], "r (x)"),
            (["o/r", "--dir", "other/r"], "r (other/r)"),
        ]
        for (index, testCase) in cases.enumerated() {
            let (plan, _) = try vmCloneDryRunPlan(testCase.arguments + ["--machine", "brave-otter"], home: home)
            XCTAssertEqual(plan["workspace_name"] as? String, testCase.name, testCase.arguments.description)
            let (result, log) = try runVMCloneAgainstMock(
                "vcdw\(index)",
                arguments: ["vm", "clone"] + testCase.arguments + ["--machine", "brave-otter", "--no-open"],
                home: home
            ) { method, _ in
                switch method {
                case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
                case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": ""]
                case "vm.workspace_new": return ["remote_workspace_id": "ws_\(index)", "existing": false, "opened": false]
                default: return nil
                }
            }
            XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
            let workspace = try XCTUnwrap(log.params(ofFirst: "vm.workspace_new"), log.methods.description)
            XCTAssertEqual(workspace["name"] as? String, testCase.name, testCase.arguments.description)
            XCTAssertEqual(workspace["reuse"] as? Bool, true)
        }
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
        XCTAssertEqual(log.methods, ["vm.list", "vm.secrets_sync", "vm.exec"], "nothing is opened after a failed clone: \(log.methods)")
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
        XCTAssertEqual(log.methods, ["vm.list", "vm.secrets_sync", "vm.exec"], log.methods.description)
        XCTAssertTrue(result.stderr.contains("work/r on brave-otter already holds a checkout of github.com/other/r"), result.stderr)
        XCTAssertTrue(result.stderr.contains("--dir"), result.stderr)
    }

    // MARK: - Declared secrets and setup

    /// The clone exec's stdout for a checkout holding `.cmux/cloud.json`.
    private static func vmCloneOutput(withCloudJSON cloudJSON: String) -> String {
        "cmux-clone=cloned\ncmux-manifest .cmux/cloud.json \(Data(cloudJSON.utf8).base64EncodedString())\n"
    }

    private static let vmCloneManifest = #"""
    {
      // what the project needs
      "env": [{"name": "DATABASE_URL", "description": "Postgres for tests"}, "ANTHROPIC_API_KEY"],
      "setup": ["bun install", "bun run build"],
    }
    """#

    /// The app's side of a clone whose checkout declares secrets and setup. `setupOutput`
    /// is what the "setup" terminal printed.
    private static func vmCloneSetupResponder(setupOutput: String) -> @Sendable (String, [String: Any]) -> [String: Any]? {
        { method, params in
            switch method {
            case "vm.secrets_sync": return ["machine": "brave-otter", "sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": vmCloneOutput(withCloudJSON: vmCloneManifest), "stderr": ""]
            case "vm.secrets_check":
                return [
                    "declared": [
                        ["name": "DATABASE_URL", "description": "Postgres for tests", "source": ".cmux/cloud.json", "stored": false, "scopes": [], "effective": false],
                        ["name": "ANTHROPIC_API_KEY", "description": NSNull(), "source": ".cmux/cloud.json", "stored": true, "scopes": ["all"], "effective": true],
                    ],
                    "missing": ["DATABASE_URL"],
                    "project": "github.com/acme/api",
                    "machine": "brave-otter",
                ]
            case "vm.workspace_new": return ["machine": "brave-otter", "remote_workspace_id": "ws_9", "existing": false, "opened": false, "terminal_id": "term_starter"]
            case "vm.terminal_write": return ["wrote": 20]
            case "surface.new_terminal":
                return (params["name"] as? String) == "setup"
                    ? ["terminal_id": "term_setup", "remote_workspace_id": "ws_9"]
                    : ["terminal_id": "term_agent", "remote_workspace_id": "ws_9"]
            case "vm.terminal_wait": return ["matched": true, "text": setupOutput]
            case "vm.terminal_output": return ["text": setupOutput, "start_offset": 0, "next_offset": setupOutput.utf8.count, "complete": true]
            default: return nil
            }
        }
    }

    func testVMCloneWarnsAboutMissingSecretsAndRunsSetupInAVisibleTerminal() throws {
        let root = try vmCloneScratch("setup")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let output = "[cmux setup] 2 step(s) from .cmux/cloud.json\r\n\r\n[cmux setup 1/2] $ bun install\r\n\u{1B}[32mbun install v1.2\u{1B}[0m\r\n"
            + "[cmux setup 1/2] exit 0\r\n\r\n[cmux setup 2/2] $ bun run build\r\nbuilt in 3s\r\n[cmux setup 2/2] exit 0\r\n[cmux setup] done\r\n$ "
        let (result, log) = try runVMCloneAgainstMock(
            "vcs1",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--json", "--setup", "--agent", "claude"],
            home: home,
            respond: Self.vmCloneSetupResponder(setupOutput: output)
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(
            log.methods,
            ["vm.list", "vm.secrets_sync", "vm.exec", "vm.secrets_check", "vm.workspace_new", "vm.terminal_write",
             "surface.new_terminal", "vm.terminal_wait", "vm.terminal_output", "vm.agent_readiness", "surface.new_terminal"],
            "setup runs after the workspace and before the agent: \(log.methods)"
        )
        // The same exec that clones reads the manifest back (names and commands only).
        let command = try XCTUnwrap(log.params(ofFirst: "vm.exec")?["command"] as? String)
        XCTAssertTrue(command.contains("cmux-manifest"), command)
        XCTAssertTrue(command.contains(".cmux/cloud.json"), command)

        // Preflight: the declared names go to the app with the machine and the project.
        let check = try XCTUnwrap(log.params(ofFirst: "vm.secrets_check"))
        XCTAssertEqual(check["id"] as? String, "brave-otter")
        XCTAssertEqual(check["project"] as? String, "github.com/acme/api")
        XCTAssertEqual((check["files"] as? [String: Any])?[".cmux/cloud.json"] as? String, Self.vmCloneManifest)
        XCTAssertTrue(
            result.stderr.contains("Missing secrets for acme/api: DATABASE_URL (from .cmux/cloud.json \u{2014} \"Postgres for tests\")."),
            result.stderr
        )
        XCTAssertTrue(result.stderr.contains("Add: cmux vm secrets set DATABASE_URL --scope project:github.com/acme/api"), result.stderr)
        XCTAssertFalse(result.stderr.contains("ANTHROPIC_API_KEY ("), "a stored name is not reported missing: \(result.stderr)")

        // Setup: one visible terminal named "setup" in the repository's workspace.
        let terminals = log.snapshot()
            .filter { ($0["method"] as? String) == "surface.new_terminal" }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(terminals.first?["name"] as? String, "setup")
        XCTAssertEqual(terminals.first?["remote_workspace_id"] as? String, "ws_9")
        XCTAssertEqual(terminals.first?["focus"] as? Bool, false)
        let setupCommand = try XCTUnwrap(terminals.first?["command"] as? [String])
        XCTAssertEqual(setupCommand.prefix(2), ["bash", "-lc"])
        let script = setupCommand.last ?? ""
        XCTAssertTrue(script.contains("( eval 'bun install' )"), script)
        XCTAssertTrue(script.contains("( eval 'bun run build' )"), script)
        XCTAssertTrue(script.contains("work/api"), script)
        XCTAssertTrue(script.hasSuffix("exec \"${SHELL:-bash}\" -l"), "the terminal stays open as a shell: \(script)")
        let wait = try XCTUnwrap(log.params(ofFirst: "vm.terminal_wait"))
        XCTAssertEqual(wait["terminal_id"] as? String, "term_setup")
        XCTAssertEqual(wait["pattern"] as? String, "\\[cmux setup 1/2\\] exit [0-9]+")
        XCTAssertNotNil(wait["timeout_ms"] as? Int, "the wait is bounded: \(wait)")
        XCTAssertEqual(terminals.last?["name"] as? String, "claude", "the agent starts after setup")

        for step in ["Setup 1/2 bun install \u{2026} ", "Setup 2/2 bun run build \u{2026} "] {
            XCTAssertTrue(result.stderr.contains(step), "missing '\(step)' in:\n\(result.stderr)")
        }
        XCTAssertTrue(result.stderr.contains("s \u{2713}"), result.stderr)

        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual(payload["missing_secrets"] as? [String], ["DATABASE_URL"])
        let setup = try XCTUnwrap(payload["setup"] as? [String: Any])
        XCTAssertEqual(setup["status"] as? String, "done")
        XCTAssertEqual(setup["terminal_id"] as? String, "term_setup")
        XCTAssertEqual((setup["steps"] as? [[String: Any]])?.compactMap { $0["exit_code"] as? Int }, [0, 0])
        XCTAssertEqual(payload["agent_terminal_id"] as? String, "term_agent")
        XCTAssertNotNil((payload["timings"] as? [String: Any])?["setup"])
    }

    /// A checkout whose `.cmux/cloud.json` declares exactly one setup command.
    private static func vmCloneOneStepResponder(setupOutput: String) -> @Sendable (String, [String: Any]) -> [String: Any]? {
        let base = vmCloneSetupResponder(setupOutput: setupOutput)
        let manifest = #"{"setup": "bun install"}"#
        return { method, params in
            method == "vm.exec"
                ? ["exit_code": 0, "stdout": vmCloneOutput(withCloudJSON: manifest), "stderr": ""]
                : base(method, params)
        }
    }

    func testVMCloneCountsOneSetupStepInTheSingular() throws {
        let root = try vmCloneScratch("setupone")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let output = "[cmux setup 1/1] $ bun install\nok\n[cmux setup 1/1] exit 0\n[cmux setup] done\n"
        let (result, _) = try runVMCloneAgainstMock(
            "vcs1o",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--setup"],
            home: home,
            respond: Self.vmCloneOneStepResponder(setupOutput: output)
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("\u{2014} 1 step in terminal term_setup"), result.stderr)
        XCTAssertFalse(result.stderr.contains("1 steps"), result.stderr)
    }

    func testVMCloneSetupPromptNamesTheRepositoryAndCountsInTheSingular() throws {
        let root = try vmCloneScratch("setupprompt")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        // A terminal to ask on, and "n" typed at the prompt: nothing runs.
        let (result, log) = try runVMCloneAgainstMock(
            "vcsp",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open"],
            home: home,
            terminalInput: "n\n",
            respond: Self.vmCloneOneStepResponder(setupOutput: "")
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertFalse(log.methods.contains("vm.terminal_wait"), "declined setup never runs: \(log.methods)")
        let screen = result.stdout.replacingOccurrences(of: "\r", with: "")
        // A lead-in names where the commands come from, then the list, then the question.
        XCTAssertTrue(
            screen.contains("Setup commands from acme/api:\n  1. bun install\nRun 1 setup command from acme/api on brave-otter? It runs with your Cloud Secrets. [y/N] "),
            screen
        )
        XCTAssertFalse(screen.contains("Run these 1"), screen)
        XCTAssertTrue(screen.contains("Setup skipped."), screen)
    }

    func testVMCloneStopsAtAFailedSetupStepAndKeepsItsTerminal() throws {
        let root = try vmCloneScratch("setupfail")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let output = "[cmux setup 1/2] $ bun install\nok\n[cmux setup 1/2] exit 0\n[cmux setup 2/2] $ bun run build\nerror: missing script\n[cmux setup 2/2] exit 7\n[cmux setup] step 2/2 failed. This shell stays open in the checkout.\n"
        let (result, log) = try runVMCloneAgainstMock(
            "vcs2",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--setup", "--agent", "codex"],
            home: home,
            respond: Self.vmCloneSetupResponder(setupOutput: output)
        )
        XCTAssertEqual(result.status, 7, "a failed step's exit code passes through: stdout=\(result.stdout) stderr=\(result.stderr)")
        let terminals = log.snapshot().filter { ($0["method"] as? String) == "surface.new_terminal" }
        XCTAssertEqual(terminals.count, 1, "no agent after a failed setup: \(log.methods)")
        XCTAssertFalse(log.methods.contains("vm.terminal_close"), "the setup terminal stays open")
        XCTAssertTrue(result.stderr.contains("Setup 1/2 bun install \u{2026} "), result.stderr)
        XCTAssertTrue(result.stderr.contains("\u{2717} exit 7"), result.stderr)
        // One whole sentence: the step, its command, the exit code and the machine.
        XCTAssertTrue(
            result.stderr.contains("vm clone: setup step 2 of 2 (`bun run build`) exited with code 7 on brave-otter. The \"setup\" terminal stays open in the checkout."),
            result.stderr
        )
        XCTAssertTrue(result.stderr.contains("Open: cmux vm open brave-otter/ws_9/term_setup"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm clone acme/api --machine brave-otter --skip-setup"), result.stderr)
    }

    func testVMCloneSkipSetupStartsTheAgentWithoutTheSetupTerminal() throws {
        let root = try vmCloneScratch("setupskip")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, log) = try runVMCloneAgainstMock(
            "vcs3",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--skip-setup", "--json", "--agent", "claude"],
            home: home,
            respond: Self.vmCloneSetupResponder(setupOutput: "")
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let terminals = log.snapshot()
            .filter { ($0["method"] as? String) == "surface.new_terminal" }
            .compactMap { ($0["params"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(terminals, ["claude"], log.methods.description)
        XCTAssertFalse(log.methods.contains("vm.terminal_wait"), log.methods.description)
        XCTAssertTrue(result.stderr.contains("Setup skipped (--skip-setup): bun install; bun run build"), result.stderr)
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual((payload["setup"] as? [String: Any])?["status"] as? String, "skipped")
    }

    // MARK: - Setup trust

    func testVMCloneOfSomeoneElsesRepoSkipsSetupWithoutATerminal() throws {
        let root = try vmCloneScratch("setuptrust")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        // No --setup and no terminal to ask on: the repository's commands never run.
        let (result, log) = try runVMCloneAgainstMock(
            "vcst",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--json", "--agent", "claude"],
            home: home,
            respond: Self.vmCloneSetupResponder(setupOutput: "")
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let names = log.snapshot()
            .filter { ($0["method"] as? String) == "surface.new_terminal" }
            .compactMap { ($0["params"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["claude"], "no setup terminal: \(log.methods)")
        XCTAssertTrue(
            result.stderr.contains("Setup skipped: run again with --setup to run the setup commands from acme/api (bun install; bun run build)."),
            result.stderr
        )
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        let setup = try XCTUnwrap(payload["setup"] as? [String: Any])
        XCTAssertEqual(setup["status"] as? String, "skipped")
        XCTAssertEqual(setup["skip_reason"] as? String, "needs_confirmation")
    }

    func testVMCloneUpdateOfAnExistingCheckoutDoesNotRerunSetup() throws {
        let root = try vmCloneScratch("setupupdate")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let updatedOutput = "cmux-clone=updated\ncmux-manifest .cmux/cloud.json \(Data(Self.vmCloneManifest.utf8).base64EncodedString())\n"
        let base = Self.vmCloneSetupResponder(setupOutput: "")
        let respond: @Sendable (String, [String: Any]) -> [String: Any]? = { method, params in
            method == "vm.exec" ? ["exit_code": 0, "stdout": updatedOutput, "stderr": ""] : base(method, params)
        }
        // Even with --setup's sibling flags absent and --json, an update leaves setup alone.
        let (result, log) = try runVMCloneAgainstMock(
            "vcsu",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--json"],
            home: home,
            respond: respond
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertFalse(log.methods.contains("vm.terminal_wait"), log.methods.description)
        XCTAssertTrue(result.stderr.contains("Setup skipped: acme/api was already checked out on the machine. Run again with --setup"), result.stderr)
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual((payload["setup"] as? [String: Any])?["skip_reason"] as? String, "existing_checkout")

        // --setup runs it again on the same checkout.
        let (again, againLog) = try runVMCloneAgainstMock(
            "vcsv",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--setup"],
            home: home,
            respond: { method, params in
                switch method {
                case "vm.exec": return ["exit_code": 0, "stdout": updatedOutput, "stderr": ""]
                case "vm.terminal_wait": return ["matched": true, "text": "[cmux setup 1/2] exit 0\n[cmux setup 2/2] exit 0\n"]
                case "vm.terminal_output":
                    let text = "[cmux setup 1/2] exit 0\n[cmux setup 2/2] exit 0\n"
                    return ["text": text, "next_offset": text.utf8.count]
                default: return base(method, params)
                }
            }
        )
        XCTAssertEqual(again.status, 0, "stdout=\(again.stdout) stderr=\(again.stderr)")
        XCTAssertTrue(againLog.methods.contains("vm.terminal_wait"), againLog.methods.description)
    }

    func testVMCloneRejectsSetupAndSkipSetupTogether() throws {
        let root = try vmCloneScratch("setupboth")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runVMCloneCLI(
            arguments: ["vm", "clone", "o/r", "--setup", "--skip-setup", "--dry-run"],
            home: root.appendingPathComponent("home"),
            socketPath: makeSocketPath("vcsb")
        )
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("--setup and --skip-setup are exclusive"), result.stderr)
    }

    // MARK: - Following setup

    /// Pages `vm.terminal_output` returns, one per call, then nothing new.
    private final class VMCloneOutputPages: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String]
        private var offset = 0

        init(_ pages: [String]) { self.pages = pages }

        func next() -> [String: Any] {
            lock.lock()
            defer { lock.unlock() }
            let page = pages.isEmpty ? "" : pages.removeFirst()
            offset += page.utf8.count
            return ["text": page, "next_offset": offset]
        }
    }

    /// A `--setup` clone whose setup terminal is followed with `waitReply` (nil: the
    /// method is unknown to this app) and whose output arrives in `pages`.
    private func runVMCloneSetupFollow(
        _ name: String,
        waitReply: [String: Any]?,
        waitExitReply: [String: Any]?,
        pages: [String]
    ) throws -> (result: ProcessRunResult, log: VMCloneRequestLog) {
        let root = try vmCloneScratch(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = VMCloneOutputPages(pages)
        let base = Self.vmCloneSetupResponder(setupOutput: "")
        return try runVMCloneAgainstMock(
            name,
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--setup"],
            home: root.appendingPathComponent("home")
        ) { method, params in
            switch method {
            case "vm.terminal_wait": return waitReply
            case "vm.terminal_wait_exit": return waitExitReply
            case "vm.terminal_output": return output.next()
            default: return base(method, params)
            }
        }
    }

    func testVMCloneSetupFollowSurvivesAnAppWithoutWaitMethods() throws {
        // Neither wait method exists: that is "unknown", never "the terminal closed".
        // The CLI polls the output until both steps report their exit.
        let (result, log) = try runVMCloneSetupFollow(
            "vcf1",
            waitReply: nil,
            waitExitReply: nil,
            pages: ["[cmux setup 1/2] $ bun install\n", "[cmux setup 1/2] exit 0\n[cmux setup 2/2] $ bun run build\n", "[cmux setup 2/2] exit 0\n"]
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertFalse(result.stderr.contains("closed"), result.stderr)
        XCTAssertGreaterThanOrEqual(log.methods.filter { $0 == "vm.terminal_output" }.count, 3, log.methods.description)
    }

    func testVMCloneSetupFollowKeepsWaitingThroughSliceTimeouts() throws {
        // A slice that times out (not matched, not exited) is a running step.
        let (result, _) = try runVMCloneSetupFollow(
            "vcf2",
            waitReply: ["matched": false, "exited": false, "text": ""],
            waitExitReply: nil,
            pages: ["", "[cmux setup 1/2] exit 0\n", "", "[cmux setup 2/2] exit 0\n"]
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertFalse(result.stderr.contains("closed"), result.stderr)
    }

    func testVMCloneSetupFollowReportsATerminalTheDaemonSaysExited() throws {
        let (result, _) = try runVMCloneSetupFollow(
            "vcf3",
            waitReply: ["matched": false, "exited": true, "text": ""],
            waitExitReply: nil,
            pages: ["[cmux setup 1/2] $ bun install\n"]
        )
        XCTAssertEqual(result.status, 1, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("vm clone: the \"setup\" terminal on brave-otter closed during setup step 1 of 2 (`bun install`)."),
            result.stderr
        )
    }

    // MARK: - --machine <label>

    func testVMCloneResolvesAMachineLabelBeforeAnythingRuns() throws {
        let root = try vmCloneScratch("label")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, log) = try runVMCloneAgainstMock(
            "vclb",
            arguments: ["vm", "clone", "o/r", "--machine", "proud-white-sloth", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.list": return ["vms": [["id": "vm-f944", "displayName": "proud-white-sloth", "status": "running"]]]
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_2", "existing": false, "opened": false]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods.filter { $0 == "vm.exec" }.count, 1, "the clone runs once: \(log.methods)")
        XCTAssertEqual(log.params(ofFirst: "vm.secrets_sync")?["id"] as? String, "vm-f944")
        XCTAssertEqual(log.params(ofFirst: "vm.exec")?["id"] as? String, "vm-f944")
        XCTAssertTrue(result.stdout.contains("on proud-white-sloth."), result.stdout)
        XCTAssertTrue(result.stdout.contains("Open: cmux vm open proud-white-sloth/ws_2"), result.stdout)
        XCTAssertFalse(result.stdout.contains("vm-f944"), "the label, not the id, in the summary: \(result.stdout)")
        XCTAssertFalse(result.stderr.contains("is the label of"), result.stderr)

        // An unknown machine stops before any request to it; no binding is recorded.
        let (unknown, unknownLog) = try runVMCloneAgainstMock(
            "vclu",
            arguments: ["vm", "clone", "o/r", "--machine", "ghost", "--no-open"],
            home: home
        ) { method, _ in
            method == "vm.list" ? ["vms": [["id": "vm-f944", "displayName": "proud-white-sloth", "status": "running"]]] : nil
        }
        XCTAssertNotEqual(unknown.status, 0, unknown.stdout)
        XCTAssertEqual(unknownLog.methods, ["vm.list"], unknownLog.methods.description)
        XCTAssertTrue(unknown.stderr.contains("vm clone: no machine named ghost."), unknown.stderr)
    }

    func testVMCloneRecordsTheRepositoryMachineOnlyAfterASuccessfulClone() throws {
        let root = try vmCloneScratch("bindfail")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let (result, _) = try runVMCloneAgainstMock(
            "vcbf",
            arguments: ["vm", "clone", "o/r", "--machine", "brave-otter", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 128, "stdout": "", "stderr": "fatal: repository not found\n"]
            default: return nil
            }
        }
        XCTAssertNotEqual(result.status, 0, result.stdout)
        let bindings = home.appendingPathComponent(".cmuxterm/vm-run-bindings.json")
        let stored = (try? Data(contentsOf: bindings)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertTrue(stored?.isEmpty ?? true, "a failed clone binds nothing: \(stored ?? [:])")
    }

    // MARK: - Hostile input

    /// What a POSIX shell makes of `word` as it appears in a generated command.
    private func vmCloneShellValue(of word: String) -> String {
        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "eval \"set -- $1\"; printf %s \"$1\"", "sh", word],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 10
        )
        return result.stdout
    }

    func testVMCloneQuotesHostileBranchAndDirectoryForTheShell() throws {
        let root = try vmCloneScratch("hostile")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let branch = "x';touch$(echo)`id`;'"
        let dir = "work/a b'$(touch pwned)`id`;\"q"
        let (result, log) = try runVMCloneAgainstMock(
            "vchq",
            arguments: ["vm", "clone", "o/r", "--machine", "brave-otter", "--no-open", "--skip-setup", "--branch", branch, "--dir", dir],
            home: home
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_1", "existing": true, "opened": false]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let command = try XCTUnwrap(log.params(ofFirst: "vm.exec")?["command"] as? String)
        // `d=<word>; u=<word>; k=<word>; if …`: each word evaluates back to exactly what was typed.
        let assignment = try XCTUnwrap(command.range(of: "d=")).upperBound
        let uStart = try XCTUnwrap(command.range(of: "; u=", range: assignment..<command.endIndex))
        XCTAssertEqual(vmCloneShellValue(of: String(command[assignment..<uStart.lowerBound])), dir)
        let flags = try XCTUnwrap(command.range(of: "git clone --branch ")).upperBound
        let flagsEnd = try XCTUnwrap(command.range(of: " -- \"$u\"", range: flags..<command.endIndex))
        XCTAssertEqual(vmCloneShellValue(of: String(command[flags..<flagsEnd.lowerBound])), branch)
    }

    func testVMCloneRefusesDashDirectoriesAndRedactsCredentialsItEchoes() throws {
        let root = try vmCloneScratch("dash")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        // `--dir --agent` lost its value: never a directory named like a flag.
        let dash = try runVMCloneCLI(
            arguments: ["vm", "clone", "o/r", "--dir", "--agent", "--dry-run"],
            home: home,
            socketPath: makeSocketPath("vcdd")
        )
        XCTAssertNotEqual(dash.status, 0, dash.stdout)
        XCTAssertTrue(dash.stderr.contains("--dir '--agent' is not a usable directory"), dash.stderr)

        // An unrecognized repository string is echoed with its userinfo replaced.
        let secret = try runVMCloneCLI(
            arguments: ["vm", "clone", "ftp://alice:hunter2@example.com", "--dry-run"],
            home: home,
            socketPath: makeSocketPath("vcdr")
        )
        XCTAssertNotEqual(secret.status, 0, secret.stdout)
        XCTAssertFalse(secret.stderr.contains("hunter2"), secret.stderr)
        XCTAssertFalse(secret.stdout.contains("hunter2"), secret.stdout)
    }

    // MARK: - Warm starts and waking

    /// A repository's warm start, written the way `vm clone --save-warm` records it.
    private func writeVMCloneWarmStart(projectKey: String, snapshot: String, machine: String, savedSecondsAgo: Int, home: URL) throws {
        let store: [String: Any] = [projectKey: [
            "snapshot_id": snapshot,
            "machine": machine,
            "created_at_unix": Int(Date().timeIntervalSince1970) - savedSecondsAgo,
            "name": "cmux warm start \(projectKey)",
        ]]
        let url = home.appendingPathComponent(".cmuxterm/vm-warm-starts.json")
        try JSONSerialization.data(withJSONObject: store).write(to: url)
    }

    private func readVMCloneWarmStarts(home: URL) -> [String: [String: Any]] {
        let url = home.appendingPathComponent(".cmuxterm/vm-warm-starts.json")
        return ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: [String: Any]]) ?? [:]
    }

    func testVMCloneNewMachineStartsFromTheRepositorysWarmStart() throws {
        let root = try vmCloneScratch("warm")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try writeVMCloneWarmStart(projectKey: "github.com/o/r", snapshot: "snap_warm", machine: "vm-old", savedSecondsAgo: 3 * 86_400 + 3_600, home: home)

        // The plan says it would start from the warm start.
        let (plan, _) = try vmCloneDryRunPlan(["o/r", "--new"], home: home)
        let plannedWarm = try XCTUnwrap(plan["warm_start"] as? [String: Any], "\(plan)")
        XCTAssertEqual(plannedWarm["snapshot_id"] as? String, "snap_warm")

        // `--new`: a new machine is needed, so it is restored from the snapshot instead of
        // provisioned cold, and the existing checkout is only fetched.
        let (result, log) = try runVMCloneAgainstMock(
            "vcw1",
            arguments: ["vm", "clone", "o/r", "--new", "--no-open", "--json"],
            home: home
        ) { method, params in
            switch method {
            case "vm.restore": return ["id": "vm-warm", "status": "running", "image": "snap_warm"]
            case "vm.status": return ["id": "vm-warm", "status": "running"]
            case "vm.rename": return ["id": "vm-warm"]
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.tree":
                return ["machines": [[
                    "id": "vm-warm",
                    "remote_workspaces": [
                        ["id": "ws-old", "name": "source-repository"],
                        ["id": "ws-old-agent", "name": "source-agent"],
                    ],
                ]]
                ]
            case "vm.workspace_delete": return ["deleted": true]
            case "vm.exec":
                let command = (params["command"] as? String) ?? ""
                if command.contains("cmux-clone=") {
                    return ["exit_code": 0, "stdout": "cmux-clone=updated\ncmux-clone-path=/home/cmux/work/r\n", "stderr": ""]
                }
                return ["exit_code": 0, "stdout": "", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_r", "existing": false, "opened": false]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertFalse(log.methods.contains("vm.create"), "no cold machine: \(log.methods)")
        XCTAssertEqual(log.params(ofFirst: "vm.restore")?["snapshot_id"] as? String, "snap_warm")
        XCTAssertNotNil(log.params(ofFirst: "vm.restore")?["idempotency_key"] as? String)
        XCTAssertEqual(log.snapshot().filter { ($0["method"] as? String) == "vm.workspace_delete" }.count, 2)
        XCTAssertFalse(log.methods.contains("vm.workspace_rename"), "warm restore clears the source workspace graph: \(log.methods)")
        // The snapshot's machine env is cleared before Cloud Secrets deliver this machine's own.
        let execs = log.snapshot().filter { ($0["method"] as? String) == "vm.exec" }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertTrue(execs.allSatisfy { $0["id"] as? String == "vm-warm" }, "\(execs)")
        let clearIndex = try XCTUnwrap(execs.firstIndex { ($0["command"] as? String)?.contains(".config/cmux/env") == true }, "\(execs)")
        let cloneIndex = try XCTUnwrap(execs.firstIndex { ($0["command"] as? String)?.contains("cmux-clone=") == true }, "\(execs)")
        XCTAssertLessThan(clearIndex, cloneIndex)
        let methods = log.methods
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "vm.restore")), try XCTUnwrap(methods.firstIndex(of: "vm.secrets_sync")))
        XCTAssertTrue(result.stderr.contains("Warm start from snapshot (saved 3 days ago) "), result.stderr)
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual(payload["machine"] as? String, "vm-warm")
        XCTAssertEqual(payload["created"] as? Bool, true)
        XCTAssertEqual(payload["result"] as? String, "updated")
        let warm = try XCTUnwrap(payload["warm_start"] as? [String: Any], "\(payload)")
        XCTAssertEqual(warm["snapshot_id"] as? String, "snap_warm")
        XCTAssertEqual(warm["status"] as? String, "restored")
        // The restored machine joins the pool, like a machine the router provisioned.
        let pool = (try? Data(contentsOf: home.appendingPathComponent(".cmuxterm/vm-run-pool.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(pool?["machines"] as? [String], ["vm-warm"])
    }

    func testVMCloneDiscardsWarmMachineWhenItsEnvironmentCannotBeReset() throws {
        let root = try vmCloneScratch("warm-reset-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try writeVMCloneWarmStart(projectKey: "github.com/o/r", snapshot: "snap_warm", machine: "vm-old", savedSecondsAgo: 600, home: home)

        let (result, log) = try runVMCloneAgainstMock(
            "vcw-reset-fail",
            arguments: ["vm", "clone", "o/r", "--new", "--no-open", "--json"],
            home: home
        ) { method, params in
            switch method {
            case "vm.list": return ["vms": []]
            case "vm.restore": return ["id": "vm-warm", "status": "running", "image": "snap_warm"]
            case "vm.status": return ["id": "vm-warm", "status": "running"]
            case "vm.rename": return ["id": "vm-warm"]
            case "vm.destroy": return ["destroyed": true]
            case "vm.create": return ["id": "vm-cold", "status": "running"]
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec":
                let command = (params["command"] as? String) ?? ""
                if command.contains(".config/cmux/env") {
                    return ["exit_code": 1, "stdout": "", "stderr": "reset failed"]
                }
                return ["exit_code": 0, "stdout": "cmux-clone=cloned\ncmux-clone-path=/home/cmux/work/r\n", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_r", "existing": false, "opened": false]
            default: return nil
            }
        }

        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let methods = log.methods
        XCTAssertTrue(methods.contains("vm.destroy"), methods.description)
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "vm.restore")), try XCTUnwrap(methods.firstIndex(of: "vm.destroy")), methods.description)
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "vm.destroy")), try XCTUnwrap(methods.firstIndex(of: "vm.create")), methods.description)
        XCTAssertEqual(log.params(ofFirst: "vm.destroy")?["id"] as? String, "vm-warm")
        let execs = log.snapshot().filter { ($0["method"] as? String) == "vm.exec" }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(execs.last?["id"] as? String, "vm-cold")
        XCTAssertTrue(result.stderr.contains("Warm start from snapshot snap_warm failed"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cloning on a fresh machine instead"), result.stderr)
        XCTAssertEqual(readVMCloneWarmStarts(home: home)["github.com/o/r"]?["snapshot_id"] as? String, "snap_warm")
    }

    func testVMCloneFallsBackToAColdMachineWhenTheWarmStartCannotRestore() throws {
        let root = try vmCloneScratch("warmfail")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try writeVMCloneWarmStart(projectKey: "github.com/o/r", snapshot: "snap_gone", machine: "vm-old", savedSecondsAgo: 600, home: home)
        let socketPath = makeSocketPath("vcw2")
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
            let result: [String: Any]?
            switch method {
            case "vm.restore":
                return self.v2Response(id: id, ok: false, error: [
                    "code": "internal_error",
                    "message": "Snapshot snap_gone was not found.",
                    "data": ["http_status": 404, "backend_code": "vm_snapshot_not_found"],
                ])
            case "vm.create": result = ["id": "vm-cold", "status": "running"]
            case "vm.rename": result = ["id": "vm-cold"]
            case "vm.status": result = ["id": "vm-cold", "status": "running"]
            case "vm.secrets_sync": result = ["sent": [], "removed": [], "noop": true]
            case "vm.exec": result = ["exit_code": 0, "stdout": "cmux-clone=cloned\n", "stderr": ""]
            case "vm.workspace_new": result = ["remote_workspace_id": "ws_c", "existing": false, "opened": false]
            default: result = nil
            }
            guard let result else {
                return self.v2Response(id: id, ok: false, error: ["code": "method_not_found", "message": "Unknown method"])
            }
            return self.v2Response(id: id, ok: true, result: result)
        }
        let result = try runVMCloneCLI(arguments: ["vm", "clone", "o/r", "--new", "--no-open", "--json"], home: home, socketPath: socketPath)
        wait(for: [handled], timeout: 60)
        XCTAssertEqual(result.status, 0, "a bad snapshot never blocks the clone: stdout=\(result.stdout) stderr=\(result.stderr)")
        let methods = log.methods
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "vm.restore")), try XCTUnwrap(methods.firstIndex(of: "vm.create")), methods.description)
        XCTAssertEqual(log.params(ofFirst: "vm.exec")?["id"] as? String, "vm-cold")
        XCTAssertTrue(result.stderr.contains("Warm start from snapshot snap_gone failed"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cloning on a fresh machine instead"), result.stderr)
        // A snapshot that is gone is forgotten, so the next clone does not try it again.
        XCTAssertNil(readVMCloneWarmStarts(home: home)["github.com/o/r"], "\(readVMCloneWarmStarts(home: home))")
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual(payload["machine"] as? String, "vm-cold")
        let warm = try XCTUnwrap(payload["warm_start"] as? [String: Any], "\(payload)")
        XCTAssertEqual(warm["status"] as? String, "failed")
        XCTAssertEqual(warm["snapshot_id"] as? String, "snap_gone")
    }

    func testVMCloneColdSkipsTheWarmStart() throws {
        let root = try vmCloneScratch("cold")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try writeVMCloneWarmStart(projectKey: "github.com/o/r", snapshot: "snap_warm", machine: "vm-old", savedSecondsAgo: 60, home: home)
        let (plan, _) = try vmCloneDryRunPlan(["o/r", "--new", "--cold"], home: home)
        XCTAssertTrue(plan["warm_start"] is NSNull, "\(plan)")
        // A pinned machine never restores: the warm start only replaces a new machine.
        let (pinned, _) = try vmCloneDryRunPlan(["o/r", "--machine", "brave-otter"], home: home)
        XCTAssertTrue(pinned["warm_start"] is NSNull, "\(pinned)")
    }

    func testVMCloneSaveWarmSnapshotsAfterSetupBeforeTheAgent() throws {
        let root = try vmCloneScratch("savewarm")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try writeVMCloneWarmStart(projectKey: "github.com/acme/api", snapshot: "snap_previous", machine: "vm-old", savedSecondsAgo: 86_400, home: home)
        let output = "[cmux setup 1/2] exit 0\r\n[cmux setup 2/2] exit 0\r\n[cmux setup] done\r\n"
        let base = Self.vmCloneSetupResponder(setupOutput: output)
        let (result, log) = try runVMCloneAgainstMock(
            "vcw3",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--json", "--setup", "--save-warm", "--agent", "claude"],
            home: home
        ) { method, params in
            switch method {
            case "vm.snapshot": return ["id": "snap_new", "snapshot_id": "snap_new", "name": params["name"] ?? NSNull(), "created_at": 0]
            case "vm.snapshot_delete": return ["machine": "vm-old", "snapshot_id": "snap_previous", "deleted": true]
            default: return base(method, params)
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let methods = log.methods
        let snapshotIndex = try XCTUnwrap(methods.firstIndex(of: "vm.snapshot"), methods.description)
        let setupWait = try XCTUnwrap(methods.firstIndex(of: "vm.terminal_wait"), methods.description)
        let agentIndex = try XCTUnwrap(methods.lastIndex(of: "surface.new_terminal"), methods.description)
        XCTAssertLessThan(setupWait, snapshotIndex, "saved after setup")
        XCTAssertLessThan(snapshotIndex, agentIndex, "saved before the agent starts")
        let snapshot = try XCTUnwrap(log.params(ofFirst: "vm.snapshot"))
        XCTAssertEqual(snapshot["id"] as? String, "brave-otter")
        XCTAssertEqual(snapshot["name"] as? String, "cmux warm start github.com/acme/api")
        // The previous warm start of this repository is replaced and deleted.
        let deleted = try XCTUnwrap(log.params(ofFirst: "vm.snapshot_delete"), methods.description)
        XCTAssertEqual(deleted["id"] as? String, "vm-old")
        XCTAssertEqual(deleted["snapshot_id"] as? String, "snap_previous")
        let stored = try XCTUnwrap(readVMCloneWarmStarts(home: home)["github.com/acme/api"])
        XCTAssertEqual(stored["snapshot_id"] as? String, "snap_new")
        XCTAssertEqual(stored["machine"] as? String, "brave-otter")
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], result.stdout)
        XCTAssertEqual((payload["warm_saved"] as? [String: Any])?["snapshot_id"] as? String, "snap_new")
        XCTAssertNotNil((payload["timings"] as? [String: Any])?["warm_save"], "\(payload)")
    }

    func testVMCloneSavesAWarmStartWhenTheManifestAsksForOne() throws {
        let root = try vmCloneScratch("autowarm")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let manifest = #"{"setup": ["bun install"], "warm": true}"#
        let output = "[cmux setup 1/1] exit 0\r\n[cmux setup] done\r\n"
        let base = Self.vmCloneSetupResponder(setupOutput: output)
        let (result, log) = try runVMCloneAgainstMock(
            "vcw4",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--setup"],
            home: home
        ) { method, params in
            switch method {
            case "vm.exec": return ["exit_code": 0, "stdout": Self.vmCloneOutput(withCloudJSON: manifest), "stderr": ""]
            case "vm.snapshot": return ["id": "snap_auto", "snapshot_id": "snap_auto", "created_at": 0]
            default: return base(method, params)
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods.filter { $0 == "vm.snapshot" }.count, 1, log.methods.description)
        XCTAssertEqual(readVMCloneWarmStarts(home: home)["github.com/acme/api"]?["snapshot_id"] as? String, "snap_auto")

        // Without "warm": true (and without --save-warm) nothing is saved.
        let plainRoot = try vmCloneScratch("nowarm")
        defer { try? FileManager.default.removeItem(at: plainRoot) }
        let plainHome = plainRoot.appendingPathComponent("home")
        let (plain, plainLog) = try runVMCloneAgainstMock(
            "vcw5",
            arguments: ["vm", "clone", "acme/api", "--machine", "brave-otter", "--no-open", "--setup"],
            home: plainHome,
            respond: Self.vmCloneSetupResponder(setupOutput: "[cmux setup 1/2] exit 0\r\n[cmux setup 2/2] exit 0\r\n")
        )
        XCTAssertEqual(plain.status, 0, "stdout=\(plain.stdout) stderr=\(plain.stderr)")
        XCTAssertFalse(plainLog.methods.contains("vm.snapshot"), plainLog.methods.description)
    }

    func testVMCloneWakesAPausedMachineWithOneLine() throws {
        let root = try vmCloneScratch("wake")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try writeVMCloneBinding(projectKey: "github.com/o/r", machine: "vm-b", home: home)
        let vms: [[String: Any]] = [["id": "vm-b", "displayName": "brave-otter", "status": "paused"]]
        let (result, log) = try runVMCloneAgainstMock(
            "vcwk",
            arguments: ["vm", "clone", "o/r", "--no-open"],
            home: home
        ) { method, _ in
            switch method {
            case "vm.list": return ["vms": vms]
            case "vm.resume": return ["id": "vm-b", "status": "running"]
            case "vm.secrets_sync": return ["sent": [], "removed": [], "noop": true]
            case "vm.exec": return ["exit_code": 0, "stdout": "cmux-clone=updated\n", "stderr": ""]
            case "vm.workspace_new": return ["remote_workspace_id": "ws_3", "existing": true, "opened": false]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.list", "vm.resume", "vm.secrets_sync", "vm.exec", "vm.workspace_new"], log.methods.description)
        XCTAssertEqual(log.params(ofFirst: "vm.resume")?["id"] as? String, "vm-b")
        XCTAssertTrue(result.stderr.contains("Waking brave-otter\u{2026} "), result.stderr)
    }

    func testVMSnapshotWarmListsAndForgetsWarmStarts() throws {
        let root = try vmCloneScratch("warmls")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try writeVMCloneWarmStart(projectKey: "github.com/acme/api", snapshot: "snap_api", machine: "vm-old", savedSecondsAgo: 7_200, home: home)
        let (list, _) = try runVMCloneAgainstMock("vcwl", arguments: ["vm", "snapshot", "warm", "--json"], home: home) { _, _ in nil }
        XCTAssertEqual(list.status, 0, "stdout=\(list.stdout) stderr=\(list.stderr)")
        let listed = try XCTUnwrap(list.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], list.stdout)
        let rows = try XCTUnwrap(listed["warm_starts"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["project"] as? String }, ["github.com/acme/api"])
        XCTAssertEqual(rows.first?["snapshot_id"] as? String, "snap_api")

        // `rm` takes any repository spelling, forgets it, and deletes the snapshot on its machine.
        let (forget, log) = try runVMCloneAgainstMock("vcwr", arguments: ["vm", "snapshot", "warm", "rm", "acme/api"], home: home) { method, _ in
            method == "vm.snapshot_delete" ? ["deleted": true] : nil
        }
        XCTAssertEqual(forget.status, 0, "stdout=\(forget.stdout) stderr=\(forget.stderr)")
        XCTAssertEqual(log.params(ofFirst: "vm.snapshot_delete")?["id"] as? String, "vm-old")
        XCTAssertEqual(log.params(ofFirst: "vm.snapshot_delete")?["snapshot_id"] as? String, "snap_api")
        XCTAssertTrue(readVMCloneWarmStarts(home: home).isEmpty)
        XCTAssertTrue(forget.stdout.contains("deleted snapshot snap_api"), forget.stdout)
    }
}
