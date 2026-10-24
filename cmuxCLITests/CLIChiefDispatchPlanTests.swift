import Foundation
import Testing

/// `cmux chief dispatch` parsing, quoting and screen reading. The plan is
/// compiled into this target from `CLI/ChiefDispatchPlan.swift`.
@Suite("cmux chief dispatch: plan")
struct CLIChiefDispatchPlanTests {
    // MARK: Parsing

    @Test func wordsAfterTheSeparatorAreTheTaskVerbatim() throws {
        let options = try ChiefDispatchOptions.parse([
            "--agent", "claude", "--name", "#12: docs", "--cwd", "/tmp/app", "--wait-working",
            "--", "--fix", "the", "--name", "flag",
        ])
        #expect(options.agent == .claude)
        #expect(options.name == "#12: docs")
        #expect(options.cwd == "/tmp/app")
        #expect(options.waitWorking)
        #expect(options.timeout == ChiefDispatchOptions.defaultTimeout)
        #expect(options.prompt == .words("--fix the --name flag"))
        #expect(options.focus == nil)
    }

    @Test func defaultsToCodexWithNormalPermissions() throws {
        let options = try ChiefDispatchOptions.parse(["--", "do it"])
        #expect(options.agent == .codex)
        #expect(options.agentCommand == ["codex"])
        #expect(!options.waitWorking)
    }

    @Test func inlineValuesAgentArgumentsFocusAndTimeout() throws {
        let options = try ChiefDispatchOptions.parse([
            "--agent=codex", "--agent-arg", "-m", "--agent-arg=--search", "--no-focus", "--timeout=90", "task",
        ])
        #expect(options.agentCommand == ["codex", "-m", "--search"])
        #expect(options.focus == false)
        #expect(options.timeout == 90)
        #expect(options.waitWorking, "--timeout implies --wait-working")
        #expect(options.prompt == .words("task"))
    }

    @Test func promptFileAndStandardInput() throws {
        #expect(try ChiefDispatchOptions.parse(["--prompt-file", "-"]).prompt == .standardInput)
        #expect(try ChiefDispatchOptions.parse(["--prompt-file", "task.md"]).prompt == .file("task.md"))
    }

    @Test func worktreeAndBranch() throws {
        let options = try ChiefDispatchOptions.parse(["--worktree", "/src/app", "--branch", "fix-it", "--", "x"])
        #expect(options.worktreeRepo == "/src/app")
        #expect(options.branch == "fix-it")
    }

    @Test(arguments: [
        ["--agent", "gemini", "--", "x"],          // unknown agent
        ["--"],                                     // no task
        ["--", "   "],                              // blank task
        [],                                         // no task
        ["--prompt-file", "-", "--", "x"],         // two task sources
        ["--branch", "b", "--", "x"],              // --branch without --worktree
        ["--cwd", "/a", "--worktree", "/b", "x"],  // both directories
        ["--timeout", "0", "x"],
        ["--timeout", "601", "x"],
        ["--timeout", "soon", "x"],
        ["--name", "", "x"],
        ["--name", "two\nlines", "x"],
        ["--bogus", "x"],
        ["--name"],                                 // missing value
    ])
    func rejects(_ args: [String]) {
        #expect(throws: CLIError.self) { try ChiefDispatchOptions.parse(args) }
    }

    @Test func helpOnlyBeforeTheSeparator() {
        #expect(ChiefDispatchOptions.isHelpRequest(["--help"]))
        #expect(ChiefDispatchOptions.isHelpRequest(["--agent", "codex", "-h"]))
        #expect(!ChiefDispatchOptions.isHelpRequest(["--", "document", "--help", "and", "-h"]))
    }

    @Test func normalizedPrompt() throws {
        #expect(try ChiefDispatchOptions.normalizedPrompt("  fix it \n") == "fix it")
        #expect(try ChiefDispatchOptions.normalizedPrompt("--help me") == " --help me")
        #expect(throws: CLIError.self) { try ChiefDispatchOptions.normalizedPrompt(" \n ") }
        #expect(throws: CLIError.self) {
            try ChiefDispatchOptions.normalizedPrompt(String(repeating: "a", count: ChiefDispatchOptions.maxPromptBytes + 1))
        }
    }

    @Test func titleDefaultsToTheTasksFirstLine() throws {
        let options = try ChiefDispatchOptions.parse(["--", "x"])
        #expect(options.title(prompt: "Fix   login\nthen more") == "Fix login")
        let long = ChiefDispatchOptions.defaultTitle(for: String(repeating: "word ", count: 20))
        #expect(long.count == 40)
        #expect(long.hasSuffix("…"))
    }

    // MARK: Layout

    @Test func slugAndWorktreePath() {
        #expect(ChiefDispatchPlan.slug("#123: Fix login!") == "123-fix-login")
        #expect(ChiefDispatchPlan.slug("日本語") == "agent")
        #expect(ChiefDispatchPlan.worktreePath(repo: "/src/app/", slug: "fix") == "/src/app-fix")
        #expect(ChiefDispatchPlan.worktreeAddArguments(repo: "/src/app", path: "/src/app-fix", branch: "fix")
            == ["-C", "/src/app", "worktree", "add", "-b", "fix", "--", "/src/app-fix"])
    }

    @Test func typedCommandOnlyNamesTheLauncher() {
        #expect(ChiefDispatchPlan.typedCommand(launcherPath: "/tmp/cmux-dispatch.ab/launch.sh")
            == " /bin/sh '/tmp/cmux-dispatch.ab/launch.sh'")
        #expect(ChiefDispatchPlan.shellWord("it's") == #"'it'"'"'s'"#)
    }

    /// The launcher hands the task to the agent as one argv word, byte for
    /// byte, and removes its directory. `printf %s` stands in for the agent.
    @Test func launcherPassesTheTaskAsOneArgumentAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dispatch-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = #"Fix "it's" $HOME `id` $(whoami) \n; rm -rf / && echo *"# + "\nsecond line"
        let promptPath = directory.appendingPathComponent("task.txt").path
        let scriptPath = directory.appendingPathComponent("launch.sh").path
        try Data(task.utf8).write(to: URL(fileURLWithPath: promptPath))
        let script = ChiefDispatchPlan.launcherScript(
            agentCommand: ["/usr/bin/printf", "%s"], promptPath: promptPath, directory: directory.path
        )
        try Data(script.utf8).write(to: URL(fileURLWithPath: scriptPath))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == task)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Screen

    @Test func codexWorkingRow() {
        let screen = "› Fix the login bug\n\n• Working (3s • esc to interrupt)\n\n  ⏎ send"
        #expect(ChiefDispatchScreenReading.read(screen, agent: .codex) == .working("• Working (3s • esc to interrupt)"))
        #expect(ChiefDispatchScreenReading.read("Working on it", agent: .codex) == .pending)
    }

    @Test func claudeSpinnerRowButNotItsStatusBar() {
        let bar = "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt"
        #expect(ChiefDispatchScreenReading.read(bar, agent: .claude) == .pending)
        let screen = "> Fix the README\n✻ Pondering… (5s · ↑ 1.2k tokens · esc to interrupt)\n\(bar)"
        #expect(ChiefDispatchScreenReading.read(screen, agent: .claude)
            == .working("✻ Pondering… (5s · ↑ 1.2k tokens · esc to interrupt)"))
    }

    @Test func blockedScreensAreReportedNotAnswered() {
        let trust = "Quick safety check\nYes, I trust this folder\nNo, exit"
        #expect(ChiefDispatchScreenReading.read(trust, agent: .claude) == .blocked(reason: "trust_prompt"))
        #expect(ChiefDispatchScreenReading.read("zsh: command not found: codex", agent: .codex)
            == .blocked(reason: "agent_not_found"))
        #expect(ChiefDispatchScreenReading.read("/tmp/x/launch.sh: line 5: exec: claude: not found", agent: .claude)
            == .blocked(reason: "agent_not_found"))
        #expect(ChiefDispatchScreenReading.read("user@mac app % ", agent: .codex) == .pending)
    }

    // MARK: Waiting on surface.wait_text_change

    @Test func aChangedScreenWithoutTheAgentWorkingWaitsAfterItsRevision() {
        let step = ChiefDispatchWaitStep.read(
            ["text": "user@mac app % ", "revision": "r1", "changed": true], agent: .codex
        )
        #expect(step == ChiefDispatchWaitStep(reading: .pending, revision: "r1", isFinal: false))
    }

    @Test func theWorkingRowEndsTheWait() {
        let step = ChiefDispatchWaitStep.read(
            ["text": "• Working (3s • esc to interrupt)", "revision": "r2", "changed": true], agent: .codex
        )
        #expect(step.reading == .working("• Working (3s • esc to interrupt)"))
        #expect(step.isFinal)
    }

    @Test func anUnchangedReplyIsTheAppsDeadlineAndKeepsTheLastReading() {
        let trust = "Do you trust the files in this folder?\n❯ 1. Yes, proceed"
        let step = ChiefDispatchWaitStep.read(["text": trust, "revision": "r3", "changed": false], agent: .claude)
        #expect(step.reading == ChiefDispatchScreenReading.read(trust, agent: .claude))
        #expect(step.isFinal)
    }

    @Test func aBlockingScreenThatChangedKeepsWaitingForSomeoneToAnswerIt() {
        let trust = "Do you trust the files in this folder?\n❯ 1. Yes, proceed"
        let step = ChiefDispatchWaitStep.read(["text": trust, "revision": "r4", "changed": true], agent: .claude)
        #expect(!step.isFinal, "a trust prompt may still be answered before the deadline")
        #expect(step.revision == "r4")
    }

    @Test func aReplyWithoutARevisionCannotBeWaitedAfter() {
        #expect(ChiefDispatchWaitStep.read(["text": ""], agent: .codex).isFinal)
        #expect(ChiefDispatchWaitStep.read(["text": "", "revision": ""], agent: .codex).isFinal)
    }
}
