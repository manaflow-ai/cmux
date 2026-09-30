import Foundation
import Testing

/// `cmux app new-incognito-window` run from the repo root opened a terminal
/// in `App/` instead of running the command: the `cmux <path>` shorthand
/// took the bare word `app` as a path because the (case-insensitive) file
/// system has `App/`. A command name always wins over the shorthand.
struct CLIPathShorthandTests {
    /// Every top-level command, plus nouns the app's action catalog adds at
    /// run time, from a folder that holds a directory of the same name.
    @Test func everyCommandWinsOverASameNamedDirectory() {
        let catalogNouns = ["app", "tab", "tab-group", "workspace", "room", "screen", "extension", "window"]
        for name in CLITopLevelCommands.names.sorted() + catalogNouns {
            #expect(!CLIPathShorthand.opensAsPath(name, exists: { _ in true }), "\(name) opened as a path")
        }
    }

    @Test func explicitPathsStillOpen() {
        for path in [".", "..", "./App", "App/", "/tmp", "~/src", "docs/guide"] {
            #expect(CLIPathShorthand.opensAsPath(path, exists: { _ in false }), "\(path)")
        }
        #expect(CLIPathShorthand.opensAsPath("README.md", exists: { _ in true }))
        #expect(!CLIPathShorthand.opensAsPath("README.md", exists: { _ in false }))
        #expect(!CLIPathShorthand.opensAsPath("--help", exists: { _ in true }))
    }
}
