import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testSessionsListUsesTrustedOpenCodeLaunchCaptureForForkSupport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-opencode-untrusted-\(UUID().uuidString)", isDirectory: true)
        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try sessionsListDiagnosticSession(
            agent: "opencode",
            launcher: "omo",
            executablePath: "/bin/sh",
            arguments: ["/bin/sh", "-lc", "opencode"],
            workingDirectory: repoDir.path
        )
        #expect(session["fork_command_available"] as? Bool == true)
        #expect(session["fork_supported"] as? Bool == false)
        #expect(session["fork_unavailable_reason"] as? String == "opencode_version_unverified")
    }
}
