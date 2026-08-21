import Foundation
import Testing

struct CLICompletionCandidateSafetyTests {
    @Test("completion candidates degrade silently without a socket")
    func completionCandidatesDegradeSilentlyWithoutSocket() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let missingSocket = "/tmp/cmux-completion-absent-\(UUID().uuidString).sock"

        let started = Date()
        let result = try runCLI(
            cliPath,
            arguments: ["__complete-candidates", "workspaces"],
            environment: ["CMUX_SOCKET_PATH": missingSocket]
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(
            result.exitCode == 0,
            "completion must never exit nonzero; a nonzero exit makes the shell beep"
        )
        #expect(
            result.stdout.isEmpty,
            "completion must offer no candidates when cmux is not running"
        )
        #expect(
            result.stderr.isEmpty,
            "completion must never write to stderr; it would corrupt the user's prompt"
        )
        #expect(
            elapsed < 1.0,
            "completion must not hang the shell when the socket is absent"
        )
    }
}
