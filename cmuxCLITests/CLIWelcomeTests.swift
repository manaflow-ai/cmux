import Foundation
import Testing

@Suite(.serialized)
struct CLIWelcomeTests {
    @Test("welcome keeps the v0.64.25 shortcut list and footer")
    func welcomeShowsShortcutList() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US"

        let result = CLIHookProcessRunner.run(
            executablePath: cliPath,
            arguments: ["welcome"],
            environment: environment,
            timeout: 10
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))

        let output = stripANSI(from: result.stdout)
        let expectedShortcuts = """
          Shortcuts
          ⌘N                  New workspace
          ⌘T                  New tab
          ⌘P                  Go to Workspace…
          ⌘B                  Toggle Left Sidebar
          ⌘⌥B                 Toggle Right Sidebar
          ⌘D                  Split Right
          ⌘⇧D                 Split Down
          ⌘⇧P                 Command Palette…
          ⌘⇧R                 Rename Workspace
          ⌘⇧L                 New browser
          ⌘⇧U                 Jump to Latest Unread
          ⌥⌘U                 Toggle Unread
        """
        // The reference block is intentionally exact: these labels describe the
        // factory defaults and should not follow user-customized settings.
        #expect(output.contains(expectedShortcuts), Comment(rawValue: output))
        #expect(output.contains("Run cmux shortcuts to edit shortcuts."), Comment(rawValue: output))
        #expect(output.contains("Run cmux --help for all commands."), Comment(rawValue: output))
        #expect(output.contains("Run cmux feedback to report a bug."), Comment(rawValue: output))
        #expect(!output.contains("Default shortcuts"), Comment(rawValue: output))
        #expect(!output.contains("Rebound something?"), Comment(rawValue: output))
    }

    private func stripANSI(from value: String) -> String {
        value.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }
}
