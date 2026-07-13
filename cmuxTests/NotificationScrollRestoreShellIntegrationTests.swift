import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Notification scroll restore shell integration", .serialized)
struct NotificationScrollRestoreShellIntegrationTests {
    @Test func zshReplayEmitsOrderedCompletionMarker() throws {
        try expectIntegrationReplay(
            shell: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f"],
            integrationFilename: "cmux-zsh-integration.zsh"
        )
    }

    @Test func bashReplayEmitsOrderedCompletionMarker() throws {
        try expectIntegrationReplay(
            shell: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["--noprofile", "--norc"],
            integrationFilename: "cmux-bash-integration.bash"
        )
    }

    @Test func fishReplayEmitsOrderedCompletionMarker() throws {
        guard let shell = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        try expectIntegrationReplay(
            shell: URL(fileURLWithPath: shell),
            arguments: ["--no-config"],
            integrationFilename: "fish/config.fish"
        )
    }

    private func expectIntegrationReplay(
        shell: URL,
        arguments: [String],
        integrationFilename: String
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-replay-marker-\(UUID().uuidString)", isDirectory: true)
        let replayFile = directory.appendingPathComponent("replay-test.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "history\n".write(to: replayFile, atomically: true, encoding: .utf8)

        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let integration = repoRoot
            .appendingPathComponent("Resources/shell-integration")
            .appendingPathComponent(integrationFilename)
        let process = Process()
        let stdout = Pipe()
        process.executableURL = shell
        process.arguments = arguments + ["-c", "source \"\(integration.path)\""]
        process.currentDirectoryURL = repoRoot
        process.standardOutput = stdout
        var environment = ProcessInfo.processInfo.environment
        environment[SessionScrollbackReplayStore.environmentKey] = replayFile.path
        environment["CMUX_FISH_USER_CONFIG_ALREADY_LOADED"] = "1"
        environment["CMUX_SHELL_INTEGRATION"] = "1"
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let marker = SessionScrollbackReplayCompletionMarker(fileURL: replayFile)
        #expect(process.terminationStatus == 0)
        #expect(output == "history\n" + marker.terminalSequence(restoring: repoRoot.path))
        #expect(!FileManager.default.fileExists(atPath: replayFile.path))
    }
}
