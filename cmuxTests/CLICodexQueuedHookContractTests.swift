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

    @Test("Codex generated decision hooks propagate CLI failure while lifecycle hooks fail open")
    func generatedScriptsPreserveFailureSemantics() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-codex-generated-hook-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let injection = runCodexHookProcess(
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
        #expect(!injection.timedOut, Comment(rawValue: injection.stderr))
        #expect(injection.status == 0, Comment(rawValue: injection.stderr))
        let arguments = injection.stdout.split(separator: "\0").map(String.init)
        let environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SURFACE_ID": "surface-codex-hook-failure",
            "CMUX_CODEX_HOOK_CMUX_BIN": "/usr/bin/false",
            "CMUX_BUNDLED_CLI_PATH": "/usr/bin/true",
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let payload = #"{"session_id":"codex-hook-failure","tool_name":"Write"}"#

        for event in ["PreToolUse", "PermissionRequest"] {
            let configuration = try injectedConfiguration(event: event, arguments: arguments)
            let command = try injectedCommand(configuration: configuration)
            #expect(FileManager.default.isExecutableFile(atPath: command))
            let result = runCodexHookProcess(
                executablePath: command,
                arguments: [],
                environment: environment,
                standardInput: payload,
                timeout: 2
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status != 0, "A direct \(event) hook must propagate its CLI failure")
            #expect(result.stdout.isEmpty, "A direct \(event) hook must not synthesize a decision")
        }

        let stopConfiguration = try injectedConfiguration(event: "Stop", arguments: arguments)
        let stopCommand = try injectedCommand(configuration: stopConfiguration)
        #expect(FileManager.default.isExecutableFile(atPath: stopCommand))
        let stop = runCodexHookProcess(
            executablePath: stopCommand,
            arguments: [],
            environment: environment,
            standardInput: payload,
            timeout: 2
        )
        #expect(!stop.timedOut, Comment(rawValue: stop.stderr))
        #expect(stop.status == 0, Comment(rawValue: stop.stderr))
        #expect(stop.stdout == "{}\n")
    }

    private func injectedConfiguration(event: String, arguments: [String]) throws -> String {
        try #require(arguments.first { $0.hasPrefix("hooks.\(event)=") })
    }

    private func injectedCommand(configuration: String) throws -> String {
        let marker = "command='''"
        let start = try #require(configuration.range(of: marker)?.upperBound)
        let end = try #require(configuration.range(of: "'''", range: start..<configuration.endIndex)?.lowerBound)
        return String(configuration[start..<end])
    }

    private func injectedCommandBody(configuration: String) throws -> String {
        let command = try injectedCommand(configuration: configuration)
        if FileManager.default.fileExists(atPath: command) {
            return try String(contentsOfFile: command, encoding: .utf8)
        }
        return command
    }
}
