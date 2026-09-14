import Foundation
import Testing

@Suite(.serialized)
struct CLICodexHookPathQuotingRegressionTests {
    @Test func codexInjectedHookScriptPathSurvivesShellEvaluationWhenHomeContainsShellCharacters() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux codex $hook 'home \(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux fake cli", isDirectory: false)
        let marker = root.appendingPathComponent("hook-marker", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "cat >/dev/null",
            "printf '%s\\n' \"$*\" >> \"$CMUX_TEST_HOOK_MARKER\"",
        ])

        var environment = codexHookTestEnvironment(root: root, codexHome: codexHome)
        environment["TMPDIR"] = root.path
        environment["CMUX_SURFACE_ID"] = "surface-codex-path-space"
        environment["CMUX_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["CMUX_TEST_HOOK_MARKER"] = marker.path

        let emit = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: environment,
            timeout: 10
        )
        #expect(!emit.timedOut, Comment(rawValue: emit.stderr))
        #expect(emit.status == 0, Comment(rawValue: emit.stderr))

        let lifecycleEvents = [
            (eventName: "SessionStart", subcommand: "session-start"),
            (eventName: "UserPromptSubmit", subcommand: "prompt-submit"),
            (eventName: "Stop", subcommand: "stop"),
        ]
        for event in lifecycleEvents {
            let command = try injectedCodexHookCommand(eventName: event.eventName, output: emit.stdout)
            #expect(command.contains("/.cmux/hooks/"))
            #expect(command.contains("-\(event.subcommand).sh"))
            let run = runCodexHookProcess(
                executablePath: "/bin/sh",
                arguments: ["-lc", command],
                environment: environment,
                standardInput: #"{"session_id":"codex-path-space","hook_event_name":"\#(event.eventName)"}"#,
                timeout: 5
            )
            #expect(
                run.status == 0,
                "\(event.eventName) command failed for a shell-significant home path: \(run.stderr)"
            )
            #expect(run.stdout == "{}\n")
            #expect(
                waitForFile(marker, containing: "hooks codex \(event.subcommand)", timeout: 2),
                "\(event.eventName) script did not reach the bundled cmux command"
            )
        }
    }

    @Test(arguments: ["install", "uninstall"])
    func codexHookOwnershipUsesFilesystemPathsWhenHomeContainsSemicolons(action: String) throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux codex $hook 'home; \(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyScript = hooksDirectory.appendingPathComponent("cmux-codex-hook-persistent-stop.sh")
        try makeCodexHookExecutableShellFile(at: legacyScript, lines: ["#!/bin/sh", "exit 0"])
        let userCommand = "/bin/true"
        let outsideCommand = root.appendingPathComponent("cmux-codex-hook-persistent-stop.sh").path
        let hooks: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [
                    ["type": "command", "command": legacyScript.path],
                    ["type": "command", "command": userCommand],
                    ["type": "command", "command": outsideCommand],
                ]]],
            ],
        ]
        let configFile = codexHome.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: hooks).write(to: configFile)
        let environment = codexHookTestEnvironment(root: root, codexHome: codexHome)

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", action, "--yes"],
            environment: environment,
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let entries = try codexHookEntries(in: codexHome)
        #expect(!entries.contains { $0.command == legacyScript.path })
        #expect(entries.filter { $0.command == userCommand }.count == 1)
        #expect(entries.filter { $0.command == outsideCommand }.count == 1)

        if action == "install" {
            let stopCommands = entries.filter { $0.eventName == "Stop" }.map(\.command)
            #expect(stopCommands.count == 3)
            let installed = try #require(stopCommands.first { $0 != userCommand && $0 != outsideCommand })
            #expect(installed.hasPrefix("'"))

            let uninstall = runCodexHookProcess(
                executablePath: cliPath,
                arguments: ["hooks", "codex", "uninstall", "--yes"],
                environment: environment,
                timeout: 10
            )
            #expect(!uninstall.timedOut, Comment(rawValue: uninstall.stderr))
            #expect(uninstall.status == 0, Comment(rawValue: uninstall.stderr))
            let remaining = try codexHookEntries(in: codexHome)
            #expect(Set(remaining.map(\.command)) == [userCommand, outsideCommand])
            #expect(remaining.count == 2)
        }
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }

    private func injectedCodexHookCommand(eventName: String, output: String) throws -> String {
        let argument = try #require(
            output.split(separator: "\0").map(String.init).first { $0.hasPrefix("hooks.\(eventName)=") },
            "missing injected \(eventName) argument"
        )
        let commandMarker = try #require(argument.range(of: "command='''"), "missing command field")
        let commandBody = argument[commandMarker.upperBound...]
        let commandEnd = try #require(commandBody.range(of: "''',timeout="), "missing command terminator")
        return String(commandBody[..<commandEnd.lowerBound])
    }
}
