import Foundation
import Testing

@Suite("CLI localization")
struct CLILocalizationTests {
    @Test("the built CLI exposes the actual catalog", arguments: ["en", "ja"])
    func builtCatalog(language: String) throws {
        let cliURL = try BundledCLITestSupport.bundledCLIURL(for: BundleToken.self)
        let result = Self.runCLI(at: cliURL, language: language)
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains(language == "ja" ? "開始と再開" : "Start & Resume"))
    }

    @Test("an app-contained CLI and its symlink use the app catalog", arguments: [false, true])
    func appCatalog(throughSymlink: Bool) throws {
        let fixture = try Self.makeFixture(app: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executable: URL
        if throughSymlink {
            executable = fixture.root.appendingPathComponent("linked-cmux")
            try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: fixture.cli)
        } else {
            executable = fixture.cli
        }
        let result = Self.runCLI(at: executable, language: "ja")
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("開始と再開"))
        #expect(!result.stdout.contains("Start & Resume"))
    }

    @Test("a detached executable retains English defaults")
    func missingCatalog() throws {
        let fixture = try Self.makeFixture(app: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = Self.runCLI(at: fixture.cli, language: "ja")
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("Start & Resume"))
    }

    @Test("a missing catalog key retains its default")
    func missingKey() throws {
        let fixture = try Self.makeFixture(app: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = Self.runCLI(at: fixture.cli, language: "ja", arguments: ["help", "--help"])
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("Usage: cmux help [topic]"))
    }

    @Test("localized interpolation substitutes the argument")
    func interpolation() throws {
        let fixture = try Self.makeFixture(app: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = Self.runCLI(
            at: fixture.cli,
            language: "ja",
            arguments: ["--socket", fixture.root.appendingPathComponent("unused.sock").path,
                        "right-sidebar", "--test-flag"]
        )
        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(result.stderr.contains("不明なフラグ '--test-flag'"), Comment(rawValue: result.stderr))
        #expect(!result.stderr.contains("%@"))
    }

    private final class BundleToken {}

    private static func runCLI(
        at url: URL,
        language: String,
        arguments: [String] = ["help", "start"]
    ) -> CLIHookProcessRunner.Result {
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CMUX_") && $0.key != "AppleLanguages"
        }
        environment["AppleLanguages"] = "(\(language))"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return CLIHookProcessRunner.run(
            executablePath: url.path,
            arguments: arguments,
            environment: environment,
            timeout: 10
        )
    }

    private static func makeFixture(app: Bool) throws -> (root: URL, cli: URL) {
        let fileManager = FileManager.default
        let source = try BundledCLITestSupport.bundledCLIURL(for: BundleToken.self).resolvingSymlinksInPath()
        let root = fileManager.temporaryDirectory.appendingPathComponent("cli-localization-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("Fixture.app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        let bin = app ? resources.appendingPathComponent("bin") : root
        do {
            try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
            if app {
                let info: [String: String] = [
                    "CFBundleIdentifier": "com.cmuxterm.cli-localization.fixture",
                    "CFBundlePackageType": "APPL",
                    "CFBundleDevelopmentRegion": "en"
                ]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                let japanese = resources.appendingPathComponent("ja.lproj")
                try fileManager.createDirectory(at: japanese, withIntermediateDirectories: true)
                try Data("""
                "cli.help.topic.start" = "開始と再開";
                "cli.rightSidebar.error.unknownFlag" = "不明なフラグ '%@'";
                """.utf8)
                    .write(to: japanese.appendingPathComponent("Localizable.strings"))
            }
            let cli = bin.appendingPathComponent("cmux")
            try fileManager.copyItem(at: source, to: cli)
            // Preserve the CLI's framework dependencies after moving the executable.
            // These are the three @executable_path locations in the CLI target.
            let sourceDirectory = source.deletingLastPathComponent()
            for relative in [".", "../Frameworks", "../../Frameworks"] {
                let directory = sourceDirectory.appendingPathComponent(relative).standardizedFileURL
                for framework in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                    where framework.pathExtension == "framework" {
                    let destination = bin.appendingPathComponent(framework.lastPathComponent)
                    if !fileManager.fileExists(atPath: destination.path) {
                        try fileManager.createSymbolicLink(at: destination, withDestinationURL: framework)
                    }
                }
            }
            return (root, cli)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }
}
