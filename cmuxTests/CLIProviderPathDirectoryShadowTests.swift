import Foundation
import Testing

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/8743:
// `resolveExecutableInSearchPath` accepted PATH candidates via
// `FileManager.isExecutableFile(atPath:)` alone, which returns true for
// directories on macOS. A directory named like a provider binary earlier on
// PATH could shadow the real executable and break provider launch.
extension CMUXCLIErrorOutputRegressionTests {
    @Test func testProviderPathResolutionSkipsDirectoryNamedLikeProviderBinary() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-path-dir-shadow-\(UUID().uuidString)", isDirectory: true)
        let shadowBin = root.appendingPathComponent("shadow-bin", isDirectory: true)
        let shadowDirectory = shadowBin.appendingPathComponent("codex", isDirectory: true)
        let realBin = root.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: shadowDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shadowDirectory.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let realCodex = realBin.appendingPathComponent("codex", isDirectory: false)
        try "#!/bin/sh\necho fake-codex-resolved\nexit 0\n"
            .write(to: realCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: realCodex.path)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // A throwaway HOME keeps the resolver's implicit home-relative search
        // directories (~/.local/bin, ~/.bun/bin, ...) hermetic. The absolute
        // fallback directories (/opt/homebrew/bin, ...) come after the PATH
        // walk, so the fake codex in real-bin always wins once the shadow
        // directory is rejected.
        environment["HOME"] = root.path
        environment["PATH"] = "\(shadowBin.path):\(realBin.path)"

        // The fake codex exits immediately; the deadline only bounds a hung
        // CLI process and never grades speed.
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["codex-teams", "--version"],
            environment: environment,
            timeout: 10
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("fake-codex-resolved"), Comment(rawValue: result.stdout))
    }
}
