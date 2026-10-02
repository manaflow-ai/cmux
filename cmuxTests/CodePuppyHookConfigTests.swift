import Foundation
import Testing

/// Installation coverage for the managed callback plugin and native-hook migration.
@Suite(.serialized)
struct CodePuppyHookConfigTests {
    @Test func installPreservesUserHooksAndRegistersOnlyOneManagedPlugin() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-code-puppy-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configDirectory = root.appendingPathComponent(".code_puppy", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let hookURL = configDirectory.appendingPathComponent("hooks.json")
        let userCommand = "echo user-hook"
        let legacyConfig: [String: Any] = ["hooks": ["Stop": [[
            "matcher": "*", "hooks": [
                ["type": "command", "command": userCommand],
                ["type": "command", "command": "cmux hooks code-puppy stop"],
            ],
        ], ["matcher": "user-empty", "hooks": [], "custom": "preserve"]]]]
        try JSONSerialization.data(withJSONObject: legacyConfig).write(to: hookURL)

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "code-puppy", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            "XDG_CONFIG_HOME": "",
            ],
            timeout: 10
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let pluginURL = configDirectory.appendingPathComponent("plugins/cmux-session/register_callbacks.py")
        #expect(FileManager.default.fileExists(atPath: pluginURL.path))
        let registryURL = configDirectory.appendingPathComponent("external_plugins.json")
        let registry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any])
        let plugins = try #require(registry["plugins"] as? [[String: Any]])
        #expect(plugins.filter { $0["name"] as? String == "cmux-session" }.count == 1)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        #expect(commands == [userCommand])
        #expect(stop.contains { $0["matcher"] as? String == "user-empty" && $0["custom"] as? String == "preserve" })

        let repeatInstall = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "pup", "install", "--yes"],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "CMUX_CLI_SENTRY_DISABLED": "1", "XDG_CONFIG_HOME": ""],
            timeout: 10
        )
        #expect(repeatInstall.status == 0, Comment(rawValue: repeatInstall.stderr))
        #expect(try Data(contentsOf: registryURL) == JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted, .sortedKeys]))

        let uninstall = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "code-puppy", "uninstall"],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "CMUX_CLI_SENTRY_DISABLED": "1", "XDG_CONFIG_HOME": ""],
            timeout: 10
        )
        #expect(uninstall.status == 0, Comment(rawValue: uninstall.stderr))
        #expect(!FileManager.default.fileExists(atPath: pluginURL.path))
        #expect(try Data(contentsOf: hookURL) == JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
    }
}
