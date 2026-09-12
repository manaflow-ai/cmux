import Darwin
import Foundation
import Testing

@Suite("Video background CLI selection", .serialized)
struct CLIVideoBackgroundCommandTests {
    @Test(arguments: ["set", "source", "play", "next"])
    func selectionCommandsExplicitlyRestartThePersistedQueue(action: String) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-cli-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = home.appendingPathComponent(".config/cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = configDirectory.appendingPathComponent("cmux.json")
        try """
        {"terminal":{"videoBackground":{"source":"/tmp/first.mp4","queue":["/tmp/first.mp4","/tmp/second.mp4"]}}}
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let bundleID = "com.cmuxterm.tests.video.\(UUID().uuidString.lowercased())"
        let ghosttyDirectory = home.appendingPathComponent("Library/Application Support/\(bundleID)", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDirectory, withIntermediateDirectories: true)
        try "background-opacity = 0.8\n".write(
            to: ghosttyDirectory.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8
        )
        let socketPath = "/tmp/video-cli-\(UUID().uuidString.prefix(8)).sock"
        let server = try CLIWindowCommandMockServer(
            socketPath: socketPath, targetWindowID: "", targetWindowRef: "",
            responseOverride: { command in command.hasPrefix("reload_config") ? "OK Reloaded config" : nil }
        )
        server.start()
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") || key.hasPrefix("CMUXTERM_") {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = bundleID
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"

        let process = Process()
        let output = Pipe()
        process.executableURL = try BundledCLITestSupport.bundledCLIURL(for: BundleToken.self)
        process.arguments = ["video-background", action, "--json", "--yes"]
            + (action == "next" ? [] : ["/tmp/second.mp4", "/tmp/first.mp4"])
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timedOut = finished.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(!timedOut, Comment(rawValue: text))
        #expect(process.terminationStatus == 0, Comment(rawValue: text))
        #expect(server.receivedLinesSnapshot() == ["reload_config --restart-video-background"])
        let response = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(response["queue"] as? [String] == ["/tmp/second.mp4", "/tmp/first.mp4"])
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        let video = try #require((root["terminal"] as? [String: Any])?["videoBackground"] as? [String: Any])
        #expect(video["queue"] as? [String] == ["/tmp/second.mp4", "/tmp/first.mp4"])
    }

    @Test
    func mutationJSONReportsLegacySourceAsEffectiveQueue() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-cli-legacy-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = home.appendingPathComponent(".config/cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = configDirectory.appendingPathComponent("cmux.json")
        try """
        {"terminal":{"videoBackground":{"source":"/tmp/legacy.mp4"}}}
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let bundleID = "com.cmuxterm.tests.video.\(UUID().uuidString.lowercased())"
        let socketPath = "/tmp/video-cli-\(UUID().uuidString.prefix(8)).sock"

        let result = try runCLI(
            home: home,
            bundleID: bundleID,
            socketPath: socketPath,
            arguments: ["video-background", "on", "--json", "--yes"]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let response = try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        #expect(response["queue"] as? [String] == ["/tmp/legacy.mp4"])
    }

    @Test
    func setNormalizesRelativeLocalPathsBeforePersisting() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-cli-relative-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = home.appendingPathComponent(".config/cmux", isDirectory: true)
        let workingDirectory = home.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try Data().write(to: workingDirectory.appendingPathComponent("loop.mp4"))
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = configDirectory.appendingPathComponent("cmux.json")
        let bundleID = "com.cmuxterm.tests.video.\(UUID().uuidString.lowercased())"
        let socketPath = "/tmp/video-cli-\(UUID().uuidString.prefix(8)).sock"

        let result = try runCLI(
            home: home,
            bundleID: bundleID,
            socketPath: socketPath,
            arguments: ["video-background", "set", "--json", "--yes", "./loop.mp4"],
            currentDirectoryURL: workingDirectory
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        let video = try #require((root["terminal"] as? [String: Any])?["videoBackground"] as? [String: Any])
        let expectedPath = workingDirectory.appendingPathComponent("loop.mp4").standardizedFileURL.path
        #expect(video["queue"] as? [String] == [expectedPath])
    }

    private struct CLIRunResult {
        let status: Int32
        let timedOut: Bool
        let output: String
    }

    private func runCLI(
        home: URL,
        bundleID: String,
        socketPath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws -> CLIRunResult {
        let ghosttyDirectory = home.appendingPathComponent("Library/Application Support/\(bundleID)", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDirectory, withIntermediateDirectories: true)
        try "background-opacity = 0.8\n".write(
            to: ghosttyDirectory.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8
        )
        let server = try CLIWindowCommandMockServer(
            socketPath: socketPath, targetWindowID: "", targetWindowRef: "",
            responseOverride: { command in command.hasPrefix("reload_config") ? "OK Reloaded config" : nil }
        )
        server.start()
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") || key.hasPrefix("CMUXTERM_") {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = bundleID
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "2"

        let process = Process()
        let output = Pipe()
        process.executableURL = try BundledCLITestSupport.bundledCLIURL(for: BundleToken.self)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timedOut = finished.wait(timeout: .now() + 10) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CLIRunResult(status: process.terminationStatus, timedOut: timedOut, output: text)
    }

    private final class BundleToken {}
}
