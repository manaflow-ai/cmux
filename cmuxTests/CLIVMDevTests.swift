import CryptoKit
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Black-box coverage for `cmux vm dev`: the real CLI binary runs against a mock control
/// socket that plays the app's side of `vm.status`, `vm.exec`, `vm.workspace_new`,
/// `surface.catalog`, `vm.tree`, `vm.workspace_open`, and `vm.open_port`, so project
/// detection (through `--dry-run`, zero socket traffic), the exact socket sequence, the
/// layout document the in-VM shim receives, the reuse/idempotency rule, the sync step,
/// and the local-open policy are exercised as an agent hits them. CLI-target code is not
/// linked into this bundle (see CLIVMTransferTests), so the static helpers are verified
/// through their observable command lines and JSON.
extension CLINotifyProcessIntegrationRegressionTests {
    private final class VMDevRequestLog: @unchecked Sendable {
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

        func execCommands() -> [String] {
            snapshot().compactMap { request in
                guard (request["method"] as? String) == "vm.exec" else { return nil }
                return (request["params"] as? [String: Any])?["command"] as? String
            }
        }
    }

    /// Bytes a mock machine received through `vm push` chunks, so the finalize step can
    /// answer with the real digest.
    private final class VMDevPushSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        func digest() -> String {
            lock.lock()
            defer { lock.unlock() }
            return SHA256.hash(data: storage).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The base64 body of a `printf %s '<b64>' | base64 -d …` command.
    private static func vmDevBase64Payload(inCommand command: String) -> Data? {
        guard let start = command.range(of: "printf %s '"),
              let end = command.range(of: "' | base64 -d", range: start.upperBound..<command.endIndex) else { return nil }
        return Data(base64Encoded: String(command[start.upperBound..<end.lowerBound]))
    }

    /// The shim's `cmux layout apply --json` summary for the built-in dev layout.
    private static let vmDevApplySummary: [String: Any] = [
        "workspace_id": "ws_7",
        "workspace_name": "app",
        "panes": [
            ["pane_id": "pane_1", "surfaces": [["type": "terminal", "name": "dev", "terminal_id": "term_dev", "tab_id": "tab_1"]]],
            [
                "pane_id": "pane_2",
                "surfaces": [
                    ["type": "terminal", "name": "shell", "terminal_id": "term_shell", "tab_id": "tab_2"],
                    ["type": "browser", "name": "preview", "browser_id": "br_1", "tab_id": "tab_3"],
                ],
            ],
        ],
        "warnings": [],
    ]

    private static func vmDevJSONText(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func vmDevEnvironment(socketPath: String, home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // `vm dev` binds the folder to the machine in ~/.cmuxterm; keep that out of the
        // developer's home.
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        return environment
    }

    /// A scratch tree: `home/` for the CLI's state files and `project/<name>/` with the
    /// fixture files, each written from a `path: contents` table.
    private func vmDevFixture(_ name: String, files: [String: String]) throws -> (root: URL, home: URL, project: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-dev-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cmuxterm"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (root, home, project)
    }

    private func startVMDevMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMDevRequestLog,
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> [String: Any]?
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard let result = respond(method, params) else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            return self.v2Response(id: id, ok: true, result: result)
        }
    }

    /// One `cmux vm dev …` invocation against the mock; returns the process result and
    /// every request the mock saw.
    private func runVMDev(
        _ name: String,
        arguments: [String],
        home: URL,
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> [String: Any]?
    ) throws -> (result: ProcessRunResult, log: VMDevRequestLog) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMDevRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMDevMock(listenerFD: listenerFD, state: state, log: log, respond: respond)
        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: vmDevEnvironment(socketPath: socketPath, home: home),
            timeout: 60
        )
        wait(for: [serverHandled], timeout: 60)
        XCTAssertFalse(result.timedOut, "\(arguments) timed out: \(result.stderr)")
        return (result, log)
    }

    /// `--dry-run --json` never opens the socket: the plan is computed locally.
    private func vmDevDryRunPlan(_ name: String, project: URL, home: URL, extra: [String] = []) throws -> [String: Any] {
        let cliPath = try bundledCLIPath()
        let environment = vmDevEnvironment(socketPath: makeSocketPath("vm-dev-dry-\(name)"), home: home)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "dev", "brave-otter", project.path, "--dry-run", "--json"] + extra,
            environment: environment,
            timeout: 30
        )
        XCTAssertFalse(result.timedOut, "\(name) timed out")
        XCTAssertEqual(result.status, 0, "\(name): stdout=\(result.stdout) stderr=\(result.stderr)")
        guard let data = result.stdout.data(using: .utf8),
              let plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("\(name): dry-run did not print a JSON plan: \(result.stdout)")
            return [:]
        }
        return plan
    }

    // MARK: - Detection (dry run, no socket)

    func testVMDevDryRunDetectsProjectsWithoutTouchingTheSocket() throws {
        struct Case {
            let name: String
            let files: [String: String]
            let extra: [String]
            let command: String?
            let port: Int?
            let kind: String
            let sync: Bool
        }
        let cases: [Case] = [
            Case(
                name: "next-bun",
                files: ["package.json": #"{"scripts": {"dev": "next dev -p 4000"}, "dependencies": {"next": "15.0.0"}}"#, "bun.lockb": ""],
                extra: [], command: "bun install && bun run dev", port: 4000, kind: "node", sync: true
            ),
            Case(
                name: "vite-pnpm",
                files: ["package.json": #"{"scripts": {"dev": "vite --host"}}"#, "pnpm-lock.yaml": ""],
                extra: [], command: "pnpm install && pnpm run dev", port: 5173, kind: "node", sync: true
            ),
            Case(
                name: "start-only-yarn",
                files: ["package.json": #"{"scripts": {"start": "node server.js"}, "dependencies": {"express": "4"}}"#, "yarn.lock": ""],
                extra: [], command: "yarn install && yarn run start", port: nil, kind: "node", sync: true
            ),
            Case(
                name: "deps-decide-port",
                files: ["package.json": #"{"scripts": {"dev": "node --expose-gc scripts/dev.js"}, "devDependencies": {"astro": "4"}}"#],
                extra: [], command: "npm install && npm run dev", port: 4321, kind: "node", sync: true
            ),
            Case(name: "cargo", files: ["Cargo.toml": "[package]\nname = \"app\"\n"], extra: [], command: "cargo run", port: nil, kind: "cargo", sync: true),
            Case(name: "go", files: ["go.mod": "module app\n"], extra: [], command: "go run .", port: nil, kind: "go", sync: true),
            Case(name: "make", files: ["Makefile": ".PHONY: dev\nbuild:\n\techo build\ndev: build\n\techo dev\n"], extra: [], command: "make dev", port: nil, kind: "make", sync: true),
            Case(name: "make-without-dev", files: ["Makefile": "development:\n\techo x\n", "manage.py": "# django"], extra: [], command: "python manage.py runserver 0.0.0.0:8000", port: 8000, kind: "django", sync: true),
            Case(name: "uv", files: ["pyproject.toml": "[project]\nname = \"app\"\n", "uv.lock": ""], extra: [], command: "uv sync", port: nil, kind: "uv", sync: true),
            Case(name: "static", files: ["index.html": "<h1>hi</h1>"], extra: [], command: "python3 -m http.server 8000", port: 8000, kind: "static", sync: true),
            Case(name: "empty", files: ["notes.txt": "nothing to run"], extra: [], command: nil, port: nil, kind: "none", sync: true),
            Case(
                name: "override",
                files: ["package.json": #"{"scripts": {"dev": "next dev"}}"#],
                extra: ["--command", "bun run dev --host --port 9000"], command: "bun run dev --host --port 9000", port: 9000, kind: "node", sync: true
            ),
            Case(
                name: "override-port-flag",
                files: ["Cargo.toml": "[package]\nname = \"app\"\n"],
                extra: ["--port", "8080", "--no-sync"], command: "cargo run", port: 8080, kind: "cargo", sync: false
            ),
        ]
        for testCase in cases {
            let fixture = try vmDevFixture(testCase.name, files: testCase.files)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let plan = try vmDevDryRunPlan(testCase.name, project: fixture.project, home: fixture.home, extra: testCase.extra)
            XCTAssertEqual(plan["dry_run"] as? Bool, true, testCase.name)
            XCTAssertEqual(plan["machine"] as? String, "brave-otter", testCase.name)
            XCTAssertEqual(plan["remote"] as? String, "work/\(testCase.name)", testCase.name)
            XCTAssertEqual(plan["workspace_name"] as? String, testCase.name, testCase.name)
            XCTAssertEqual(plan["sync"] as? Bool, testCase.sync, testCase.name)
            XCTAssertEqual((plan["detected"] as? [String: Any])?["kind"] as? String, testCase.kind, testCase.name)
            if let command = testCase.command {
                XCTAssertEqual(plan["command"] as? String, command, testCase.name)
            } else {
                XCTAssertTrue(plan["command"] is NSNull, "\(testCase.name): expected no command, got \(String(describing: plan["command"]))")
            }
            if let port = testCase.port {
                XCTAssertEqual(plan["port"] as? Int, port, testCase.name)
            } else {
                XCTAssertTrue(plan["port"] is NSNull, "\(testCase.name): expected no port, got \(String(describing: plan["port"]))")
            }
            // The plan carries the exact document the machine would receive.
            let layout = plan["layout"] as? [String: Any]
            XCTAssertEqual(layout?["name"] as? String, testCase.name, testCase.name)
            XCTAssertEqual(layout?["cwd"] as? String, "work/\(testCase.name)", testCase.name)
            let node = layout?["layout"] as? [String: Any]
            if testCase.command != nil {
                XCTAssertEqual(node?["direction"] as? String, "horizontal", testCase.name)
                XCTAssertEqual(node?["split"] as? Double, 0.62, testCase.name)
                let children = (node?["children"] as? [[String: Any]]) ?? []
                XCTAssertEqual(children.count, 2, testCase.name)
                let dev = ((children.first?["pane"] as? [String: Any])?["surfaces"] as? [[String: Any]])?.first
                XCTAssertEqual(dev?["name"] as? String, "dev", testCase.name)
                XCTAssertEqual(dev?["command"] as? String, testCase.command, testCase.name)
                XCTAssertEqual(dev?["cwd"] as? String, "work/\(testCase.name)", testCase.name)
                XCTAssertEqual(dev?["focus"] as? Bool, false, testCase.name)
                let shellSurfaces = ((children.last?["pane"] as? [String: Any])?["surfaces"] as? [[String: Any]]) ?? []
                XCTAssertEqual(shellSurfaces.first?["name"] as? String, "shell", testCase.name)
                XCTAssertEqual(shellSurfaces.first?["focus"] as? Bool, true, testCase.name)
                if let port = testCase.port {
                    XCTAssertEqual(shellSurfaces.count, 2, testCase.name)
                    XCTAssertEqual(shellSurfaces.last?["type"] as? String, "browser", testCase.name)
                    XCTAssertEqual(shellSurfaces.last?["url"] as? String, "http://localhost:\(port)", testCase.name)
                } else {
                    XCTAssertEqual(shellSurfaces.count, 1, "\(testCase.name): no port means no browser tab")
                }
            } else {
                // Nothing to run: a single shell pane, no split.
                XCTAssertNil(node?["direction"], testCase.name)
                let surfaces = ((node?["pane"] as? [String: Any])?["surfaces"] as? [[String: Any]]) ?? []
                XCTAssertEqual(surfaces.map { $0["name"] as? String }, ["shell"], testCase.name)
            }
        }
    }

    func testVMDevDryRunHumanPlanAndRemoteNameOverrides() throws {
        let fixture = try vmDevFixture("web", files: ["package.json": #"{"scripts": {"dev": "vite"}}"#])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cliPath = try bundledCLIPath()
        let environment = vmDevEnvironment(socketPath: makeSocketPath("vm-dev-dry-human"), home: fixture.home)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--name", "frontend", "--remote", "/srv/web", "--dry-run"],
            environment: environment,
            timeout: 30
        )
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("plan: \(fixture.project.path) → brave-otter:/srv/web"), result.stdout)
        XCTAssertTrue(result.stdout.contains("plan: sync on"), result.stdout)
        XCTAssertTrue(result.stdout.contains("plan: dev: npm install && npm run dev (port 5173)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("plan: workspace frontend (get-or-create), built-in dev layout, opened here"), result.stdout)
        // The plan ends with the document itself (pretty JSON): parse it from the first `{`.
        let jsonStart = try XCTUnwrap(result.stdout.range(of: "\n{")?.upperBound, result.stdout)
        let documentText = "{" + result.stdout[jsonStart...]
        let document = try XCTUnwrap(documentText.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any], documentText)
        XCTAssertEqual(document["name"] as? String, "frontend")
        XCTAssertEqual(document["cwd"] as? String, "/srv/web")
    }

    // MARK: - The socket sequence

    func testVMDevBuildsTheLayoutInAFreshWorkspaceAndOpensItHere() throws {
        let fixture = try vmDevFixture("app", files: ["package.json": #"{"scripts": {"dev": "next dev"}}"#, "bun.lock": ""])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let summary = Self.vmDevJSONText(Self.vmDevApplySummary)
        let (result, log) = try runVMDev(
            "vm-dev-fresh",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync"],
            home: fixture.home
        ) { method, params in
            switch method {
            case "vm.status": return ["id": params["id"] ?? "?", "status": "running"]
            case "vm.exec": return ["exit_code": 0, "stdout": summary, "stderr": ""]
            case "vm.tree": return ["machines": [["id": "brave-otter", "remote_workspaces": []]], "resources": []]
            case "vm.workspace_open": return ["workspace_id": "3F1C7A2E-0000-4000-8000-000000000007", "opened": 2, "empty": false]
            case "vm.open_port": return ["url": "http://internal:3000", "token": "t", "open_url": "https://brave-otter-3000.example.test/"]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(
            log.methods,
            ["vm.status", "vm.tree", "vm.exec", "vm.tree", "vm.workspace_open", "vm.open_port"],
            log.methods.description
        )

        // New workspaces are created by the layout shim with --name; vm.workspace_new is not
        // used because its --no-open contract intentionally creates a starter shell.
        let commands = log.execCommands()
        XCTAssertEqual(commands.count, 1, commands.description)
        let apply = commands[0]
        XCTAssertTrue(apply.hasSuffix("| base64 -d | cmux layout apply --json --name app -"), apply)
        let document = try XCTUnwrap(Self.vmDevBase64Payload(inCommand: apply).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        XCTAssertEqual(document["name"] as? String, "app")
        XCTAssertEqual(document["cwd"] as? String, "work/app")
        let node = try XCTUnwrap(document["layout"] as? [String: Any])
        let children = try XCTUnwrap(node["children"] as? [[String: Any]])
        let dev = try XCTUnwrap(((children[0]["pane"] as? [String: Any])?["surfaces"] as? [[String: Any]])?.first)
        XCTAssertEqual(dev["command"] as? String, "bun install && bun run dev")
        let shellSurfaces = try XCTUnwrap((children[1]["pane"] as? [String: Any])?["surfaces"] as? [[String: Any]])
        XCTAssertEqual(shellSurfaces.last?["url"] as? String, "http://localhost:3000")
        XCTAssertEqual(log.params(ofFirst: "vm.exec")?["timeout_ms"] as? Int, 120_000)

        XCTAssertEqual(log.params(ofFirst: "vm.tree")?["refresh"] as? Bool, true)
        XCTAssertEqual(log.params(ofFirst: "vm.workspace_open")?["workspace_id"] as? String, "ws_7")
        XCTAssertEqual(log.params(ofFirst: "vm.open_port")?["port"] as? Int, 3000)

        for expected in [
            "route ok: brave-otter status=running",
            "sync skipped → using brave-otter:work/app as it is",
            "dev: bun install && bun run dev (port 3000)",
            "workspace app = ws_7 (new)",
            "layout applied: 2 panes, dev terminal term_dev, shell terminal term_shell",
            "opened locally: workspace 3F1C7A2E-0000-4000-8000-000000000007",
            "url: https://brave-otter-3000.example.test/",
            "next: cmux vm terminal output brave-otter term_dev",
            "next: cmux vm terminal send brave-otter term_shell",
        ] {
            XCTAssertTrue(result.stdout.contains(expected), "missing '\(expected)' in:\n\(result.stdout)")
        }

        // The folder is now bound to the machine, the way `vm run --sync` binds it.
        let bindings = fixture.home.appendingPathComponent(".cmuxterm/vm-run-bindings.json")
        let bindingText = (try? String(contentsOf: bindings, encoding: .utf8)) ?? ""
        XCTAssertTrue(bindingText.contains("brave-otter"), "expected a directory→machine binding, got: \(bindingText)")
    }

    func testVMDevJSONReportsEveryStep() throws {
        let fixture = try vmDevFixture("app", files: ["package.json": #"{"scripts": {"dev": "next dev"}}"#])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let summary = Self.vmDevJSONText(Self.vmDevApplySummary)
        let (result, _) = try runVMDev(
            "vm-dev-json",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync", "--json"],
            home: fixture.home
        ) { method, _ in
            switch method {
            case "vm.status": return ["status": "running"]
            case "vm.exec": return ["exit_code": 0, "stdout": summary, "stderr": ""]
            case "vm.tree": return ["machines": [["id": "brave-otter", "remote_workspaces": []]], "resources": []]
            case "vm.workspace_open": return ["workspace_id": "LOCAL-7", "opened": 2]
            case "vm.open_port": return ["open_url": "https://brave-otter-3000.example.test/"]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let payload = try XCTUnwrap(result.stdout.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        XCTAssertEqual(payload["machine"] as? String, "brave-otter")
        XCTAssertEqual(payload["workspace_id"] as? String, "ws_7")
        XCTAssertEqual(payload["local_workspace_id"] as? String, "LOCAL-7")
        XCTAssertEqual(payload["workspace_name"] as? String, "app")
        XCTAssertEqual(payload["existing"] as? Bool, false)
        XCTAssertEqual(payload["remote"] as? String, "work/app")
        XCTAssertEqual(payload["synced"] as? Bool, false)
        XCTAssertEqual(payload["command"] as? String, "npm install && npm run dev")
        XCTAssertEqual(payload["port"] as? Int, 3000)
        XCTAssertEqual(payload["url"] as? String, "https://brave-otter-3000.example.test/")
        XCTAssertEqual((payload["terminals"] as? [String: Any])?["dev"] as? String, "term_dev")
        XCTAssertEqual((payload["terminals"] as? [String: Any])?["shell"] as? String, "term_shell")
        XCTAssertEqual(payload["layout_applied"] as? Bool, true)
        XCTAssertEqual(payload["opened"] as? Bool, true)
        XCTAssertNotNil(payload["layout"] as? [String: Any], "the shim's apply summary rides along")
    }

    func testVMDevNoOpenStagesTheWorkspaceAndSkipsPortMinting() throws {
        let fixture = try vmDevFixture("api", files: ["Cargo.toml": "[package]\nname = \"api\"\n"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let summary = Self.vmDevJSONText([
            "workspace_id": "ws_9", "workspace_name": "api", "warnings": ["could not focus pane p1"],
            "panes": [
                ["pane_id": "p1", "surfaces": [["type": "terminal", "name": "dev", "terminal_id": "term_a", "tab_id": "t1"]]],
                ["pane_id": "p2", "surfaces": [["type": "terminal", "name": "shell", "terminal_id": "term_b", "tab_id": "t2"]]],
            ],
        ])
        let (result, log) = try runVMDev(
            "vm-dev-no-open",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync", "--no-open"],
            home: fixture.home
        ) { method, _ in
            switch method {
            case "vm.status": return ["status": "paused"]
            case "vm.tree": return ["machines": [["id": "brave-otter", "remote_workspaces": []]], "resources": []]
            case "vm.exec": return ["exit_code": 0, "stdout": summary, "stderr": ""]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.status", "vm.tree", "vm.exec"], "no local open, no port without one: \(log.methods)")
        XCTAssertTrue(result.stdout.contains("staged: cmux vm workspace open brave-otter ws_9"), result.stdout)
        XCTAssertTrue(result.stdout.contains("dev: cargo run\n"), result.stdout)
        XCTAssertFalse(result.stdout.contains("url:"), result.stdout)
        XCTAssertTrue(result.stderr.contains("warning: could not focus pane p1"), "shim warnings are forwarded: \(result.stderr)")
        // A single-pane document when nothing needs a port: no browser surface.
        let document = try XCTUnwrap(Self.vmDevBase64Payload(inCommand: log.execCommands()[0]).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        let children = try XCTUnwrap((document["layout"] as? [String: Any])?["children"] as? [[String: Any]])
        let shellSurfaces = try XCTUnwrap((children[1]["pane"] as? [String: Any])?["surfaces"] as? [[String: Any]])
        XCTAssertEqual(shellSurfaces.count, 1)
    }

    func testVMDevReusesAnExistingWorkspaceWithPanesInsteadOfStackingASecondServer() throws {
        let fixture = try vmDevFixture("app", files: ["package.json": #"{"scripts": {"dev": "next dev"}}"#])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (result, log) = try runVMDev(
            "vm-dev-reuse",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync"],
            home: fixture.home
        ) { method, _ in
            switch method {
            case "vm.status": return ["status": "running"]
            case "vm.tree":
                return [
                    "machines": [["id": "brave-otter", "remote_workspaces": [["id": "ws_7", "name": "app"]]]],
                    "resources": [[
                        "id": "brave-otter/terminal/term_dev", "machine": "brave-otter", "kind": "terminal", "key": "term_dev",
                        "title": "dev", "lifecycle": "running",
                        "remote_views": [["tab_id": "tab_1", "workspace": ["id": "ws_7", "name": "app"], "name": "dev", "focused": true]],
                    ], [
                        "id": "brave-otter/terminal/term_shell", "machine": "brave-otter", "kind": "terminal", "key": "term_shell",
                        "title": "shell", "lifecycle": "running",
                        "remote_views": [["tab_id": "tab_2", "workspace": ["id": "ws_7", "name": "app"], "name": "shell", "focused": false]],
                    ]],
                ]
            case "vm.workspace_open": return ["workspace_id": "LOCAL-7", "opened": 2]
            case "vm.open_port": return ["open_url": "https://brave-otter-3000.example.test/"]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(
            log.methods,
            ["vm.status", "vm.tree", "vm.tree", "vm.workspace_open", "vm.open_port"],
            "an already-built workspace must not receive a second layout: \(log.methods)"
        )
        XCTAssertTrue(result.stdout.contains("workspace app = ws_7 (existing)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("layout kept: ws_7 already has panes"), result.stdout)
        XCTAssertTrue(result.stdout.contains("opened locally: workspace LOCAL-7"), result.stdout)

        let (jsonResult, _) = try runVMDev(
            "vm-dev-reuse-json",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync", "--no-open", "--json"],
            home: fixture.home
        ) { method, _ in
            switch method {
            case "vm.status": return ["status": "running"]
            case "vm.tree":
                return [
                    "machines": [["id": "brave-otter", "remote_workspaces": [["id": "ws_7", "name": "app"]]]],
                    "resources": [
                        ["id": "brave-otter/terminal/term_dev", "machine": "brave-otter", "kind": "terminal", "key": "term_dev", "title": "dev", "lifecycle": "running", "remote_views": [["tab_id": "tab_1", "workspace": ["id": "ws_7"], "name": "dev"]]],
                        ["id": "brave-otter/terminal/term_shell", "machine": "brave-otter", "kind": "terminal", "key": "term_shell", "title": "shell", "lifecycle": "running", "remote_views": [["tab_id": "tab_2", "workspace": ["id": "ws_7"], "name": "shell"]]],
                    ]
                ]
            case "vm.open_port": return ["open_url": "https://brave-otter-3000.example.test/"]
            default: return nil
            }
        }
        XCTAssertEqual(jsonResult.status, 0, "stdout=\(jsonResult.stdout) stderr=\(jsonResult.stderr)")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["workspace_id"] as? String, "ws_7")
        let jsonTerminals = try XCTUnwrap(json["terminals"] as? [String: Any])
        XCTAssertEqual(jsonTerminals["dev"] as? String, "term_dev")
        XCTAssertEqual(jsonTerminals["shell"] as? String, "term_shell")

        // An existing but still-empty workspace (staged earlier with --no-open) does get the layout.
        let summary = Self.vmDevJSONText(Self.vmDevApplySummary)
        let (staged, stagedLog) = try runVMDev(
            "vm-dev-reuse-empty",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync", "--no-open"],
            home: fixture.home
        ) { method, _ in
            switch method {
            case "vm.status": return ["status": "running"]
            case "vm.tree": return ["machines": [["id": "brave-otter", "remote_workspaces": [["id": "ws_7", "name": "app"]]]], "resources": []]
            case "vm.exec": return ["exit_code": 0, "stdout": summary, "stderr": ""]
            case "vm.open_port": return ["open_url": "https://brave-otter-3000.example.test/"]
            default: return nil
            }
        }
        XCTAssertEqual(staged.status, 0, "stdout=\(staged.stdout) stderr=\(staged.stderr)")
        XCTAssertEqual(stagedLog.methods, ["vm.status", "vm.tree", "vm.exec", "vm.open_port"], stagedLog.methods.description)
        XCTAssertTrue(staged.stdout.contains("layout applied: 2 panes"), staged.stdout)
        XCTAssertTrue(staged.stdout.contains("url: https://brave-otter-3000.example.test/"), staged.stdout)
    }

    func testVMDevKeepsAnExistingWorkspaceWhoseOnlyPaneExited() throws {
        // A workspace whose dev server exited still owns that pane on the daemon;
        // the shim refuses to lay out a non-empty workspace, so `vm dev` must keep
        // the layout (and point at `workspace rm`) instead of applying a second one.
        let fixture = try vmDevFixture("app", files: ["package.json": #"{"scripts": {"dev": "node server.js"}}"#])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (result, log) = try runVMDev(
            "vm-dev-reuse-exited",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync", "--no-open"],
            home: fixture.home
        ) { method, _ in
            switch method {
            case "vm.status": return ["status": "running"]
            case "vm.tree":
                return [
                    "machines": [["id": "brave-otter", "remote_workspaces": [["id": "ws_7", "name": "app"]]]],
                    "resources": [[
                        "id": "brave-otter/terminal/term_dev", "machine": "brave-otter", "kind": "terminal", "key": "term_dev",
                        "title": "dev", "lifecycle": "exited",
                        "remote_views": [["tab_id": "tab_1", "workspace": ["id": "ws_7", "name": "app"], "name": "dev", "focused": true]],
                    ]],
                ]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.status", "vm.tree"], "an exited pane must not trigger a second layout: \(log.methods)")
        XCTAssertTrue(result.stdout.contains("layout kept: ws_7 already has panes"), result.stdout)
        XCTAssertFalse(result.stdout.contains("layout applied"), result.stdout)
    }

    func testVMDevFailsClosedWhenExistingWorkspacePlacementIsUnavailable() throws {
        let fixture = try vmDevFixture("app", files: ["package.json": #"{"scripts": {"dev": "next dev"}}"#])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for lifecycle in ["running", "exited"] {
            let (result, log) = try runVMDev(
                "vm-dev-unavailable-placement-\(lifecycle)",
                arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-sync", "--no-open"],
                home: fixture.home
            ) { method, _ in
                switch method {
                case "vm.status": return ["status": "running"]
                case "vm.tree":
                    return [
                        "machines": [["id": "brave-otter", "remote_workspaces": [["id": "ws_7", "name": "app"]]]],
                        "resources": [[
                            "id": "brave-otter/terminal/term_dev",
                            "machine": "brave-otter",
                            "kind": "terminal",
                            "key": "term_dev",
                            "lifecycle": lifecycle,
                            "remote_workspace": ["id": "ws_other", "name": "other"],
                            "remote_views": ["invalid": true],
                        ]],
                    ]
                default: return nil
                }
            }
            XCTAssertNotEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
            XCTAssertTrue(result.stderr.contains("terminal placement for workspace ws_7 on brave-otter is unavailable"), result.stderr)
            XCTAssertEqual(log.methods, ["vm.status", "vm.tree"], log.methods.description)
        }
    }

    func testVMDevSyncPushesTheFolderBeforeBuildingTheWorkspace() throws {
        let fixture = try vmDevFixture("site", files: [
            "package.json": #"{"scripts": {"dev": "vite"}}"#,
            "src/main.ts": "console.log('hi')\n",
            "node_modules/left-pad/index.js": "module.exports = 1\n",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sink = VMDevPushSink()
        let summary = Self.vmDevJSONText(Self.vmDevApplySummary)
        let (result, log) = try runVMDev(
            "vm-dev-sync",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--no-open"],
            home: fixture.home
        ) { method, params in
            switch method {
            case "vm.status": return ["status": "running"]
            case "vm.exec":
                let command = (params["command"] as? String) ?? ""
                if command.contains("cmux layout apply") {
                    return ["exit_code": 0, "stdout": summary, "stderr": ""]
                }
                if command.contains("| base64 -d >>"), let chunk = Self.vmDevBase64Payload(inCommand: command) {
                    sink.append(chunk)
                    return ["exit_code": 0, "stdout": "", "stderr": ""]
                }
                if command.contains("sha256sum") {
                    return ["exit_code": 0, "stdout": "\(sink.digest())  /tmp/staging\n", "stderr": ""]
                }
                return ["exit_code": 0, "stdout": "", "stderr": ""]
            case "vm.tree": return ["machines": [["id": "brave-otter", "remote_workspaces": []]], "resources": []]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let commands = log.execCommands()
        // The push (init, chunks, digest, extract into the remote path) runs before the
        // workspace exists; the layout apply is the last exec.
        let extractIndex = try XCTUnwrap(commands.firstIndex { $0.contains("tar -xzf") && $0.contains("-C work/site") }, commands.description)
        let applyIndex = try XCTUnwrap(commands.firstIndex { $0.contains("cmux layout apply") })
        XCTAssertLessThan(extractIndex, applyIndex)
        let applyExecIndex = try XCTUnwrap(log.methods.lastIndex(of: "vm.exec"))
        let lastPushExecIndex = try XCTUnwrap(log.methods.indices.filter { log.methods[$0] == "vm.exec" }.dropLast().last)
        XCTAssertLessThan(lastPushExecIndex, applyExecIndex, "every push exec precedes layout apply: \(log.methods)")
        XCTAssertTrue(result.stdout.contains("synced 2 files → brave-otter:work/site"), "node_modules is excluded by the push defaults: \(result.stdout)")
        XCTAssertTrue(result.stdout.contains("dev: npm install && npm run dev (port 5173)"), result.stdout)
    }

    // MARK: - Failing early

    func testVMDevRejectsBadInputBeforeAnyRequest() throws {
        let fixture = try vmDevFixture("app", files: ["package.json": #"{"scripts": {"dev": "next dev"}}"#, "bad-layout.json": #"{"direction": "diagonal", "children": []}"#])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let badLayout = fixture.project.appendingPathComponent("bad-layout.json").path

        let (invalidLayout, invalidLog) = try runVMDev(
            "vm-dev-bad-layout",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--layout", badLayout],
            home: fixture.home
        ) { _, _ in nil }
        XCTAssertEqual(invalidLayout.status, 2, "stdout=\(invalidLayout.stdout) stderr=\(invalidLayout.stderr)")
        XCTAssertTrue(invalidLayout.stderr.contains("invalid layout document"), invalidLayout.stderr)
        XCTAssertTrue(invalidLayout.stderr.contains("$.direction"), "the JSON path is named: \(invalidLayout.stderr)")
        XCTAssertTrue(invalidLog.methods.isEmpty, invalidLog.methods.description)

        let (missingFolder, missingLog) = try runVMDev(
            "vm-dev-missing-folder",
            arguments: ["vm", "dev", "brave-otter", fixture.project.appendingPathComponent("nope").path],
            home: fixture.home
        ) { _, _ in nil }
        XCTAssertNotEqual(missingFolder.status, 0)
        XCTAssertTrue(missingFolder.stderr.contains("no such folder"), missingFolder.stderr)
        XCTAssertTrue(missingLog.methods.isEmpty, missingLog.methods.description)

        let (badPort, badPortLog) = try runVMDev(
            "vm-dev-bad-port",
            arguments: ["vm", "dev", "brave-otter", fixture.project.path, "--port", "http"],
            home: fixture.home
        ) { _, _ in nil }
        XCTAssertNotEqual(badPort.status, 0)
        XCTAssertTrue(badPort.stderr.contains("--port must be a port number"), badPort.stderr)
        XCTAssertTrue(badPortLog.methods.isEmpty, badPortLog.methods.description)

        let (noMachine, noMachineLog) = try runVMDev(
            "vm-dev-no-machine",
            arguments: ["vm", "dev"],
            home: fixture.home
        ) { _, _ in nil }
        XCTAssertNotEqual(noMachine.status, 0)
        XCTAssertTrue(noMachine.stderr.contains("Usage: cmux vm dev <machine>"), noMachine.stderr)
        XCTAssertTrue(noMachineLog.methods.isEmpty, noMachineLog.methods.description)
    }

    func testVMDevHelpPrintsItsUsageWithoutASocket() throws {
        let cliPath = try bundledCLIPath()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-vm-dev-help-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = vmDevEnvironment(socketPath: makeSocketPath("vm-dev-help"), home: home)
        for arguments in [["vm", "dev", "--help"], ["vm", "dev", "-h"]] {
            let result = runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 30)
            XCTAssertFalse(result.timedOut, "\(arguments) timed out")
            XCTAssertEqual(result.status, 0, "\(arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
            for expected in ["Usage: cmux vm dev <machine>", "--dry-run", "--no-sync", "package.json", "Cargo.toml", "manage.py"] {
                XCTAssertTrue(result.stdout.contains(expected), "\(arguments) should mention '\(expected)':\n\(result.stdout)")
            }
        }
    }
}
