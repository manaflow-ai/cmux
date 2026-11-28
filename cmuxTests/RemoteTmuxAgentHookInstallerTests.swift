import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The in-band agent hook install names the mirrored tmux session by name
/// until its `$id` is known. tmux reads a bare name that starts with `@` or
/// `%` as a window or pane target (#21595), and the helper runs its own
/// `-t` calls with the same value.
@MainActor
@Suite struct RemoteTmuxAgentHookInstallerTests {
    private let payload = Data("print('cmux')".utf8)

    @Test func namesASessionThatLooksLikeAWindowOrPaneExactly() {
        for name in ["@dev-vm", "%build", "work"] {
            let command = RemoteTmuxAgentHookInstaller.installCommand(sessionTarget: name, payload: payload)
            let installArgument = "'--install' '=\(name)' ".replacingOccurrences(of: "'", with: "'\\''")
            #expect(command?.hasPrefix("run-shell -b -t '=\(name)' ") == true, "\(name): \(command ?? "nil")")
            #expect(command?.contains(installArgument) == true, "\(name): \(command ?? "nil")")
        }
    }

    @Test func keepsASessionIdTarget() {
        let command = RemoteTmuxAgentHookInstaller.installCommand(sessionTarget: "$7", payload: payload)
        let installArgument = "'--install' '$7' ".replacingOccurrences(of: "'", with: "'\\''")
        #expect(command?.hasPrefix("run-shell -b -t '$7' ") == true, Comment(rawValue: command ?? "nil"))
        #expect(command?.contains(installArgument) == true, Comment(rawValue: command ?? "nil"))
    }
}
