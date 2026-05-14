import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    /// Regression test for the install cleanup logic. Older `cmux hooks
    /// setup` runs wrote `cmux <agent>-hook <sub>` and `cmux feed-hook
    /// --source <agent>` into per-agent hooks files. Running install on a
    /// newer CLI must recognize those legacy entries as cmux-owned and
    /// remove them, instead of stacking the new entries next to the old
    /// ones (which then keep firing at runtime).
    func testCursorHookInstallRemovesLegacyEntriesAndPreservesForeignEntries() throws {
        let cliPath = try bundledCLIPath()
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cursor-install-cleanup-\(UUID().uuidString)", isDirectory: true)
        let cursorDir = tempHome.appendingPathComponent(".cursor", isDirectory: true)
        let hooksPath = cursorDir.appendingPathComponent("hooks.json", isDirectory: false)

        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let foreignAfter = "/Users/example/.superconductor/hooks/cursor-notify.sh"
        let foreignBefore = "/Users/example/.vibe-island/bin/vibe-island-bridge --source cursor"
        let legacyShellExec = "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_CURSOR_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux cursor-hook shell-exec || echo '{}'"
        let legacyFeed = "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_CURSOR_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux feed-hook --source cursor || echo '{}'"
        let legacyPromptSubmit = "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_CURSOR_HOOKS_DISABLED\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && cmux cursor-hook prompt-submit || echo '{}'"

        let seed: [String: Any] = [
            "version": 1,
            "hooks": [
                "beforeShellExecution": [
                    ["command": foreignBefore],
                    ["command": legacyShellExec],
                    ["command": legacyFeed],
                ],
                "beforeSubmitPrompt": [
                    ["command": legacyPromptSubmit],
                    ["command": foreignAfter],
                ],
            ],
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed, options: [.prettyPrinted])
        try seedData.write(to: hooksPath, options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempHome.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["hooks", "cursor", "install", "--yes"],
            environment: environment,
            timeout: 15
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let resultData = try Data(contentsOf: hooksPath)
        let resultJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        let resultHooks = try XCTUnwrap(resultJSON["hooks"] as? [String: Any])

        let shellExecCommands = (resultHooks["beforeShellExecution"] as? [[String: Any]] ?? [])
            .compactMap { $0["command"] as? String }
        let promptSubmitCommands = (resultHooks["beforeSubmitPrompt"] as? [[String: Any]] ?? [])
            .compactMap { $0["command"] as? String }

        XCTAssertFalse(
            shellExecCommands.contains(legacyShellExec),
            "Legacy `cmux cursor-hook shell-exec` must be removed; commands: \(shellExecCommands)"
        )
        XCTAssertFalse(
            shellExecCommands.contains(legacyFeed),
            "Legacy `cmux feed-hook --source cursor` must be removed; commands: \(shellExecCommands)"
        )
        XCTAssertFalse(
            promptSubmitCommands.contains(legacyPromptSubmit),
            "Legacy `cmux cursor-hook prompt-submit` must be removed; commands: \(promptSubmitCommands)"
        )

        XCTAssertTrue(
            shellExecCommands.contains(foreignBefore),
            "Foreign vibe-island entry must be preserved; commands: \(shellExecCommands)"
        )
        XCTAssertTrue(
            promptSubmitCommands.contains(foreignAfter),
            "Foreign superconductor entry must be preserved; commands: \(promptSubmitCommands)"
        )

        let allCommands = (resultHooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 })
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(
            allCommands.contains(where: { $0.contains("cmux hooks cursor shell-exec") }),
            "Expected new `cmux hooks cursor shell-exec` entry to be written; commands: \(allCommands)"
        )
        XCTAssertTrue(
            allCommands.contains(where: { $0.contains("cmux hooks cursor prompt-submit") }),
            "Expected new `cmux hooks cursor prompt-submit` entry to be written; commands: \(allCommands)"
        )
    }
}
