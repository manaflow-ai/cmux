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

    @Test("Setup targets the Kimi Code config when only it exists")
    func setupTargetsKimiCodeConfigWhenOnlyItExists() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeConfig = try fixture.seedConfig(
            directory: ".kimi-code",
            content: Self.userHookContent(command: "orca")
        )
        let kimiCliConfig = fixture.configURL(directory: ".kimi")

        let result = try runCLI(arguments: ["hooks", "setup", "kimi", "--yes"], fixture: fixture)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(!FileManager.default.fileExists(atPath: kimiCliConfig.path), Comment(rawValue: result.output))
        let installed = try String(contentsOf: kimiCodeConfig, encoding: .utf8)
        #expect(installed.contains("hooks kimi stop"), Comment(rawValue: result.output))
        #expect(installed.contains(#"command = "orca""#), Comment(rawValue: result.output))
        #expect(installed.contains(#"event = "Notification""#))
        #expect(!installed.contains(#"event = "PermissionRequest""#))
        #expect(!installed.contains(#"event = "Interrupt""#))
    }

    @Test("Setup targets the Kimi CLI config when only it exists")
    func setupTargetsKimiCliConfigWhenOnlyItExists() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCliConfig = try fixture.seedConfig(
            directory: ".kimi",
            content: Self.userHookContent(command: "vibe-island")
        )
        let kimiCodeConfig = fixture.configURL(directory: ".kimi-code")

        let result = try runCLI(arguments: ["hooks", "setup", "kimi", "--yes"], fixture: fixture)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(!FileManager.default.fileExists(atPath: kimiCodeConfig.path), Comment(rawValue: result.output))
        let installed = try String(contentsOf: kimiCliConfig, encoding: .utf8)
        #expect(installed.contains("hooks kimi stop"), Comment(rawValue: result.output))
        #expect(installed.contains(#"command = "vibe-island""#), Comment(rawValue: result.output))
    }

    @Test("Setup prefers the Kimi Code config and keeps the Kimi CLI block installed")
    func setupPrefersKimiCodeAndRefreshesKimiCliBlock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeConfig = try fixture.seedConfig(
            directory: ".kimi-code",
            content: Self.userHookContent(command: "orca")
        )
        let kimiCliConfig = try fixture.seedConfig(
            directory: ".kimi",
            content: Self.installingCmuxBlock(in: Self.userHookContent(command: "vibe-island"))
        )

        let result = try runCLI(arguments: ["hooks", "setup", "kimi", "--yes"], fixture: fixture)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let installed = try String(contentsOf: kimiCodeConfig, encoding: .utf8)
        let secondary = try String(contentsOf: kimiCliConfig, encoding: .utf8)
        #expect(installed.contains("hooks kimi stop"), Comment(rawValue: result.output))
        #expect(installed.contains(#"command = "orca""#), Comment(rawValue: result.output))
        #expect(secondary.contains("hooks kimi stop"), Comment(rawValue: result.output))
        #expect(secondary.contains(#"command = "vibe-island""#), Comment(rawValue: result.output))
    }

    @Test("Setup leaves a secondary config without a cmux block untouched")
    func setupLeavesSecondaryConfigWithoutCmuxBlockUntouched() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let secondaryContent = Self.userHookContent(command: "vibe-island")
        let kimiCodeConfig = try fixture.seedConfig(
            directory: ".kimi-code",
            content: Self.userHookContent(command: "orca")
        )
        let kimiCliConfig = try fixture.seedConfig(directory: ".kimi", content: secondaryContent)

        let result = try runCLI(arguments: ["hooks", "setup", "kimi", "--yes"], fixture: fixture)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(
            try String(contentsOf: kimiCodeConfig, encoding: .utf8).contains("hooks kimi stop"),
            Comment(rawValue: result.output)
        )
        #expect(
            try String(contentsOf: kimiCliConfig, encoding: .utf8) == secondaryContent,
            Comment(rawValue: result.output)
        )
    }

    @Test("Setup uses the config path the installed Kimi binary reports")
    func setupUsesConfigPathReportedByKimiBinary() throws {
        let probedDirectory = "probed-kimi"
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let probedConfig = fixture.root
            .appendingPathComponent(probedDirectory, isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        try FileManager.default.createDirectory(
            at: probedConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixture.setDoctorOutput(Self.doctorReport(configPath: probedConfig.path))

        let kimiCodeContent = Self.userHookContent(command: "orca")
        let kimiCodeConfig = try fixture.seedConfig(directory: ".kimi-code", content: kimiCodeContent)

        let result = try runCLI(arguments: ["hooks", "setup", "kimi", "--yes"], fixture: fixture)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(
            try String(contentsOf: probedConfig, encoding: .utf8).contains("hooks kimi stop"),
            Comment(rawValue: result.output)
        )
        #expect(
            try String(contentsOf: kimiCodeConfig, encoding: .utf8) == kimiCodeContent,
            Comment(rawValue: result.output)
        )
    }

    @Test("Setup falls back to a well-known config when the reported path is unusable")
    func setupFallsBackWhenReportedPathIsUnusable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let missingConfig = fixture.root
            .appendingPathComponent("never-created", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        try fixture.setDoctorOutput(Self.doctorReport(configPath: missingConfig.path))
        let kimiCodeConfig = try fixture.seedConfig(
            directory: ".kimi-code",
            content: Self.userHookContent(command: "orca")
        )

        let result = try runCLI(arguments: ["hooks", "setup", "kimi", "--yes"], fixture: fixture)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(!FileManager.default.fileExists(atPath: missingConfig.path), Comment(rawValue: result.output))
        #expect(
            try String(contentsOf: kimiCodeConfig, encoding: .utf8).contains("hooks kimi stop"),
            Comment(rawValue: result.output)
        )
    }

    @Test("Setup honors KIMI_CODE_HOME and keeps the Kimi CLI block installed")
    func setupHonorsKimiCodeHomeAndKeepsKimiCliBlock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeDirectory = try fixture.makeDirectory(named: "kimi-code-home")
        let kimiCliDirectory = try fixture.makeDirectory(named: "kimi-share-dir")
        let kimiCodeConfig = kimiCodeDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let kimiCliConfig = kimiCliDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try Self.userHookContent(command: "orca")
            .write(to: kimiCodeConfig, atomically: true, encoding: .utf8)
        try Self.installingCmuxBlock(in: Self.userHookContent(command: "vibe-island"))
            .write(to: kimiCliConfig, atomically: true, encoding: .utf8)

        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi", "--yes"],
            fixture: fixture,
            environmentOverrides: [
                "KIMI_CODE_HOME": kimiCodeDirectory.path,
                "KIMI_SHARE_DIR": kimiCliDirectory.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let installed = try String(contentsOf: kimiCodeConfig, encoding: .utf8)
        let secondary = try String(contentsOf: kimiCliConfig, encoding: .utf8)
        #expect(installed.contains("hooks kimi stop"), Comment(rawValue: result.output))
        #expect(installed.contains(#"command = "orca""#), Comment(rawValue: result.output))
        #expect(secondary.contains("hooks kimi stop"), Comment(rawValue: result.output))
        #expect(secondary.contains(#"command = "vibe-island""#), Comment(rawValue: result.output))
    }

    @Test("Setup succeeds when a secondary Kimi config cannot be read")
    func setupSucceedsWhenSecondaryConfigCannotBeRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeDirectory = try fixture.makeDirectory(named: "kimi-code-home")
        let kimiCliDirectory = try fixture.makeDirectory(named: "kimi-share-dir")
        let kimiCodeConfig = kimiCodeDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let kimiCliConfig = kimiCliDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try FileManager.default.createDirectory(at: kimiCliConfig, withIntermediateDirectories: true)

        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi", "--yes"],
            fixture: fixture,
            environmentOverrides: [
                "KIMI_CODE_HOME": kimiCodeDirectory.path,
                "KIMI_SHARE_DIR": kimiCliDirectory.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(
            try String(contentsOf: kimiCodeConfig, encoding: .utf8).contains("hooks kimi stop"),
            Comment(rawValue: result.output)
        )
        #expect(result.output.contains(kimiCliConfig.path), Comment(rawValue: result.output))
    }

    @Test("Setup writes one block when both Kimi paths resolve to the same directory")
    func setupWritesOneBlockThroughSymlinkedConfigDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeDirectory = try fixture.makeDirectory(named: "kimi-code-home")
        let kimiCliDirectory = fixture.root.appendingPathComponent("kimi-share-dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: kimiCliDirectory, withDestinationURL: kimiCodeDirectory)
        let kimiCodeConfig = kimiCodeDirectory.appendingPathComponent("config.toml", isDirectory: false)

        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi", "--yes"],
            fixture: fixture,
            environmentOverrides: [
                "KIMI_CODE_HOME": kimiCodeDirectory.path,
                "KIMI_SHARE_DIR": kimiCliDirectory.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let installed = try String(contentsOf: kimiCodeConfig, encoding: .utf8)
        #expect(installed.contains("hooks kimi stop"), Comment(rawValue: result.output))
        #expect(
            installed.components(separatedBy: #"event = "Stop""#).count == 2,
            Comment(rawValue: installed)
        )
    }

    @Test("Declining setup previews and preserves both Kimi configs")
    func decliningSetupPreviewsAndPreservesBothConfigs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeContent = Self.userHookContent(command: "orca")
        let kimiCliContent = Self.installingCmuxBlock(in: Self.userHookContent(command: "vibe-island"))
        let kimiCodeConfig = try fixture.seedConfig(directory: ".kimi-code", content: kimiCodeContent)
        let kimiCliConfig = try fixture.seedConfig(directory: ".kimi", content: kimiCliContent)

        let result = try runCLI(
            arguments: ["hooks", "setup", "kimi"],
            fixture: fixture,
            standardInput: "n\n"
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(try String(contentsOf: kimiCodeConfig, encoding: .utf8) == kimiCodeContent)
        #expect(try String(contentsOf: kimiCliConfig, encoding: .utf8) == kimiCliContent)
        #expect(result.output.contains(kimiCodeConfig.path), Comment(rawValue: result.output))
    }

    @Test("Uninstall removes cmux blocks from both Kimi configs")
    func uninstallRemovesBlocksFromBothConfigs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeContent = Self.userHookContent(command: "orca")
        let kimiCliContent = Self.userHookContent(command: "vibe-island")
        let kimiCodeConfig = try fixture.seedConfig(
            directory: ".kimi-code",
            content: Self.installingCmuxBlock(in: kimiCodeContent)
        )
        let kimiCliConfig = try fixture.seedConfig(
            directory: ".kimi",
            content: Self.installingCmuxBlock(in: kimiCliContent)
        )

        let result = try runCLI(arguments: ["hooks", "uninstall", "kimi", "--yes"], fixture: fixture)

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(try String(contentsOf: kimiCodeConfig, encoding: .utf8) == kimiCodeContent)
        #expect(try String(contentsOf: kimiCliConfig, encoding: .utf8) == kimiCliContent)
    }

    @Test("Uninstall succeeds when a secondary Kimi config cannot be read")
    func uninstallSucceedsWhenSecondaryConfigCannotBeRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let kimiCodeDirectory = try fixture.makeDirectory(named: "kimi-code-home")
        let kimiCliDirectory = try fixture.makeDirectory(named: "kimi-share-dir")
        let kimiCodeContent = Self.userHookContent(command: "orca")
        let kimiCodeConfig = kimiCodeDirectory.appendingPathComponent("config.toml", isDirectory: false)
        let kimiCliConfig = kimiCliDirectory.appendingPathComponent("config.toml", isDirectory: false)
        try Self.installingCmuxBlock(in: kimiCodeContent)
            .write(to: kimiCodeConfig, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: kimiCliConfig, withIntermediateDirectories: true)

        let result = try runCLI(
            arguments: ["hooks", "uninstall", "kimi", "--yes"],
            fixture: fixture,
            environmentOverrides: [
                "KIMI_CODE_HOME": kimiCodeDirectory.path,
                "KIMI_SHARE_DIR": kimiCliDirectory.path,
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(try String(contentsOf: kimiCodeConfig, encoding: .utf8) == kimiCodeContent)
        #expect(FileManager.default.fileExists(atPath: kimiCliConfig.path))
        #expect(result.output.contains(kimiCliConfig.path), Comment(rawValue: result.output))
        #expect(result.output.contains("cmux hooks uninstall kimi"), Comment(rawValue: result.output))
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let bin: URL

        func configURL(directory: String) -> URL {
            home
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("config.toml", isDirectory: false)
        }

        @discardableResult
        func seedConfig(directory: String, content: String) throws -> URL {
            let url = configURL(directory: directory)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func makeDirectory(named name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func setDoctorOutput(_ output: String) throws {
            try output.write(
                to: bin.appendingPathComponent("doctor-output.txt", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kimi-hooks-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let kimi = bin.appendingPathComponent("kimi", isDirectory: false)
        let stub = """
        #!/bin/sh
        if [ "$1" = "doctor" ]; then
            cat "$(dirname "$0")/doctor-output.txt" 2>/dev/null
        fi
        exit 0
        """
        try (stub + "\n").write(to: kimi, atomically: true, encoding: .utf8)
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

    private static func doctorReport(configPath: String) -> String {
        """
        Checking Kimi Code CLI configuration
        config.toml: \(configPath) ok
        tui.toml: skipped
        """ + "\n"
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
