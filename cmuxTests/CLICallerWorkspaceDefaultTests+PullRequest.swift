import Darwin
import Foundation
import Testing

extension CLICallerWorkspaceDefaultTests {
    /// Exercises the shipped executable, real Git worktree discovery, and
    /// line-framed socket writes. Only the GitHub network boundary is stubbed.
    @Test(arguments: ["number", "url", "explicit", "tty", "worktree", "ambiguous", "mismatch", "invalid", "clear", "blank", "option"])
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
        case "$1 $2" in
          'repo view') echo '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}' ;;
          'pr view')
            [ "$3" = 123 ] && [ "$4" = --repo ] && [ "$5" = owner/repo ] || exit 8
            echo '{"number":123,"url":"https://github.com/owner/repo/pull/123","state":"OPEN","headRefName":"handoff"}' ;;
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
        let handled = Self.startMockServer(listenerFD: listener, state: state) { line in
            guard let object = Self.jsonObject(line), let id = object["id"] as? String else {
                return "OK"
            }
            switch object["method"] as? String {
            case "system.identify":
                return Self.v2Response(id: id, ok: true, result: [
                    "caller": ["workspace_id": Self.otherWorkspaceId],
                    "focused": ["workspace_id": Self.focusedWorkspaceId]
                ])
            case "window.list":
                return Self.v2Response(id: id, ok: true, result: ["windows": [["id": Self.focusedWorkspaceId]]])
            case "workspace.list":
                var rows = [["id": Self.otherWorkspaceId, "current_directory": worktreePath, "remote": ["enabled": false]] as [String: Any]]
                if scenario == "ambiguous" { rows.append(["id": Self.focusedWorkspaceId, "current_directory": worktreePath]) }
                return Self.v2Response(id: id, ok: true, result: ["workspaces": rows])
            default:
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": line])
            }
        }
        var args = ["pr", "123"]
        switch scenario {
        case "url": args[1] = "https://github.com/owner/repo/pull/123?diff=split#discussion"
        case "explicit": args += ["--workspace", Self.otherWorkspaceId]
        case "tty": environment["CMUX_CLI_TTY_NAME"] = "ttys123"
        case "worktree", "ambiguous": environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        case "mismatch": args[1] = "https://github.com/other/repo/pull/123"
        case "invalid": args[1] = "https://example.com/pull/123"
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
        let shouldFail = ["ambiguous", "mismatch", "invalid", "blank", "option"].contains(scenario)
        #expect((result.status != 0) == shouldFail, Comment(rawValue: result.stderr))
        #expect(!lines.contains { $0.contains("workspace.current") || $0.contains("window.focus") })
        if shouldFail { #expect(mutations.isEmpty); return }
        let mutation = try #require(mutations.first)
        #expect(mutations.count == 1)
        let expected = ["explicit", "tty", "worktree"].contains(scenario) ? Self.otherWorkspaceId : Self.callerWorkspaceId
        #expect(mutation.contains("--tab=\(expected)"))
        if scenario == "clear" {
            #expect(mutation.contains("clear_workspace_pr"))
        } else {
            #expect(mutation.contains("report_workspace_pr"))
            #expect(mutation.contains("https://github.com/owner/repo/pull/123"))
            #expect(mutation.contains("--state=open"))
            #expect(mutation.contains("--branch=handoff"))
        }
    }
}
