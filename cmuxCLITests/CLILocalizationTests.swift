import Darwin
import Foundation
import Testing

@Suite("CLI localization")
struct CLILocalizationTests {
    @Test("uses the enclosing app catalog")
    func usesEnclosingAppCatalog() throws {
        let cliURL = try BundledCLITestSupport.bundledCLIURL(for: BundleToken.self)
        let fixture = try LocalizationAppFixture(cliURL: cliURL)
        defer { fixture.cleanUp() }

        let result = try runCLI(
            at: fixture.appCLIURL,
            environment: ["AppleLanguages": "(ja)"]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("開始と再開"), Comment(rawValue: result.output))
        #expect(!result.output.contains("Start & Resume"), Comment(rawValue: result.output))
    }

    @Test("keeps default values when no catalog is available")
    func keepsDefaultValuesWithoutCatalog() throws {
        let cliURL = try BundledCLITestSupport.bundledCLIURL(for: BundleToken.self)
        let result = try runCLI(
            at: cliURL,
            environment: ["AppleLanguages": "(ja)"]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("Start & Resume"), Comment(rawValue: result.output))
        #expect(!result.output.contains("開始と再開"), Comment(rawValue: result.output))
    }

    private final class BundleToken {}

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private static func runCLI(at url: URL, environment overrides: [String: String]) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = url
        process.arguments = ["help", "start"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")
        environment.removeValue(forKey: "CMUX_BUNDLE_ID")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        for (key, value) in overrides {
            environment[key] = value
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private final class LocalizationAppFixture {
        let root: URL
        let appCLIURL: URL

        init(cliURL: URL) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cli-localization-\(UUID().uuidString)", isDirectory: true)
            let appURL = root.appendingPathComponent("cmux DEV.app", isDirectory: true)
            let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
            let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
            let binURL = resourcesURL.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: resourcesURL.appendingPathComponent("ja.lproj", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>com.cmuxterm.app.debug.fixture</string>
              <key>CFBundlePackageType</key><string>APPL</string>
              <key>CFBundleExecutable</key><string>cmux</string>
            </dict></plist>
            """.utf8).write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
            try Data("\"cli.help.topic.start\" = \"開始と再開\";\n".utf8)
                .write(to: resourcesURL.appendingPathComponent("ja.lproj/Localizable.strings", isDirectory: false))

            let frameworksURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
            let resourceFrameworksURL = resourcesURL.appendingPathComponent("Frameworks", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: frameworksURL, withDestinationURL: cliURL.deletingLastPathComponent().appendingPathComponent("Frameworks", isDirectory: true))
            try FileManager.default.createSymbolicLink(at: resourceFrameworksURL, withDestinationURL: frameworksURL)

            appCLIURL = binURL.appendingPathComponent("cmux", isDirectory: false)
            try FileManager.default.linkItem(at: cliURL, to: appCLIURL)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
