import Foundation
import XCTest

enum DesktopCmxUITestLaunchSupport {
    static func configure(app: XCUIApplication, tagPrefix: String) {
        let tag = "\(tagPrefix)-\(UUID().uuidString.prefix(8).lowercased())"
        let socketPath = "/tmp/cmux-debug-\(tag).sock"
        let debugLogPath = "/tmp/cmux-debug-\(tag).log"
        let cmuxdSocketPath = "\(NSHomeDirectory())/Library/Application Support/cmux/cmuxd-dev-\(tag).sock"

        app.launchEnvironment["CMUX_TAG"] = tag
        app.launchEnvironment["CMUX_DESKTOP_CMX_BACKEND"] = "1"
        app.launchEnvironment["CMUX_REMOTE_SSH_STACK_IN_RUST"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUXD_UNIX_PATH"] = cmuxdSocketPath
        app.launchEnvironment["CMUX_DEBUG_LOG"] = debugLogPath
        app.launchEnvironment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] = "1"

        let repoRoot = resolvedRepoRoot()
        if let repoRoot {
            app.launchEnvironment["CMUXTERM_REPO_ROOT"] = repoRoot
        }
        if let cmxExecutable = resolvedCmxExecutable(repoRoot: repoRoot) {
            app.launchEnvironment["CMUX_DESKTOP_CMX_EXECUTABLE"] = cmxExecutable
        }

        try? FileManager.default.removeItem(atPath: "/tmp/cmux-cmx-\(tag)")
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: debugLogPath)
        try? FileManager.default.removeItem(atPath: cmuxdSocketPath)
    }

    private static func resolvedRepoRoot() -> String? {
        if let value = trimmedEnvironmentValue("CMUX_UI_TEST_REPO_ROOT") {
            return value
        }

        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
        ]
        for candidate in candidates {
            if let root = firstAncestor(containing: "rust/cmux-cli/Cargo.toml", from: candidate) {
                return root.path
            }
        }
        return nil
    }

    private static func resolvedCmxExecutable(repoRoot: String?) -> String? {
        if let value = trimmedEnvironmentValue("CMUX_UI_TEST_CMX_EXECUTABLE") {
            return value
        }
        if let value = trimmedEnvironmentValue("CMUX_DESKTOP_CMX_EXECUTABLE") {
            return value
        }
        guard let repoRoot else { return nil }
        let candidate = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent("rust/cmux-cli/target/debug/cmx")
            .path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func trimmedEnvironmentValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func firstAncestor(containing relativePath: String, from startURL: URL) -> URL? {
        var candidate = startURL.standardizedFileURL
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(relativePath).path
            ) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
        return nil
    }
}
