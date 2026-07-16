import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

private final class KimiHookConfigLocationBundleToken {}

@Suite("Kimi hook config location", .serialized)
struct KimiHookConfigLocationTests {
    private struct ProcessResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    @Test("Setup writes the default Kimi config file")
    func setupWritesDefaultKimiConfigFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentConfig = fixture.home
            .appendingPathComponent(".kimi", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        let legacyConfig = fixture.home
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        try FileManager.default.createDirectory(
            at: currentConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi", "--yes"],
            fixture: fixture
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(FileManager.default.fileExists(atPath: currentConfig.path), Comment(rawValue: result.output))
        #expect(!FileManager.default.fileExists(atPath: legacyConfig.path), Comment(rawValue: result.output))
        let installed = try String(contentsOf: currentConfig, encoding: .utf8)
        #expect(installed.contains("cmux hooks kimi stop"))
        #expect(installed.contains(#"event = "Notification""#))
        #expect(!installed.contains(#"event = "PermissionRequest""#))
        #expect(!installed.contains(#"event = "Interrupt""#))
    }

    @Test("Setup honors KIMI_SHARE_DIR and cleans the legacy cmux block")
    func setupHonorsShareDirectoryAndCleansLegacyBlock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentDirectory = fixture.root.appendingPathComponent("current-kimi", isDirectory: true)
        let legacyDirectory = fixture.root.appendingPathComponent("legacy-kimi", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let currentUserContent = Self.userHookContent(command: "vibe-island")
        let legacyUserContent = Self.userHookContent(command: "orca")
        let legacyWithCmuxBlock = Self.installingCmuxBlock(in: legacyUserContent)
        let currentConfig = currentDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let legacyConfig = legacyDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try currentUserContent.write(to: currentConfig, atomically: true, encoding: .utf8)
        try legacyWithCmuxBlock.write(to: legacyConfig, atomically: true, encoding: .utf8)

        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi", "--yes"],
            fixture: fixture,
            environmentOverrides: [
                "KIMI_SHARE_DIR": currentDirectory.path,
                "KIMI_CODE_HOME": legacyDirectory.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let installed = try String(contentsOf: currentConfig, encoding: .utf8)
        let migratedLegacy = try String(contentsOf: legacyConfig, encoding: .utf8)
        #expect(installed.contains(#"command = "vibe-island""#))
        #expect(installed.contains("cmux hooks kimi stop"))
        #expect(migratedLegacy == legacyUserContent)
    }

    @Test("Uninstall removes cmux blocks from current and legacy Kimi configs")
    func uninstallRemovesCurrentAndLegacyBlocks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentDirectory = fixture.root.appendingPathComponent("current-kimi", isDirectory: true)
        let legacyDirectory = fixture.root.appendingPathComponent("legacy-kimi", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let currentUserContent = Self.userHookContent(command: "vibe-island")
        let legacyUserContent = Self.userHookContent(command: "orca")
        let currentConfig = currentDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let legacyConfig = legacyDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try Self.installingCmuxBlock(in: currentUserContent)
            .write(to: currentConfig, atomically: true, encoding: .utf8)
        try Self.installingCmuxBlock(in: legacyUserContent)
            .write(to: legacyConfig, atomically: true, encoding: .utf8)

        let result = try runCLI(
            arguments: ["hooks", "uninstall", "kimi", "--yes"],
            fixture: fixture,
            environmentOverrides: [
                "KIMI_SHARE_DIR": currentDirectory.path,
                "KIMI_CODE_HOME": legacyDirectory.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(try String(contentsOf: currentConfig, encoding: .utf8) == currentUserContent)
        #expect(try String(contentsOf: legacyConfig, encoding: .utf8) == legacyUserContent)
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let bin: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kimi-hooks-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let kimi = bin.appendingPathComponent("kimi", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: kimi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kimi.path)
        return Fixture(root: root, home: home, bin: bin)
    }

    private func runCLI(
        arguments: [String],
        fixture: Fixture,
        environmentOverrides: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(
                for: KimiHookConfigLocationBundleToken.self
            )
        )
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "KIMI_SHARE_DIR")
        environment.removeValue(forKey: "KIMI_CODE_HOME")
        environment["HOME"] = fixture.home.path
        environment["PATH"] = "\(fixture.bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.merge(environmentOverrides) { _, override in override }

        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        try process.run()
        let timedOut = exitSignal.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        return ProcessResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private static func userHookContent(command: String) -> String {
        """
        default_model = "user-model"

        [[hooks]]
        event = "Stop"
        command = "\(command)"

        """
    }

    private static func installingCmuxBlock(in content: String) -> String {
        KimiCodeHookConfig.installing(
            events: [
                KimiCodeHookConfig.Event(
                    name: "Stop",
                    command: "cmux hooks kimi stop",
                    timeout: 10
                ),
            ],
            in: content
        )
    }
}
