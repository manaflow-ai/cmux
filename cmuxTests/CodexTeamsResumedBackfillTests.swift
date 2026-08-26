import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CodexTeamsResumedBackfillTests {
    @Test func resumedLoadedChildrenOpenNativeSplitsWithoutReadinessReprobe() throws {
        let appServer = try CodexTeamsAppServerFixture(childCount: 3)
        let cmuxSocket = try CodexTeamsSocketFixture()
        let running = try startWatcher(appServer: appServer, cmuxSocket: cmuxSocket)
        defer {
            stop(running.process)
            appServer.stop()
            cmuxSocket.stop()
        }

        #expect(appServer.waitForAllResumes(timeout: 5))
        #expect(
            cmuxSocket.waitForSurfaceSplits(3, timeout: 5),
            "three successfully resumed idle subagents should open three panes"
        )
        #expect(appServer.resumedThreadIdsSnapshot() == appServer.threadIds)

        let splitRequests = cmuxSocket.requestsSnapshot().filter {
            $0["method"] as? String == "surface.split"
        }
        #expect(splitRequests.count == 3)
        for request in splitRequests {
            let params = try #require(request["params"] as? [String: Any])
            #expect(params["workspace_id"] as? String == "fixture-workspace")
            #expect(params["focus"] as? Bool == false)
            #expect(params["initial_command"] is String)
        }
    }

    @Test func paneCreationFailureIsVisibleAfterValidSubagentResume() throws {
        let appServer = try CodexTeamsAppServerFixture(childCount: 2)
        let cmuxSocket = try CodexTeamsSocketFixture(
            splitFailureMessage: "fixture pane creation denied"
        )
        let running = try startWatcher(appServer: appServer, cmuxSocket: cmuxSocket)
        defer {
            appServer.stop()
            cmuxSocket.stop()
        }

        #expect(appServer.waitForAllResumes(timeout: 5))
        #expect(cmuxSocket.waitForSurfaceSplits(2, timeout: 5))
        stop(running.process)
        let diagnostic = String(
            data: running.stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(diagnostic.contains("cmux codex-teams watcher"))
        #expect(diagnostic.contains("could not create a pane"))
        #expect(diagnostic.contains("fixture_split_failure"))
        #expect(!diagnostic.contains("child-"))
        #expect(!diagnostic.contains("fixture pane creation denied"))
    }

    private func startWatcher(
        appServer: CodexTeamsAppServerFixture,
        cmuxSocket: CodexTeamsSocketFixture
    ) throws -> (process: Process, stderr: Pipe) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(
            fileURLWithPath: try bundledCLIPath()
        )
        process.arguments = [
            "--socket", cmuxSocket.path,
            "__codex-teams-watch",
            "--workspace-id", "fixture-workspace",
            "--surface-id", "fixture-root-surface",
            "--app-server-url", appServer.url,
            "--codex-path", "/usr/bin/true",
            "--max-auto-depth", "2"
        ]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        return (process, stderr)
    }

    private func bundledCLIPath() throws -> String {
        let appBundleURL = Bundle(for: BundleToken.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cliURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw NSError(
                domain: "CodexTeamsResumedBackfillTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled cmux CLI not found at \(cliURL.path)"]
            )
        }
        return cliURL.path
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date.now.addingTimeInterval(2)
        while process.isRunning, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private final class BundleToken {}
}
