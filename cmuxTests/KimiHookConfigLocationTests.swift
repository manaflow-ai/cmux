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
        #expect(installed.contains("hooks kimi stop"))
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
        #expect(installed.contains("hooks kimi stop"))
        #expect(migratedLegacy == legacyUserContent)
    }

    @Test("Setup succeeds when the legacy Kimi config cannot be read")
    func setupSucceedsWhenLegacyConfigCannotBeRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentDirectory = fixture.root.appendingPathComponent("current-kimi", isDirectory: true)
        let legacyDirectory = fixture.root.appendingPathComponent("legacy-kimi", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let currentConfig = currentDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let legacyConfig = legacyDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyConfig, withIntermediateDirectories: true)

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
        #expect(try String(contentsOf: currentConfig, encoding: .utf8).contains("hooks kimi stop"))
        #expect(result.output.contains(legacyConfig.path))
    }

    @Test("Setup does not clean the active Kimi config through a legacy symlink")
    func setupDoesNotCleanActiveConfigThroughLegacySymlink() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentDirectory = fixture.root.appendingPathComponent("current-kimi", isDirectory: true)
        let legacyDirectory = fixture.root.appendingPathComponent("legacy-kimi", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: legacyDirectory,
            withDestinationURL: currentDirectory
        )

        let currentConfig = currentDirectory.appendingPathComponent("config.toml", isDirectory: false)
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
        #expect(installed.contains("hooks kimi stop"), Comment(rawValue: result.output))
    }

    @Test("Declining setup previews and preserves both Kimi configs")
    func decliningSetupPreviewsAndPreservesBothConfigs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentDirectory = fixture.root.appendingPathComponent("current-kimi", isDirectory: true)
        let legacyDirectory = fixture.root.appendingPathComponent("legacy-kimi", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let currentContent = Self.userHookContent(command: "vibe-island")
        let legacyContent = Self.installingCmuxBlock(in: Self.userHookContent(command: "orca"))
        let currentConfig = currentDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let legacyConfig = legacyDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try currentContent.write(to: currentConfig, atomically: true, encoding: .utf8)
        try legacyContent.write(to: legacyConfig, atomically: true, encoding: .utf8)

        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi"],
            fixture: fixture,
            environmentOverrides: [
                "KIMI_SHARE_DIR": currentDirectory.path,
                "KIMI_CODE_HOME": legacyDirectory.path,
            ],
            standardInput: "n\n"
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(try String(contentsOf: currentConfig, encoding: .utf8) == currentContent)
        #expect(try String(contentsOf: legacyConfig, encoding: .utf8) == legacyContent)
        #expect(result.output.contains(currentConfig.path))
        #expect(result.output.contains(legacyConfig.path))
    }

    @Test("Declining legacy cleanup preserves an up-to-date active Kimi config")
    func decliningLegacyCleanupPreservesCurrentConfigs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentDirectory = fixture.root.appendingPathComponent("current-kimi", isDirectory: true)
        let legacyDirectory = fixture.root.appendingPathComponent("legacy-kimi", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let currentConfig = currentDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let legacyConfig = legacyDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let environment = [
            "KIMI_SHARE_DIR": currentDirectory.path,
            "KIMI_CODE_HOME": legacyDirectory.path,
        ]
        let seedResult = try runCLI(
            arguments: ["hooks", "setup", "kimi", "--yes"],
            fixture: fixture,
            environmentOverrides: environment
        )
        #expect(seedResult.status == 0, Comment(rawValue: seedResult.output))
        let currentContent = try String(contentsOf: currentConfig, encoding: .utf8)
        let legacyContent = Self.installingCmuxBlock(in: Self.userHookContent(command: "orca"))
        try legacyContent.write(to: legacyConfig, atomically: true, encoding: .utf8)

        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi"],
            fixture: fixture,
            environmentOverrides: environment,
            standardInput: "n\n"
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(try String(contentsOf: currentConfig, encoding: .utf8) == currentContent)
        #expect(try String(contentsOf: legacyConfig, encoding: .utf8) == legacyContent)
        #expect(result.output.contains(legacyConfig.path))
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

    @Test("Uninstall succeeds when the legacy Kimi config cannot be read")
    func uninstallSucceedsWhenLegacyConfigCannotBeRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let currentDirectory = fixture.root.appendingPathComponent("current-kimi", isDirectory: true)
        let legacyDirectory = fixture.root.appendingPathComponent("legacy-kimi", isDirectory: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let currentUserContent = Self.userHookContent(command: "vibe-island")
        let currentConfig = currentDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let legacyConfig = legacyDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try Self.installingCmuxBlock(in: currentUserContent)
            .write(to: currentConfig, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: legacyConfig, withIntermediateDirectories: true)

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
        #expect(FileManager.default.fileExists(atPath: legacyConfig.path))
        #expect(result.output.contains(legacyConfig.path))
        #expect(result.output.contains("cmux hooks uninstall kimi"))
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
        environmentOverrides: [String: String] = [:],
        standardInput: String? = nil
    ) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let input = standardInput == nil ? nil : Pipe()
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
        if let input {
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = output
        process.standardError = output
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSignal.signal() }
        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            try input.fileHandleForWriting.close()
        }
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
        """ + "\n\n"
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
