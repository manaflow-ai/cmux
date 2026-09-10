import Foundation
import Testing

private let cmuxBundledBinFishExecutablePath = [
    "/opt/homebrew/bin/fish",
    "/usr/local/bin/fish",
    "/usr/bin/fish",
    "/bin/fish",
].first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.serialized)
struct CmuxBundledBinPathIntegrationTests {
    enum Shell: String, CustomTestStringConvertible, Sendable {
        case bash
        case fish
        case zsh

        var testDescription: String { rawValue }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct ResolutionError: Error, CustomStringConvertible {
        let description: String
    }

    /// Regression for #9471: cmux's bundled commands must not depend on
    /// Ghostty's optional helper environment to remain first on `PATH`.
    @Test(arguments: [Shell.bash, .zsh])
    func bundledOpenWinsWithoutGhosttyBinEnvironment(shell: Shell) throws {
        try assertBundledOpenWinsWithoutGhosttyBinEnvironment(shell: shell)
    }

    @Test(.enabled(if: cmuxBundledBinFishExecutablePath != nil))
    func bundledOpenWinsWithoutGhosttyBinEnvironmentInFish() throws {
        try assertBundledOpenWinsWithoutGhosttyBinEnvironment(shell: .fish)
    }

    private func assertBundledOpenWinsWithoutGhosttyBinEnvironment(shell: Shell) throws {
        guard let executable = Self.executable(for: shell) else {
            throw ResolutionError(description: "\(shell.rawValue) is not installed")
        }

        let fixture = try makeAppBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = run(
            shell: shell,
            executable: executable,
            integrationDirectory: fixture.integrationDirectory,
            home: fixture.root
        )

        guard result.status == 0 else {
            throw ResolutionError(description: "\(shell.rawValue) stderr: \(result.stderr)")
        }
        let resolvedOpen = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedOpen == fixture.openShim.path else {
            throw ResolutionError(
                description: "\(shell.rawValue) resolved \(resolvedOpen) instead of \(fixture.openShim.path); "
                    + "stderr: \(result.stderr)"
            )
        }
    }

    private func makeAppBundleFixture() throws -> (
        root: URL,
        integrationDirectory: URL,
        openShim: URL
    ) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "cmux issue 9471 \(UUID().uuidString)", directoryHint: .isDirectory)
        let resources = root
            .appending(path: "cmux.app/Contents/Resources", directoryHint: .isDirectory)
        let integrationDirectory = resources
            .appending(path: "shell-integration", directoryHint: .isDirectory)
        let binDirectory = resources.appending(path: "bin", directoryHint: .isDirectory)
        let openShim = binDirectory.appending(path: "open", directoryHint: .notDirectory)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shippedIntegration = repositoryRoot
            .appending(path: "Resources/shell-integration", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: shippedIntegration, to: integrationDirectory)
        try fileManager.createSymbolicLink(at: openShim, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        return (root, integrationDirectory, openShim)
    }

    private func run(
        shell: Shell,
        executable: String,
        integrationDirectory: URL,
        home: URL
    ) -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.arguments(for: shell, integrationDirectory: integrationDirectory)
        process.environment = [
            "CMUX_FISH_USER_CONFIG_ALREADY_LOADED": "1",
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR": integrationDirectory.path,
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": executable,
            "TERM": "xterm-256color",
            "USER": NSUserName(),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private static func executable(for shell: Shell) -> String? {
        let candidates: [String]
        switch shell {
        case .bash:
            candidates = ["/bin/bash", "/usr/bin/bash"]
        case .fish:
            return cmuxBundledBinFishExecutablePath
        case .zsh:
            candidates = ["/bin/zsh", "/usr/bin/zsh"]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func arguments(for shell: Shell, integrationDirectory: URL) -> [String] {
        switch shell {
        case .bash:
            return [
                "--noprofile",
                "--norc",
                "-c",
                // The file path is positional so spaces stay literal.
                "source \"$1\"; command -v open",
                "bash",
                integrationDirectory.appending(path: "cmux-bash-integration.bash").path,
            ]
        case .fish:
            return [
                "--no-config",
                "--command",
                // Sourcing the integration exercises the same PATH repair without
                // keeping Fish's interactive event loop alive after the command.
                "source \"$argv[1]\"; command -s open; exit",
                integrationDirectory.appending(path: "fish/config.fish").path,
            ]
        case .zsh:
            return [
                "-dfc",
                "source \"$1\"; _cmux_fix_path; whence -p open",
                "zsh",
                integrationDirectory.appending(path: "cmux-zsh-integration.zsh").path,
            ]
        }
    }
}
