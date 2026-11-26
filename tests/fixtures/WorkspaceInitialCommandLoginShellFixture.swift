import Foundation

/// Prints the login-shell wrapper for a workspace command: `SHELL COMMAND`.
@main
struct WorkspaceInitialCommandLoginShellFixture {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { exit(2) }
        print(WorkspaceInitialCommandLoginShell.wrap(arguments[2], userShell: arguments[1]))
    }
}
