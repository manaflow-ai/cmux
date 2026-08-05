import Foundation
import Testing

@Suite("CLI localization resources")
struct CLILocalizationResourceTests {
    @Test("Bundled CLI loads the app string catalog")
    func bundledCLILoadsJapaneseAppLocalization() throws {
        let cliURL = try BundledCLITestSupport.bundledCLIURL(for: BundleProbe.self)
        let result = try runRestoreHelp(cliURL: cliURL)

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(
            result.output.contains("この CLI プロセスを保存されたサーフェスプロセスで置き換えます。"),
            Comment(rawValue: result.output)
        )
        #expect(
            !result.output.contains("Replace this CLI process with the persisted surface process."),
            Comment(rawValue: result.output)
        )
    }

    @Test("CLI keeps default values when app resources are unavailable")
    func standaloneCLIFallsBackToDefaultValue() throws {
        let bundledCLIURL = try BundledCLITestSupport.bundledCLIURL(for: BundleProbe.self)
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-localization-\(UUID().uuidString)", isDirectory: true)
        let standaloneCLIURL = temporaryDirectoryURL.appendingPathComponent("cmux", isDirectory: false)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        try FileManager.default.copyItem(at: bundledCLIURL, to: standaloneCLIURL)

        let result = try runRestoreHelp(cliURL: standaloneCLIURL)

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(
            result.output.contains("Replace this CLI process with the persisted surface process."),
            Comment(rawValue: result.output)
        )
        #expect(
            !result.output.contains("この CLI プロセスを保存されたサーフェスプロセスで置き換えます。"),
            Comment(rawValue: result.output)
        )
    }

    private func runRestoreHelp(cliURL: URL) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["AppleLanguages"] = "(ja)"
        environment["LANG"] = "ja_JP.UTF-8"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        process.executableURL = cliURL
        process.arguments = ["restore", "--help"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            output: String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private final class BundleProbe {}

    private struct ProcessResult {
        let status: Int32
        let output: String
    }
}
