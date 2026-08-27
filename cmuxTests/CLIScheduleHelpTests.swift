import Foundation
import Testing

struct CLIScheduleHelpTests {
    @Test func scheduleHelpRunsWithoutACmuxSocket() throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self))
        process.arguments = ["schedule", "--help"]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = "/private/tmp/cmux-schedule-help-\(UUID().uuidString).sock"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: error + output))
        #expect(output.contains("Usage: cmux schedule"), Comment(rawValue: output))
        #expect(output.contains("one-shot only"), Comment(rawValue: output))
    }

    @Test func scheduleListDoesNotRequireACmuxSocket() throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self))
        process.arguments = ["schedule", "list"]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = "/private/tmp/cmux-schedule-list-\(UUID().uuidString).sock"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: error))
    }

    private final class BundleToken {
        deinit {}
    }
}
