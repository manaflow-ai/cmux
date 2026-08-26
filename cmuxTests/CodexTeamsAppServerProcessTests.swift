import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CodexTeamsAppServerProcessTests {
    @Test("closing the launcher lifetime terminates the app-server process tree")
    func closingLauncherLifetimeTerminatesProcessTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-codex-teams-process-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parentMarker = root.appendingPathComponent("parent")
        let childMarker = root.appendingPathComponent("child")
        let childPIDMarker = root.appendingPathComponent("child-pid")
        let script = """
        echo \"$$\" > \"$CMUX_CODEX_PARENT_MARKER\"
        /bin/sh -c 'echo \"$$\" > \"$CMUX_CODEX_CHILD_MARKER\"; while :; do /bin/sleep 1; done' &
        child=$!
        echo \"$child\" > \"$CMUX_CODEX_CHILD_PID_MARKER\"
        wait \"$child\"
        """
        let process = try CodexTeamsAppServerProcess(
            supervisorExecutablePath: try bundledCLIPath(),
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            environment: [
                "CMUX_CODEX_PARENT_MARKER": parentMarker.path,
                "CMUX_CODEX_CHILD_MARKER": childMarker.path,
                "CMUX_CODEX_CHILD_PID_MARKER": childPIDMarker.path,
                "PATH": "/usr/bin:/bin",
            ],
            logURL: nil
        )
        defer {
            process.terminate()
            if !process.waitUntilExit() {
                process.forceTerminate()
            }
        }

        _ = try #require(await Self.waitForPIDMarker(parentMarker))
        let childPID = try #require(await Self.waitForPIDMarker(childPIDMarker))
        _ = try #require(await Self.waitForPIDMarker(childMarker))

        process.closeParentLifetimeForTesting()

        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline,
              process.isRunning || Self.processExists(childPID) {
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }

        #expect(!process.isRunning)
        #expect(!Self.processExists(childPID))
    }

    private static func waitForPIDMarker(_ url: URL) async throws -> Int32? {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline {
            if let pid = readPID(from: url) {
                return pid
            }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        return nil
    }

    private static func readPID(from url: URL) -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else {
            return nil
        }
        return pid
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
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
                domain: "CodexTeamsAppServerProcessTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Bundled cmux CLI not found at \(cliURL.path)"
                ]
            )
        }
        return cliURL.path
    }

    private final class BundleToken {}
}
