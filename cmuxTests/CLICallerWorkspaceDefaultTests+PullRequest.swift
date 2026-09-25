import Darwin
import Foundation
import Testing

extension CLICallerWorkspaceDefaultTests {
    private static let hexWindowId = "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"

    /// Exercises the shipped executable, real Git worktree discovery, and
    /// line-framed socket writes. Only the GitHub network boundary is stubbed.
    @Test(arguments: ["number", "url", "fork-upstream", "fork-number", "explicit", "tty", "window", "window-mismatch", "worktree", "missing-directory", "nested-repository", "nested-valid", "nested-child", "nested-child-valid", "fake-git-directory", "ambiguous", "mismatch", "invalid", "gh-failure", "gh-malformed", "clear", "blank", "option"])
    func pullRequestHandoff(scenario: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pr-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = directory.appendingPathComponent("repo")
        let worktree = directory.appendingPathComponent("worktree")
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let socketPath = Self.makeSocketPath("pr")
        var environment = cliEnvironment(socketPath: socketPath, callerWorkspaceId: Self.callerWorkspaceId)
        for key in ["CMUX_SOCKET", "CMUX_SOCKET_PASSWORD", "CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY", "GH_REPO"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = bin.path + ":/usr/bin:/bin"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        for args in [
            ["init", repository.path],
            ["-C", repository.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "fixture"],
            ["-C", repository.path, "worktree", "add", "-b", "handoff", worktree.path]
        ] {
            let result = Self.runProcess(executablePath: "/usr/bin/git", arguments: args, environment: environment, timeout: 10)
            try #require(result.status == 0, Comment(rawValue: result.stderr))
        }
        let gh = bin.appendingPathComponent("gh")
        try #"""
        #!/bin/sh
        if [ "$GH_FAILURE" = 1 ]; then
          echo 'provider secret: do not expose this' >&2
          exit 9
        fi
        if [ "$GH_MALFORMED" = 1 ]; then
          echo '{not-json'
          exit 0
        fi
        expected_repo="owner/repo"
        expected_url="https://github.com/owner/repo/pull/123"
        if [ "$GH_FORK" = 1 ]; then
          expected_repo="upstream/repo"
          expected_url="https://github.com/upstream/repo/pull/123"
        fi
        case "$1 $2" in
          'repo view')
            if [ "$GH_FORK" = 1 ]; then
              echo '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo","parent":{"nameWithOwner":"upstream/repo"}}'
            else
              echo '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}'
            fi
            ;;
          'pr view')
            [ "$3" = 123 ] || exit 8
            if [ "$4" = --repo ]; then
              [ "$5" = "$expected_repo" ] || exit 8
            else
              [ "$4" = --json ] || exit 8
            fi
            echo '{"number":123,"url":"'"$expected_url"'","state":"OPEN","headRefName":"handoff"}' ;;
          *) exit 9 ;;
        esac
        """#.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let listener = try Self.bindUnixSocket(at: socketPath)
        let state = ServerState()
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listener)
            Darwin.close(listener)
            unlink(socketPath)
        }
        let worktreePath = worktree.path
        let workspaceDirectory: String = {
            switch scenario {
            case "missing-directory":
                return directory.appendingPathComponent("missing-workspace").path
            case "nested-repository", "nested-valid", "nested-child", "nested-child-valid":
                let nested = worktree.appendingPathComponent("nested-repository", isDirectory: true)
                let result = Self.runProcess(
                    executablePath: "/usr/bin/git",
                    arguments: ["init", nested.path],
                    environment: environment,
                    timeout: 10
                )
                precondition(result.status == 0, result.stderr)
                if ["nested-child", "nested-child-valid"].contains(scenario) {
                    let child = nested.appendingPathComponent("src/feature", isDirectory: true)
                    try! FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
                    return child.path
                }
                return nested.path
            case "fake-git-directory":
                let fake = worktree.appendingPathComponent("artifact", isDirectory: true)
                try! FileManager.default.createDirectory(
                    at: fake.appendingPathComponent(".git", isDirectory: true),
                    withIntermediateDirectories: true
                )
                for entry in ["HEAD", "config", "objects", "refs"] {
                    let url = fake.appendingPathComponent(".git").appendingPathComponent(entry)
                    if ["objects", "refs"].contains(entry) {
                        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    } else {
                        try! Data("artifact".utf8).write(to: url)
                    }
                }
                return fake.path
            default:
                return worktreePath
            }
        }()
        let handled = Self.startMockServer(listenerFD: listener, state: state) { line in
            guard let object = Self.jsonObject(line), let id = object["id"] as? String else {
                return "OK"
            }
            switch object["method"] as? String {
            case "system.identify":
                return Self.v2Response(id: id, ok: true, result: [
                    "caller": [
                        "workspace_id": Self.otherWorkspaceId,
                        "window_id": scenario == "window" ? Self.hexWindowId : Self.otherWorkspaceId
                    ],
                    "focused": ["workspace_id": Self.focusedWorkspaceId]
                ])
            case "window.list":
                return Self.v2Response(id: id, ok: true, result: ["windows": [["id": Self.focusedWorkspaceId]]])
            case "workspace.list":
                var rows = [["id": Self.otherWorkspaceId, "current_directory": workspaceDirectory, "remote": ["enabled": false]] as [String: Any]]
                if ["ambiguous", "nested-valid", "nested-child-valid"].contains(scenario) {
                    rows.append(["id": Self.focusedWorkspaceId, "current_directory": worktreePath])
                }
                return Self.v2Response(id: id, ok: true, result: ["workspaces": rows])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": line])
            }
        }
        var args = ["pr", "123"]
        switch scenario {
        case "url": args[1] = "https://github.com/owner/repo/pull/123/files?diff=split#discussion"
        case "fork-upstream":
            args[1] = "https://github.com/upstream/repo/pull/123"
            environment["GH_FORK"] = "1"
        case "fork-number": environment["GH_FORK"] = "1"
        case "explicit": args += ["--workspace", Self.otherWorkspaceId]
        case "tty": environment["CMUX_CLI_TTY_NAME"] = "ttys123"
        case "worktree", "missing-directory", "nested-repository", "nested-valid", "nested-child", "nested-child-valid", "fake-git-directory", "ambiguous": environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        case "window": args += ["--workspace", Self.otherWorkspaceId, "--window", Self.hexWindowId.lowercased()]
        case "window-mismatch": args += ["--workspace", Self.otherWorkspaceId, "--window", Self.focusedWorkspaceId]
        case "mismatch": args[1] = "https://github.com/other/repo/pull/123"
        case "invalid": args[1] = "https://example.com/pull/123"
        case "gh-failure": environment["GH_FAILURE"] = "1"
        case "gh-malformed": environment["GH_MALFORMED"] = "1"
        case "clear": args[1] = "clear"
        case "blank": args += ["--workspace", ""]
        case "option": args += ["--typo"]
        default: break
        }
        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(), arguments: args,
            environment: environment, timeout: 15, directory: worktree
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut)
        let lines = state.linesSnapshot()
        let mutations = lines.filter { $0.contains("workspace_pr") }
        let shouldFail = ["window-mismatch", "missing-directory", "nested-repository", "nested-child", "ambiguous", "mismatch", "invalid", "gh-failure", "gh-malformed", "blank", "option"].contains(scenario)
        #expect((result.status != 0) == shouldFail, Comment(rawValue: result.stderr))
        #expect(!lines.contains { $0.contains("workspace.current") || $0.contains("window.focus") })
        if shouldFail {
            #expect(mutations.isEmpty)
            if scenario == "gh-failure" {
                #expect(!result.stderr.contains("provider secret"))
                #expect(result.stderr.contains("check authentication"))
            }
            if scenario == "gh-malformed" {
                #expect(result.stderr.contains("invalid pull-request information"))
                #expect(!result.stderr.contains("not-json"))
            }
            return
        }
        let mutation = try #require(mutations.first)
        #expect(mutations.count == 1)
        let expected = ["explicit", "tty", "window", "worktree", "fake-git-directory"].contains(scenario)
            ? Self.otherWorkspaceId
            : (["nested-valid", "nested-child-valid"].contains(scenario) ? Self.focusedWorkspaceId : Self.callerWorkspaceId)
        #expect(mutation.contains("--tab=\(expected)"))
        if scenario == "clear" {
            #expect(mutation.contains("clear_workspace_pr"))
        } else {
            #expect(mutation.contains("report_workspace_pr"))
            let expectedURL = ["fork-upstream", "fork-number"].contains(scenario)
                ? "https://github.com/upstream/repo/pull/123"
                : "https://github.com/owner/repo/pull/123"
            #expect(mutation.contains(expectedURL))
            #expect(mutation.contains("--state=open"))
            #expect(mutation.contains("--branch=handoff"))
        }
    }
}
