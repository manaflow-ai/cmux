import Foundation
import Testing

@Suite(.serialized)
struct CLICodexQueuedHookContractTests {
    @Test("Codex queues non-decision hooks but keeps decision hooks direct")
    func wrapperInjectionPreservesDecisionSemantics() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-codex-queued-contract-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: [
                "HOME": root.path,
                "CODEX_HOME": root.appendingPathComponent(".codex").path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 3
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let arguments = result.stdout.split(separator: "\0").map(String.init)

        for (event, subcommand) in [
            ("SessionStart", "session-start"),
            ("UserPromptSubmit", "prompt-submit"),
            ("Stop", "stop"),
            ("PostToolUse", "post-tool-use"),
        ] {
            let configuration = try injectedConfiguration(event: event, arguments: arguments)
            let body = try injectedCommandBody(configuration: configuration)
            #expect(configuration.contains("timeout=3000"))
            #expect(body.contains("hooks enqueue codex \(subcommand)"))
            #expect(body.contains("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=1"))
            #expect(!body.contains("nohup"))
            #expect(!body.contains("sleep "))
            #expect(!body.contains(">/dev/null 2>&1 &"))
        }

        let preToolConfiguration = try injectedConfiguration(event: "PreToolUse", arguments: arguments)
        let preToolBody = try injectedCommandBody(configuration: preToolConfiguration)
        #expect(preToolConfiguration.contains("timeout=120000"))
        #expect(preToolBody.contains("hooks codex pre-tool-use"))
        #expect(!preToolBody.contains("hooks enqueue"))

        let permissionConfiguration = try injectedConfiguration(event: "PermissionRequest", arguments: arguments)
        let permissionBody = try injectedCommandBody(configuration: permissionConfiguration)
        #expect(permissionConfiguration.contains("timeout=120000"))
        #expect(permissionBody.contains("hooks codex notification"))
        #expect(!permissionBody.contains("hooks enqueue"))
    }

    private func injectedConfiguration(event: String, arguments: [String]) throws -> String {
        try #require(arguments.first { $0.hasPrefix("hooks.\(event)=") })
    }

    private func injectedCommandBody(configuration: String) throws -> String {
        let marker = "command='''"
        let start = try #require(configuration.range(of: marker)?.upperBound)
        let end = try #require(configuration.range(of: "'''", range: start..<configuration.endIndex)?.lowerBound)
        let command = String(configuration[start..<end])
        if FileManager.default.fileExists(atPath: command) {
            return try String(contentsOfFile: command, encoding: .utf8)
        }
        return command
    }
}
