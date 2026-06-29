import Foundation
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

// A tagged dev build's DerivedData (or any app bundle) can be deleted while
// the app keeps running. Redirecting ZDOTDIR at a now-missing integration
// dir makes zsh silently skip the user's ~/.zshenv/.zprofile/.zshrc, because
// the bundled .zshenv that restores the real ZDOTDIR never runs. When the
// bundled bootstrap is unreadable, the spawn environment must be left
// untouched so the shell starts vanilla and the user's config still loads.
@Suite(.serialized)
struct ShellStartupMissingBundleTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let duration: TimeInterval
    }

    // The spawn-env call site only advertises CMUX_SHELL_INTEGRATION /
    // CMUX_SHELL_INTEGRATION_DIR when the bundled dir actually exists, so a
    // deleted app bundle never leaks a dangling integration path into the
    // shell environment.
    @Test
    func shellIntegrationDirectoryExistsRequiresARealDirectory() throws {
        let bundled = try makeBundledIntegrationDir(files: [".zshenv": "# cmux zsh bootstrap stub\n"])
        defer { try? FileManager.default.removeItem(at: bundled.root) }
        expectTrue(TerminalSurface.shellIntegrationDirectoryExists(bundled.integrationDir))

        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tests-deleted-bundle-\(UUID().uuidString)")
            .appendingPathComponent("shell-integration")
            .path
        expectFalse(TerminalSurface.shellIntegrationDirectoryExists(missingDir))

        // A plain file at the path does not count as the integration dir.
        let filePath = bundled.integrationDir + "/.zshenv"
        expectFalse(TerminalSurface.shellIntegrationDirectoryExists(filePath))
    }

    @Test
    func zshStartupLeavesUserConfigReachableWhenBundledZshenvIsMissing() {
        let missingIntegrationDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tests-deleted-bundle-\(UUID().uuidString)")
            .appendingPathComponent("shell-integration")
            .path
        let originalEnvironment = [
            "ZDOTDIR": "/Users/example/.zsh",
            "GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources",
        ]
        var environment = originalEnvironment
        var protectedKeys: Set<String> = []

        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/bin/zsh",
            integrationDir: missingIntegrationDir,
            userGhosttyShellIntegrationMode: "detect",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(command, nil)
        expectEqual(environment, originalEnvironment)
        expectTrue(protectedKeys.isEmpty)
    }

    @Test
    func fishStartupFallsBackToVanillaStartupWhenBundledConfigIsMissing() {
        let missingIntegrationDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tests-deleted-bundle-\(UUID().uuidString)")
            .appendingPathComponent("shell-integration")
            .path
        let originalEnvironment = ["XDG_CONFIG_HOME": "/Users/example/.config"]
        var environment = originalEnvironment
        var protectedKeys: Set<String> = []

        let command = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/opt/homebrew/bin/fish",
            integrationDir: missingIntegrationDir,
            userGhosttyShellIntegrationMode: "detect",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(command, nil)
        expectEqual(environment, originalEnvironment)
        expectTrue(protectedKeys.isEmpty)
    }

    // End-to-end repro of the dogfood report "new terminals don't respect
    // zshrc": spawn a real interactive zsh with the environment cmux produces
    // when the bundled integration dir has been deleted, and assert the user's
    // ~/.zshrc still ran.
    @Test
    func zshStillLoadsUserZshrcWhenBundledIntegrationDirIsDeleted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zshrc-deleted-bundle-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try "export CMUX_TEST_USER_ZSHRC=1\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let missingIntegrationDir = root
            .appendingPathComponent("deleted-bundle/Contents/Resources/shell-integration")
            .path

        var environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "USER": NSUserName(),
        ]
        var protectedKeys: Set<String> = []
        _ = TerminalSurface.applyManagedShellSpecificStartupEnvironment(
            shell: "/bin/zsh",
            integrationDir: missingIntegrationDir,
            userGhosttyShellIntegrationMode: "detect",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        // -i clears the ambient test-runner environment so only the spawn
        // environment computed above (plus zsh's own startup files) applies.
        let arguments = ["-i"] + environment.map { "\($0.key)=\($0.value)" } + [
            "/bin/zsh",
            "-ic",
            "print -rn -- \"user_zshrc_loaded=${CMUX_TEST_USER_ZSHRC:-no}\"",
        ]
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: arguments,
            timeout: 5
        )

        expectEqual(result.status, 0, result.stderr)
        expectFalse(result.timedOut, result.stderr)
        expectTrue(
            result.stdout.contains("user_zshrc_loaded=1"),
            "expected user .zshrc to load with a deleted integration dir; got stdout=\(result.stdout) stderr=\(result.stderr)"
        )
    }

    // End-to-end repro for the agent return-shell path: the launcher can
    // inherit a stale ZDOTDIR that points at a deleted app bundle's
    // shell-integration dir. The returned login zsh must fall back to the real
    // user ZDOTDIR/HOME so aliases defined at the bottom of ~/.zshrc are
    // available after the agent exits.
    @Test
    func zshReturnShellLoadsUserZshrcWhenBundledIntegrationDirIsDeleted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-return-zshrc-deleted-bundle-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        export CMUX_RETURN_TOP_MARKER=top
        alias cmux_return_bottom_alias='echo bottom'
        export CMUX_RETURN_BOTTOM_MARKER=bottom
        """
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let missingIntegrationDir = root
            .appendingPathComponent("deleted-bundle/Contents/Resources/shell-integration")
            .path
        let returnScriptURL = root.appendingPathComponent("return.zsh")
        let childProbeCommand = """
        print -r -- "child_top=${CMUX_RETURN_TOP_MARKER:-missing} child_bottom=${CMUX_RETURN_BOTTOM_MARKER:-missing}"
        if (( $+aliases[cmux_return_bottom_alias] )); then print -r -- child_alias=present; else print -r -- child_alias=missing; fi
        """
        try (
            "#!/bin/zsh\n"
                + TerminalStartupReturnShellScript.commandThenReturnLines(command: childProbeCommand).joined(separator: "\n")
                + "\n"
        )
        .write(to: returnScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: returnScriptURL.path)

        let driverURL = root.appendingPathComponent("drive-return-shell.zsh")
        let launchCommand = [
            "/usr/bin/env",
            "-i",
            "SHELL=/bin/zsh",
            "HOME=\(home.path)",
            "USER=\(NSUserName())",
            "PATH=/usr/bin:/bin",
            "TERM=xterm-256color",
            "CMUX_SHELL_INTEGRATION_DIR=\(missingIntegrationDir)",
            "ZDOTDIR=\(missingIntegrationDir)",
            returnScriptURL.path,
        ].map(zshSingleQuotedForTest).joined(separator: " ")
        try """
        zmodload zsh/zpty || exit 99
        zpty p \(zshSingleQuotedForTest(launchCommand))
        zpty -w p $'print -r -- "top=${CMUX_RETURN_TOP_MARKER:-missing} bottom=${CMUX_RETURN_BOTTOM_MARKER:-missing}"\\n'
        zpty -w p $'if (( $+aliases[cmux_return_bottom_alias] )); then print -r -- alias=present; else print -r -- alias=missing; fi\\n'
        zpty -w p $'exit\\n'
        local output
        local deadline=$(( SECONDS + 5 ))
        while (( SECONDS < deadline )); do
            if zpty -r -t p output; then
                print -rn -- "$output"
            else
                sleep 0.02
            fi
            zpty -t p 2>/dev/null || break
        done
        zpty -d p 2>/dev/null || true
        """
            .write(to: driverURL, atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: "/bin/zsh",
            arguments: ["-f", driverURL.path],
            timeout: 10
        )

        expectEqual(result.status, 0, result.stderr)
        expectFalse(result.timedOut, result.stderr)
        expectTrue(
            result.stdout.contains("child_top=top child_bottom=bottom"),
            "expected resumed command shell to fully source ~/.zshrc; stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        expectTrue(
            result.stdout.contains("child_alias=present"),
            "expected resumed command shell to see bottom-of-file alias; stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        expectTrue(
            result.stdout.contains("top=top bottom=bottom"),
            "expected returned shell to fully source ~/.zshrc; stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        expectTrue(
            result.stdout.contains("alias=present"),
            "expected bottom-of-file alias to survive return shell; stdout=\(result.stdout) stderr=\(result.stderr)"
        )
    }

    /// Creates a real on-disk stand-in for the app bundle's
    /// `Resources/shell-integration` dir containing the given relative files,
    /// since the production code verifies the bundled bootstrap exists before
    /// redirecting shell startup at it.
    private func makeBundledIntegrationDir(
        files: [String: String]
    ) throws -> (root: URL, integrationDir: String) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-shell-missing-bundle-\(UUID().uuidString)")
        let integrationDir = root.appendingPathComponent("shell-integration")
        for (relativePath, contents) in files {
            let fileURL = integrationDir.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return (root, integrationDir.path)
    }

    private func zshSingleQuotedForTest(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let start = Date()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false,
                duration: Date().timeIntervalSince(start)
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut,
            duration: Date().timeIntervalSince(start)
        )
    }
}
