import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct CLICodexHookTimeoutRegressionTests {
    @Test func codexPromptSubmitDelegatesTranscriptMonitoringToTheApp() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-app-monitor-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("custom codex home", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("custom hook state", isDirectory: true)
        let transcript = root.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("appmon")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let sessionID = "33333333-3333-3333-3333-333333333333"
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"turn-1","last_agent_message":"done"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 16
        )
        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "CODEX_HOME": codexHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": stateDirectory.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionID)","turn_id":"turn-1","cwd":"\#(root.path)","transcript_path":"\#(transcript.path)","hook_event_name":"UserPromptSubmit","prompt":"test"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let request = try #require(commands.snapshot().compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "agent.sidecar.start"
        })
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["kind"] as? String == "codex_transcript_monitor")
        #expect(params["session_id"] as? String == sessionID)
        #expect(params["turn_id"] as? String == "turn-1")
        #expect(params["workspace_id"] as? String == workspaceID)
        #expect(params["surface_id"] as? String == surfaceID)
        #expect(params["transcript_path"] as? String == transcript.path)
        let leasePath = try #require(params["lease_path"] as? String)
        #expect(FileManager.default.fileExists(atPath: leasePath))
        let environment = try #require(params["environment"] as? [String: Any])
        #expect(environment["HOME"] as? String == root.path)
        #expect(environment["CODEX_HOME"] as? String == codexHome.path)
        #expect(environment["CMUX_AGENT_HOOK_STATE_DIR"] as? String == stateDirectory.path)
        let methodsAtReturn = commands.snapshot().compactMap(codexHookJSONObject).compactMap {
            $0["method"] as? String
        }
        let startIndex = try #require(methodsAtReturn.firstIndex(of: "agent.sidecar.start"))
        let observedCompatibilityMonitor = waitForCondition(timeout: 0.5) {
            let methods = commands.snapshot().compactMap(codexHookJSONObject).compactMap {
                $0["method"] as? String
            }
            guard startIndex + 1 < methods.count else { return false }
            return methods[(startIndex + 1)...].contains("surface.list")
        }
        #expect(!observedCompatibilityMonitor)
    }

    @Test func unsupportedAppSidecarMethodUsesTheDetachedCompatibilityMonitor() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-compat-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let socketPath = makeCodexHookSocketPath("monold")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"turn-1","last_agent_message":"done"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 16,
            methodErrorCodes: ["agent.sidecar.start": "method_not_found"]
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP": "1",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"session-compat","turn_id":"turn-1","cwd":"\#(root.path)","transcript_path":"\#(transcript.path)","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(waitForCondition(timeout: 2) {
            let methods = commands.snapshot().compactMap(codexHookJSONObject).compactMap { $0["method"] as? String }
            guard let startIndex = methods.firstIndex(of: "agent.sidecar.start") else { return false }
            return methods[methods.index(after: startIndex)...].contains("surface.list")
        })
        let sidecarRequest = try #require(commands.snapshot().compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "agent.sidecar.start"
        })
        let sidecarParams = try #require(sidecarRequest["params"] as? [String: Any])
        let leasePath = try #require(sidecarParams["lease_path"] as? String)
        #expect(waitForCondition(timeout: 2) {
            !FileManager.default.fileExists(atPath: leasePath)
        })
    }

    @Test(arguments: ["access_denied", "auth_required", "sidecar_capacity", "timeout"])
    func sidecarAdmissionFailureDoesNotDetachACompatibilityMonitor(_ errorCode: String) throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-monitor-error-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let socketPath = makeCodexHookSocketPath("monerr")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 16,
            methodErrorCodes: ["agent.sidecar.start": errorCode]
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceID,
                "CMUX_SURFACE_ID": surfaceID,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP": "1",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"session-error","turn_id":"turn-1","cwd":"\#(root.path)","transcript_path":"\#(transcript.path)","hook_event_name":"UserPromptSubmit"}"#,
            timeout: 5
        )
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requestsAtReturn = commands.snapshot().compactMap(codexHookJSONObject)
        let methodsAtReturn = requestsAtReturn.compactMap { $0["method"] as? String }
        let startIndex = try #require(methodsAtReturn.firstIndex(of: "agent.sidecar.start"))
        let sidecarRequest = try #require(requestsAtReturn.first { $0["method"] as? String == "agent.sidecar.start" })
        let sidecarParams = try #require(sidecarRequest["params"] as? [String: Any])
        let leasePath = try #require(sidecarParams["lease_path"] as? String)
        #expect(!FileManager.default.fileExists(atPath: leasePath))
        let observedFallback = waitForCondition(timeout: 0.5) {
            let methods = commands.snapshot().compactMap(codexHookJSONObject).compactMap { $0["method"] as? String }
            guard startIndex + 1 < methods.count else { return false }
            return methods[(startIndex + 1)...].contains("surface.list")
        }
        #expect(!observedFallback)
    }

    @Test func codexWrapperUsesOneNativeClientForAllQueuedEvents() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-client-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("custom codex home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("native")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceID,
            connectionLimit: 7,
            droppedResponseCount: 1
        )
        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!inject.timedOut, Comment(rawValue: inject.stderr))
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))

        let expectedEvents = [
            "session-start", "prompt-submit", "stop",
            "pre-tool-use", "post-tool-use", "notification",
        ]
        let installedPaths = try expectedEvents.map {
            try generatedCodexHookPath(in: hooksDirectory, eventTag: $0, native: true)
        }
        let nativeClientPath = URL(fileURLWithPath: cliPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-codex-hook-client", isDirectory: false)
            .path
        #expect(FileManager.default.isExecutableFile(atPath: nativeClientPath))
        #expect(installedPaths.allSatisfy(codexHookExecutableIsMachO))

        let binaryPayload = Data([0x00, 0xFF, 0x0A, 0x22, 0x5C, 0x7F])
        let expectedEnvironment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": #"/tmp/project \"quoted\"/日本語\\repo"#,
            "TMPDIR": root.path,
            "CODEX_HOME": codexHome.path,
            "CMUX_AGENT_HOOK_STATE_DIR": root.appendingPathComponent("state directory").path,
            "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS": "1",
            "CMUX_AGENT_LAUNCH_ARGV_B64": Data("codex\0resume\0session\0".utf8).base64EncodedString(),
            "CMUX_AGENT_LAUNCH_CWD": #"/tmp/project \"quoted\"/日本語\\repo"#,
            "CMUX_AGENT_LAUNCH_EXECUTABLE": #"/tmp/bin/codex \"custom\"\\版本"#,
            "CMUX_AGENT_LAUNCH_KIND": "codex",
            "CMUX_AGENT_MANAGED_SUBAGENT": "1",
            "CMUX_BUNDLE_ID": "com.cmuxterm.app.debug.native",
            "CMUX_CODEX_PID": "4242",
            "CMUX_CUSTOM_CLAUDE_PATH": #"/tmp/Claude Code/bin/claude"#,
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS": "1",
            "CMUX_SURFACE_ID": surfaceID,
            "CMUX_TAG": "native",
            "CMUX_WORKSPACE_ID": workspaceID,
            "CMUX_SOCKET_PATH": socketPath,
            "ANTHROPIC_API_KEY": "anthropic-test-key",
            "ANTHROPIC_SMALL_FAST_MODEL": "vertex-haiku-id",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude config").path,
            "GROK_HOME": root.appendingPathComponent("grok home").path,
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "OPENAI_API_KEY": "openai-test-key",
            "OPENAI_BASE_URL": "https://openai.example.test/v1",
            "OPENCODE_CONFIG_DIR": root.appendingPathComponent("opencode config").path,
            "PI_CONFIG_DIR": root.appendingPathComponent("pi config").path,
        ]

        for (index, path) in installedPaths.enumerated() {
            var environment = expectedEnvironment
            environment["CMUX_SOCKET_CAPABILITY"] = "test-capability"
            environment["CMUX_AGENT_HOOK_ENQUEUE_V1"] = "1"
            environment["CMUX_BUNDLED_CLI_PATH"] = cliPath
            environment["CMUX_AGENT_HOOK_DELIVERY_ID"] = "native-event-\(index)"
            let payload = index == 0 ? binaryPayload : Data("payload-\(expectedEvents[index])".utf8)
            let result = runCodexHookProcess(
                executablePath: path,
                arguments: [],
                environment: environment,
                standardInputData: payload,
                timeout: 3
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        let rawRequests = commands.snapshot()
        #expect(rawRequests.count == 7)
        #expect(rawRequests.allSatisfy { $0.hasPrefix("_cmux_capability_v1 test-capability ") })
        let requests = try rawRequests.map { try #require(codexHookJSONObject($0)) }
        let parameters = try requests.map { request in
            try #require(request["params"] as? [String: Any])
        }
        #expect(parameters[0]["delivery_id"] as? String == "native-event-0")
        #expect(parameters[1]["delivery_id"] as? String == "native-event-0")
        #expect(Array(parameters.dropFirst().compactMap { $0["subcommand"] as? String }) == expectedEvents)
        let firstPayload = try #require(parameters[0]["payload_b64"] as? String)
        #expect(Data(base64Encoded: firstPayload) == binaryPayload)
        let encodedEnvironment = try #require(parameters[0]["environment_b64"] as? String)
        #expect(decodeNULSeparatedEnvironment(encodedEnvironment) == expectedEnvironment)
    }

    @Test func codexNativeClientReplaysExactInputThroughStableFallback() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-fallback-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-fallback", isDirectory: false)
        let capturedInput = root.appendingPathComponent("fallback-input.bin", isDirectory: false)
        let capturedID = root.appendingPathComponent("fallback-id.txt", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("fallback-args.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = try generatedCodexHookPath(
            in: hooksDirectory,
            eventTag: "prompt-submit",
            native: true
        )
        #expect(codexHookExecutableIsMachO(hookPath))

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$CMUX_AGENT_HOOK_DELIVERY_ID\" > \"$CMUX_TEST_ID\"",
            "printf '%s' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "cat > \"$CMUX_TEST_INPUT\"",
        ])
        let payload = Data([0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF, 0x0A])
        let deliveryID = "native-stable-fallback"
        let result = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-native-missing.sock",
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": deliveryID,
                "CMUX_TEST_ID": capturedID.path,
                "CMUX_TEST_ARGS": capturedArgs.path,
                "CMUX_TEST_INPUT": capturedInput.path,
            ],
            standardInputData: payload,
            timeout: 3
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(waitForCondition(timeout: 1) {
            FileManager.default.fileExists(atPath: capturedInput.path)
                && FileManager.default.fileExists(atPath: capturedID.path)
                && FileManager.default.fileExists(atPath: capturedArgs.path)
        })
        #expect(try Data(contentsOf: capturedInput) == payload)
        #expect(try String(contentsOf: capturedID, encoding: .utf8) == deliveryID)
        #expect(
            try String(contentsOf: capturedArgs, encoding: .utf8)
                == "--socket /tmp/cmux-native-missing.sock hooks codex enqueue prompt-submit"
        )

        let noCLIFallback = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-native-missing.sock",
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                "CMUX_CODEX_PID": "4242",
            ],
            standardInputData: payload,
            timeout: 3
        )
        #expect(!noCLIFallback.timedOut, Comment(rawValue: noCLIFallback.stderr))
        #expect(noCLIFallback.status == 0)
        #expect(noCLIFallback.stdout == "{}\n")
    }

    @Test func codexNativeClientRejectsUnexpectedPeerUID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-peer-uid-\(UUID().uuidString)", isDirectory: true)
        let harness = root.appendingPathComponent("peer-uid-harness.c", isDirectory: false)
        let executable = root.appendingPathComponent("peer-uid-harness", isDirectory: false)
        let clientSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HookClient/CodexHookClient.c", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        #define main cmux_hook_client_main
        #include "\(clientSource.path)"
        #undef main

        int main(void) {
            int sockets[2] = {-1, -1};
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return 10;
            const uid_t current = geteuid();
            if (!cmux_socket_peer_matches_uid(sockets[0], current)) return 11;
            if (cmux_socket_peer_matches_uid(sockets[0], current + 1)) return 12;
            close(sockets[0]);
            close(sockets[1]);
            return 0;
        }
        """
        try Data(source.utf8).write(to: harness, options: .atomic)

        let compile = runCodexHookProcess(
            executablePath: "/usr/bin/clang",
            arguments: ["-std=c11", "-Wall", "-Wextra", "-Werror", harness.path, "-o", executable.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 10
        )
        #expect(compile.status == 0, Comment(rawValue: compile.stderr))
        let run = runCodexHookProcess(
            executablePath: executable.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 2
        )
        #expect(run.status == 0, Comment(rawValue: run.stderr))
    }

    @Test func codexNativeClientClassifiesOnlyExactUnsupportedCodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-response-classifier-\(UUID().uuidString)", isDirectory: true)
        let harness = root.appendingPathComponent("response-classifier-harness.c", isDirectory: false)
        let executable = root.appendingPathComponent("response-classifier-harness", isDirectory: false)
        let clientSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HookClient/CodexHookClient.c", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        #define main cmux_hook_client_main
        #include "\(clientSource.path)"
        #undef main

        int main(void) {
            if (cmux_classify_queued_response("{\\"ok\\" : true, \\"queued\\" : true}")
                != CMUX_SUBMISSION_QUEUED) return 10;
            if (cmux_classify_queued_response(
                    "{\\"ok\\":false,\\"error\\":{\\"code\\" : \\"unrecognized_method\\"}}"
                ) != CMUX_SUBMISSION_UNSUPPORTED) return 11;
            if (cmux_classify_queued_response(
                    "{\\"ok\\":false,\\"error\\":{\\"code\\":\\"method_not_found\\"}}"
                ) != CMUX_SUBMISSION_UNSUPPORTED) return 12;
            if (cmux_classify_queued_response(
                    "{\\"ok\\":false,\\"error\\":{\\"code\\":\\"hook_queue_unavailable\\","
                    "\\"message\\":\\"method_not_found while busy\\"}}"
                ) != CMUX_SUBMISSION_RETRYABLE) return 13;
            if (cmux_classify_queued_response(
                    "{\\"ok\\":false,\\"error\\":{\\"code\\":\\"invalid_params\\","
                    "\\"message\\":\\"unrecognized_method is only prose\\"}}"
                ) != CMUX_SUBMISSION_REJECTED) return 14;
            return 0;
        }
        """
        try Data(source.utf8).write(to: harness, options: .atomic)

        let compile = runCodexHookProcess(
            executablePath: "/usr/bin/clang",
            arguments: ["-std=c11", "-Wall", "-Wextra", "-Werror", harness.path, "-o", executable.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 10
        )
        #expect(compile.status == 0, Comment(rawValue: compile.stderr))
        let run = runCodexHookProcess(
            executablePath: executable.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 2
        )
        #expect(run.status == 0, Comment(rawValue: run.stderr))
    }

    @Test func codexNativeWorkerClosesArbitraryInheritedDescriptors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-high-fd-\(UUID().uuidString)", isDirectory: true)
        let harness = root.appendingPathComponent("high-fd-harness.c", isDirectory: false)
        let executable = root.appendingPathComponent("high-fd-harness", isDirectory: false)
        let clientSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HookClient/CodexHookClient.c", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        #define main cmux_hook_client_main
        #include "\(clientSource.path)"
        #undef main

        int main(void) {
            const int base = open("/dev/null", O_RDONLY);
            if (base < 0) return 10;
            const int high = fcntl(base, F_DUPFD, 5000);
            close(base);
            if (high < 5000) return 11;
            cmux_close_inherited_worker_descriptors();
            errno = 0;
            if (fcntl(high, F_GETFD) != -1 || errno != EBADF) return 12;
            return 0;
        }
        """
        try Data(source.utf8).write(to: harness, options: .atomic)

        let compile = runCodexHookProcess(
            executablePath: "/usr/bin/clang",
            arguments: ["-std=c11", "-Wall", "-Wextra", "-Werror", harness.path, "-o", executable.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 10
        )
        #expect(compile.status == 0, Comment(rawValue: compile.stderr))
        let run = runCodexHookProcess(
            executablePath: executable.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 2
        )
        #expect(run.status == 0, Comment(rawValue: run.stderr))
    }

    @Test func codexNativeClientTerminatesHungFallbackWithinDeadline() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-hung-fallback-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-hung-fallback", isDirectory: false)
        let leaderPIDFile = root.appendingPathComponent("hung-leader-pid.txt", isDirectory: false)
        let descendantPIDFile = root.appendingPathComponent("hung-descendant-pid.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            for pidFile in [leaderPIDFile, descendantPIDFile] {
                if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = try generatedCodexHookPath(
            in: hooksDirectory,
            eventTag: "stop",
            native: true
        )
        #expect(codexHookExecutableIsMachO(hookPath))

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$$\" > \"$CMUX_TEST_LEADER_PID\"",
            "/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > \"$CMUX_TEST_DESCENDANT_PID\"; while :; do :; done' &",
            "trap 'exit 143' TERM",
            "while :; do :; done",
        ])
        let started = ContinuousClock().now
        let result = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-hung-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-native-hung-missing.sock",
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": "native-hung-fallback",
                "CMUX_TEST_LEADER_PID": leaderPIDFile.path,
                "CMUX_TEST_DESCENDANT_PID": descendantPIDFile.path,
            ],
            standardInputData: Data(repeating: 0xA5, count: 512 * 1024),
            timeout: 3
        )
        let elapsed = started.duration(to: ContinuousClock().now)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(elapsed < .seconds(0.25))
        #expect(waitForCondition(timeout: 1) {
            FileManager.default.fileExists(atPath: leaderPIDFile.path)
                && FileManager.default.fileExists(atPath: descendantPIDFile.path)
        })
        for pidFile in [leaderPIDFile, descendantPIDFile] {
            let rawPID = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(waitForCondition(timeout: 2) {
                errno = 0
                return Darwin.kill(pid, 0) == -1 && errno == ESRCH
            })
        }
    }

    @Test func everyPersistentCodexHookUsesNativeDurableAdmission() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-persistent-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let hooks = try codexHookEntries(in: codexHome)
        let lifecycle = hooks.filter { ["SessionStart", "UserPromptSubmit", "Stop"].contains($0.eventName) }
        let feedEvents = Set([
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SubagentStart", "SubagentStop",
        ])
        let feed = hooks.filter { feedEvents.contains($0.eventName) }
        #expect(lifecycle.count == 3)
        #expect(lifecycle.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(feed.count == 7)
        #expect(feed.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(hooks.allSatisfy { isContentAddressedCodexHookPath($0.command) })
    }

    @Test func codexHookCommandsRemainExecutableWithSpacesInHome() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-spaced-home-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("user home with spaces", isDirectory: true)
        let codexHome = root.appendingPathComponent("custom CODEX_HOME with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleSharedCommand = "/Users/Shared/.cmux-hooks-\(geteuid())/cmux-codex-native-hook-session-start-deadbeef"
        let userCommand = "printf keep-user-hook"
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["command": staleSharedCommand, "timeout": 10, "type": "command"]]],
                    ["hooks": [["command": userCommand, "timeout": 10, "type": "command"]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json"), options: .atomic)

        let environment = [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: environment,
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let persistentHooks = try codexHookEntries(in: codexHome)
        #expect(persistentHooks.count == 11)
        #expect(persistentHooks.filter { $0.eventName == "SessionStart" }.count == 2)
        #expect(persistentHooks.contains { $0.command == userCommand })
        #expect(!persistentHooks.contains { $0.command == staleSharedCommand })

        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: environment,
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let injectedCommands = codexInjectedHookCommands(inject.stdout)
        #expect(injectedCommands.count == 6)
        let injectedCommandsByEvent = codexInjectedHookCommandsByEvent(inject.stdout)
        let expectedInjectedTags = [
            "SessionStart": "session-start",
            "UserPromptSubmit": "prompt-submit",
            "Stop": "stop",
            "PreToolUse": "pre-tool-use",
            "PostToolUse": "post-tool-use",
            "PermissionRequest": "notification",
        ]
        #expect(Set(injectedCommandsByEvent.keys) == Set(expectedInjectedTags.keys))
        for (event, tag) in expectedInjectedTags {
            let command = try #require(injectedCommandsByEvent[event])
            #expect(
                URL(fileURLWithPath: command).lastPathComponent
                    .hasPrefix("cmux-codex-native-hook-\(tag)-")
            )
        }

        let generatedCommands = persistentHooks
            .filter { $0.command != userCommand }
            .map(\.command) + injectedCommands
        #expect(generatedCommands.count == 16)
        #expect(generatedCommands.allSatisfy { !$0.hasPrefix(home.path) })
        #expect(generatedCommands.allSatisfy { isShellSafeBareHookPath($0) })
        #expect(generatedCommands.allSatisfy { FileManager.default.isExecutableFile(atPath: $0) })
        #expect(generatedCommands.allSatisfy { isContentAddressedCodexHookPath($0) })

        for (index, command) in generatedCommands.enumerated() {
            let input = Data("{\"hook\":\(index)}".utf8)
            let direct = runCodexHookProcess(
                executablePath: command,
                arguments: [],
                environment: environment,
                standardInputData: input,
                timeout: 2
            )
            #expect(!direct.timedOut, Comment(rawValue: direct.stderr))
            #expect(direct.status == 0, Comment(rawValue: direct.stderr))
            #expect(direct.stdout == "{}\n")

            let shell = runCodexHookProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", command],
                environment: environment,
                standardInputData: input,
                timeout: 2
            )
            #expect(!shell.timedOut, Comment(rawValue: shell.stderr))
            #expect(shell.status == 0, Comment(rawValue: shell.stderr))
            #expect(shell.stdout == "{}\n")
        }
    }

    @Test func everyCodexFeedHookPreservesPayloadThroughNativeAdmission() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-feed-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("native-feed")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let events = [
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SubagentStart", "SubagentStop",
        ]
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: "surface-native-feed",
            connectionLimit: events.count
        )
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let hooks = try codexHookEntries(in: codexHome)

        for (index, event) in events.enumerated() {
            let command = try #require(hooks.first { $0.eventName == event }?.command)
            let payload = Data([UInt8(index), 0x00, 0xFF, 0x0A])
            let started = ContinuousClock.now
            let result = runCodexHookProcess(
                executablePath: command,
                arguments: [],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_SURFACE_ID": "surface-native-feed",
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_SOCKET_CAPABILITY": "test-capability",
                    "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                    "CMUX_AGENT_HOOK_DELIVERY_ID": "native-feed-\(index)",
                ],
                standardInputData: payload,
                timeout: 2
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
            #expect(started.duration(to: .now) < .seconds(1))
        }

        let parameters = try commands.snapshot().map { raw -> [String: Any] in
            let request = try #require(codexHookJSONObject(raw))
            return try #require(request["params"] as? [String: Any])
        }
        #expect(parameters.compactMap { $0["subcommand"] as? String } == events.map { "feed:\($0)" })
        for (index, params) in parameters.enumerated() {
            let encoded = try #require(params["payload_b64"] as? String)
            #expect(Data(base64Encoded: encoded) == Data([UInt8(index), 0x00, 0xFF, 0x0A]))
        }
    }

    @Test func codexHookUpgradeReplacesPersistentScriptsWithoutSharedPathCollisions() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-upgrade-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lifecycleEvents = [
            (agentEvent: "SessionStart", subcommand: "session-start"),
            (agentEvent: "UserPromptSubmit", subcommand: "prompt-submit"),
            (agentEvent: "Stop", subcommand: "stop"),
        ]
        var installedHooks: [String: Any] = [:]
        for event in lifecycleEvents {
            let previousPath = hooksDirectory
                .appendingPathComponent("cmux-codex-hook-persistent-\(event.subcommand).sh")
            try makeCodexHookExecutableShellFile(at: previousPath, lines: ["#!/bin/sh", "exit 0"])
            installedHooks[event.agentEvent] = [[
                "hooks": [[
                    "command": previousPath.path,
                    "timeout": 10,
                    "type": "command",
                ]],
            ]]
        }
        let expectedFeedEvents: Set<String> = [
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SubagentStart", "SubagentStop",
        ]
        for agentEvent in expectedFeedEvents {
            let previousPath = hooksDirectory
                .appendingPathComponent("cmux-codex-hook-persistent-feed-\(agentEvent).sh")
            try makeCodexHookExecutableShellFile(at: previousPath, lines: ["#!/bin/sh", "exit 0"])
            installedHooks[agentEvent] = [[
                "hooks": [[
                    "command": previousPath.path,
                    "timeout": 10,
                    "type": "command",
                ]],
            ]]
        }
        let userCommand = "printf 'keep-user-hook'"
        var sessionStart = try #require(installedHooks["SessionStart"] as? [[String: Any]])
        sessionStart.append([
            "hooks": [[
                "command": userCommand,
                "timeout": 10,
                "type": "command",
            ]],
        ])
        installedHooks["SessionStart"] = sessionStart
        let hooksJSON: [String: Any] = ["hooks": installedHooks]
        try JSONSerialization.data(withJSONObject: hooksJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json"), options: .atomic)

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let hooks = try codexHookEntries(in: codexHome)
        #expect(hooks.contains { $0.command == userCommand })
        #expect(!hooks.contains { $0.command.contains("cmux-codex-hook-persistent-") })
        for event in lifecycleEvents {
            let entries = hooks.filter { $0.eventName == event.agentEvent }
            let nativeEntries = entries.filter { codexHookExecutableIsMachO($0.command) }
            let historicalSharedPath = hooksDirectory
                .appendingPathComponent("cmux-codex-hook-\(event.subcommand).sh")
            #expect(nativeEntries.count == 1)
            let nativeEntry = try #require(nativeEntries.first)
            #expect(nativeEntry.command != historicalSharedPath.path)
            #expect(nativeEntry.command.contains("cmux-codex-native-hook-\(event.subcommand)-"))

            // An older concurrently running cmux still rewrites this historical
            // wrapper path. That must not change the installed native helper.
            try makeCodexHookExecutableShellFile(
                at: historicalSharedPath,
                lines: ["#!/bin/sh", "sleep 30"]
            )
            #expect(codexHookExecutableIsMachO(nativeEntry.command))
        }
        let feedHooks = hooks.filter { expectedFeedEvents.contains($0.eventName) }
        let installedFeedEvents = Set(feedHooks.map(\.eventName))
        #expect(feedHooks.count == expectedFeedEvents.count)
        #expect(installedFeedEvents == expectedFeedEvents)
        #expect(feedHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
        for agentEvent in expectedFeedEvents {
            #expect(hooks.filter { $0.eventName == agentEvent }.count == 1)
        }
    }

    @Test func codexHookGenerationFallsBackToPortableShellWithoutNativeClient() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-native-unavailable-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = codexHookTestEnvironment(root: root, codexHome: codexHome)
        environment["CMUX_CODEX_HOOK_CLIENT_PATH"] = root.appendingPathComponent("missing-client").path
        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: environment,
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let shellPath = try generatedCodexHookPath(
            in: root.appendingPathComponent(".cmux/hooks", isDirectory: true),
            eventTag: "session-start",
            native: false
        )
        #expect(!codexHookExecutableIsMachO(shellPath))
        let shell = try String(contentsOfFile: shellPath, encoding: .utf8)
        #expect(shell.hasPrefix("#!/bin/sh\n"))
        #expect(!shell.contains("/usr/bin/base64"))
        #expect(!shell.contains("/usr/bin/nc"))
        #expect(shell.contains("CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP=1"))
        #expect(!shell.contains("watchdog="))
        #expect(!shell.contains("( /bin/sleep 2;"))
        #expect(shell.contains("hooks codex enqueue session-start"))
    }

    @Test func generatedHookPathsAreImmutableAcrossMixedCmuxVersions() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-content-addressed-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        let clientA = root.appendingPathComponent("client-a", isDirectory: false)
        let clientB = root.appendingPathComponent("client-b", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try makeCodexHookExecutableShellFile(at: clientA, lines: ["#!/bin/sh", "printf client-a"])
        try makeCodexHookExecutableShellFile(at: clientB, lines: ["#!/bin/sh", "printf client-b"])
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = codexHookTestEnvironment(root: root, codexHome: codexHome)
        environment["CMUX_CODEX_HOOK_CLIENT_PATH"] = clientA.path
        let first = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: environment,
            timeout: 5
        )
        #expect(first.status == 0, Comment(rawValue: first.stderr))
        let pathA = try generatedCodexHookPath(
            in: hooksDirectory,
            eventTag: "session-start",
            native: true
        )
        let contentsA = try Data(contentsOf: URL(fileURLWithPath: pathA))

        environment["CMUX_CODEX_HOOK_CLIENT_PATH"] = clientB.path
        let second = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: environment,
            timeout: 5
        )
        #expect(second.status == 0, Comment(rawValue: second.stderr))
        let allSessionStartPaths = try FileManager.default.contentsOfDirectory(
            at: hooksDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("cmux-codex-native-hook-session-start-") }
        #expect(allSessionStartPaths.count == 2)
        let pathB = try #require(allSessionStartPaths.map(\.path).first { $0 != pathA })
        #expect(pathA != pathB)
        #expect(try Data(contentsOf: URL(fileURLWithPath: pathA)) == contentsA)
        #expect(try String(contentsOfFile: pathB, encoding: .utf8).contains("client-b"))
    }

    @Test func codexPortableHookBoundsSlowCLIFallbackAndPreservesPayload() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-portable-deadline-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let hooksDirectory = root.appendingPathComponent(".cmux/hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux-slow-fallback", isDirectory: false)
        let capturedInput = root.appendingPathComponent("captured-input.bin", isDirectory: false)
        let leaderPIDFile = root.appendingPathComponent("leader.pid", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            if let rawPID = try? String(contentsOf: leaderPIDFile, encoding: .utf8),
               let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }

        var generationEnvironment = codexHookTestEnvironment(root: root, codexHome: codexHome)
        generationEnvironment["CMUX_CODEX_HOOK_CLIENT_PATH"] = root.appendingPathComponent("missing-client").path
        let inject = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "inject-args"],
            environment: generationEnvironment,
            timeout: 5
        )
        #expect(inject.status == 0, Comment(rawValue: inject.stderr))
        let hookPath = try generatedCodexHookPath(
            in: hooksDirectory,
            eventTag: "session-start",
            native: false
        )

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s' \"$$\" > \"$CMUX_TEST_LEADER_PID\"",
            "cat > \"$CMUX_TEST_INPUT\"",
            "trap 'exit 143' TERM",
            "while :; do :; done",
        ])
        let payload = Data([0x00, 0x22, 0x5C, 0x7F, 0x80, 0xFF, 0x0A])
        let started = ContinuousClock.now
        let result = runCodexHookProcess(
            executablePath: hookPath,
            arguments: [],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-portable-fallback",
                "CMUX_SOCKET_PATH": "/tmp/cmux-portable-missing.sock",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_TEST_INPUT": capturedInput.path,
                "CMUX_TEST_LEADER_PID": leaderPIDFile.path,
            ],
            standardInputData: payload,
            timeout: 3
        )
        let elapsed = started.duration(to: .now)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        #expect(elapsed < .seconds(1))
        #expect(waitForCondition(timeout: 1) {
            FileManager.default.fileExists(atPath: capturedInput.path)
        })
        #expect(try Data(contentsOf: capturedInput) == payload)
        let rawPID = try String(contentsOf: leaderPIDFile, encoding: .utf8)
        let leaderPID = try #require(Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)))
        let leaderGone = waitForCondition(timeout: 3) {
            Darwin.kill(leaderPID, 0) == -1
        }
        #expect(leaderGone)
    }

    @Test func codexLifecycleHooksEnqueueWithoutDetachedProcessTrees() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-inbox-hook-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 10
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let lifecycleHooks = try codexHookEntries(in: codexHome).filter {
            ["SessionStart", "UserPromptSubmit", "Stop"].contains($0.eventName)
        }
        #expect(lifecycleHooks.count == 3)
        #expect(lifecycleHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
    }

    @Test func codexHookInstallReplacesSynchronousBundledHook() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-sync-hook-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousCommand = "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$CMUX_CODEX_HOOKS_DISABLED\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then { if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" hooks codex prompt-submit; else \"$cmux_cli\" hooks codex prompt-submit; fi; } || echo '{}'; else echo '{}'; fi"
        let legacyHookJSON: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["command": previousCommand, "timeout": 5, "type": "command"]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyHookJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: codexHome.appendingPathComponent("hooks.json", isDirectory: false), options: .atomic)

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 10
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let hooks = try codexHookEntries(in: codexHome)
        let sessionStartHooks = hooks.filter { $0.eventName == "SessionStart" }
        let promptHooks = hooks.filter { $0.eventName == "UserPromptSubmit" }
        let stopHooks = hooks.filter { $0.eventName == "Stop" }
        let expectedFeedEvents: Set<String> = [
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
        ]
        let feedHooks = hooks.filter { expectedFeedEvents.contains($0.eventName) }
        #expect(!hooks.map(\.body).contains(previousCommand), "Installer should remove stale synchronous hook")
        #expect(sessionStartHooks.count == 1, "Installer should install one session-start hook")
        #expect(sessionStartHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(sessionStartHooks.allSatisfy { $0.command.contains("cmux-codex-native-hook-session-start-") })
        #expect(promptHooks.count == 1, "Installer should collapse duplicate prompt hooks")
        #expect(promptHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(promptHooks.allSatisfy { $0.command.contains("cmux-codex-native-hook-prompt-submit-") })
        #expect(stopHooks.count == 1, "Installer should install one stop hook")
        #expect(stopHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
        #expect(stopHooks.allSatisfy { $0.command.contains("cmux-codex-native-hook-stop-") })
        let installedFeedEvents = Set(feedHooks.map(\.eventName))
        #expect(feedHooks.count == expectedFeedEvents.count, "Installer should install every Codex feed hook")
        #expect(installedFeedEvents == expectedFeedEvents)
        #expect(feedHooks.allSatisfy { codexHookExecutableIsMachO($0.command) })
    }

    @Test func codexInstalledHookHandsPayloadToInboxCommand() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-async-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        let doneFile = root.appendingPathComponent("hook-done.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "printf done > \"$CMUX_TEST_DONE\"",
        ])

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }?.command
        )
        let payload = #"{"session_id":"codex-session","prompt":"rename this workspace"}"#
        let run = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": root.path,
                "CMUX_SURFACE_ID": "surface-123",
                "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_TEST_STDIN": capturedStdin.path,
                "CMUX_TEST_ARGS": capturedArgs.path,
                "CMUX_TEST_PID": capturedPID.path,
                "CMUX_TEST_DONE": doneFile.path,
            ],
            standardInput: payload,
            timeout: 2
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks codex enqueue prompt-submit", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
        #expect(waitForFile(doneFile, containing: "done", timeout: 1))
    }

    @Test func codexGeneratedHookPreservesExactPayloadAndResumeContextOnDirectSocket() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-encoded-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("custom codex home", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("encoded")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let launchCwd = #"/tmp/project \"quoted\"/日本語\\repo"#
        let launchExecutable = #"/tmp/bin/codex \"custom\"\\版本"#
        let payloads = [
            "",
            #"{"session_id":"plain","prompt":"quote: \" and slash: \\"}"#,
            "{\n  \"session_id\": \"unicode-日本語\",\n  \"prompt\": \"line one\\nline two\"\n}\n",
            #"{},"payload_b64":"YXR0YWNr","environment":{"CMUX_SOCKET_PATH":"/tmp/injected"}"#,
            "not-json: \"quoted\" \\ path 日本語\n",
            String(repeating: "x", count: 256 * 1024),
        ]
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: payloads.count
        )
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "UserPromptSubmit" }?.command
        )

        for (index, payload) in payloads.enumerated() {
            let deliveryID = "encoded-payload-\(index)"
            let run = runCodexHookProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", command],
                environment: [
                    "HOME": root.path,
                    "CODEX_HOME": codexHome.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "PWD": launchCwd,
                    "TMPDIR": root.path,
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_SOCKET_CAPABILITY": "test-capability",
                    "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                    "CMUX_WORKSPACE_ID": workspaceId,
                    "CMUX_SURFACE_ID": surfaceId,
                    "CMUX_CODEX_PID": "4242",
                    "CMUX_AGENT_HOOK_DELIVERY_ID": deliveryID,
                    "CMUX_AGENT_LAUNCH_CWD": launchCwd,
                    "CMUX_AGENT_LAUNCH_EXECUTABLE": launchExecutable,
                    "CMUX_AGENT_LAUNCH_KIND": "codex",
                    "CMUX_AGENT_LAUNCH_ARGV_B64": Data("codex\0resume\0session\0".utf8).base64EncodedString(),
                    "CMUX_BUNDLED_CLI_PATH": cliPath,
                ],
                standardInput: payload,
                timeout: 5
            )
            #expect(!run.timedOut, Comment(rawValue: run.stderr))
            #expect(run.status == 0, Comment(rawValue: run.stderr))
            #expect(run.stdout == "{}\n")
            #expect(waitForCondition(timeout: 2) {
                commands.snapshot().compactMap(codexHookJSONObject).filter {
                    $0["method"] as? String == "agent.hook.enqueue"
                }.count == index + 1
            })

            let request = try #require(commands.snapshot().compactMap(codexHookJSONObject).last)
            let params = try #require(request["params"] as? [String: Any])
            #expect(params["delivery_id"] as? String == deliveryID)
            let payloadBase64 = try #require(params["payload_b64"] as? String)
            let deliveredPayload = try #require(Data(base64Encoded: payloadBase64))
            #expect(deliveredPayload == Data(payload.utf8))
            let environmentBase64 = try #require(params["environment_b64"] as? String)
            let deliveredEnvironment = try #require(decodeNULSeparatedEnvironment(environmentBase64))
            #expect(deliveredEnvironment["CODEX_HOME"] == codexHome.path)
            #expect(deliveredEnvironment["CMUX_AGENT_LAUNCH_CWD"] == launchCwd)
            #expect(deliveredEnvironment["CMUX_AGENT_LAUNCH_EXECUTABLE"] == launchExecutable)
            #expect(deliveredEnvironment["CMUX_SOCKET_PATH"] == socketPath)
        }
    }

    @Test func codexGeneratedHookUsesProcessLightNativeEncoding() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-fast-lane-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("fast")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 1
        )
        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))
        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "SessionStart" }?.command
        )
        let payload = #"{"session_id":"fast-lane","cwd":"/tmp/project-safe","hook_event_name":"SessionStart"}"#
        let result = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: [
                "HOME": root.path,
                "CODEX_HOME": codexHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": "/tmp/project-safe",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_CAPABILITY": "test-capability",
                "CMUX_AGENT_HOOK_ENQUEUE_V1": "1",
                "CMUX_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_CODEX_PID": "4242",
                "CMUX_AGENT_HOOK_DELIVERY_ID": "fast-lane-event",
                "CMUX_AGENT_LAUNCH_CWD": "/tmp/project-safe",
                "CMUX_AGENT_LAUNCH_EXECUTABLE": "/usr/local/bin/codex",
                "CMUX_AGENT_LAUNCH_KIND": "codex",
                "CMUX_AGENT_LAUNCH_ARGV_B64": Data("codex\0".utf8).base64EncodedString(),
                "CMUX_BUNDLED_CLI_PATH": cliPath,
            ],
            standardInput: payload,
            timeout: 3
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")

        let request = try #require(commands.snapshot().compactMap(codexHookJSONObject).last)
        let params = try #require(request["params"] as? [String: Any])
        let payloadBase64 = try #require(params["payload_b64"] as? String)
        #expect(Data(base64Encoded: payloadBase64) == Data(payload.utf8))
        #expect(params["payload_json"] == nil)
        let environmentBase64 = try #require(params["environment_b64"] as? String)
        let environment = try #require(decodeNULSeparatedEnvironment(environmentBase64))
        #expect(environment["CMUX_AGENT_LAUNCH_CWD"] == "/tmp/project-safe")
        #expect(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"] == "/usr/local/bin/codex")
        #expect(params["environment"] == nil)
    }

    @Test func codexQueueFallbackAcceptsEveryWrapperEvent() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-hook-fallback-events-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("fallback")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 6
        )

        let subcommands = [
            "session-start", "prompt-submit", "stop",
            "pre-tool-use", "post-tool-use", "notification",
        ]
        let payloads = [Data([0x00, 0xFF, 0x0A, 0x22, 0x5C, 0x7F])]
            + subcommands.dropFirst().map { Data("payload-\($0)".utf8) }
        for (index, subcommand) in subcommands.enumerated() {
            let result = runCodexHookProcess(
                executablePath: cliPath,
                arguments: ["--socket", socketPath, "hooks", "codex", "enqueue", subcommand],
                environment: [
                    "HOME": root.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "CMUX_SOCKET_PATH": socketPath,
                    "CMUX_SURFACE_ID": surfaceId,
                    "CMUX_AGENT_HOOK_DELIVERY_ID": "fallback-event-\(index)",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ],
                standardInputData: payloads[index],
                timeout: 3
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(result.stdout == "{}\n")
        }

        let queuedParams = commands.snapshot().compactMap(codexHookJSONObject).compactMap { request -> [String: Any]? in
            guard request["method"] as? String == "agent.hook.enqueue" else { return nil }
            return request["params"] as? [String: Any]
        }
        #expect(queuedParams.compactMap { $0["subcommand"] as? String } == subcommands)
        for (index, params) in queuedParams.enumerated() {
            let payloadBase64 = try #require(params["payload_b64"] as? String)
            #expect(Data(base64Encoded: payloadBase64) == payloads[index])
            #expect(params["payload"] == nil)
        }
    }

    @Test func codexResumeUsesGeneratedQueuedSessionStartBeforeExec() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-wrapper-resume-\(UUID().uuidString)", isDirectory: true)
        let hooksDirectory = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let resumeHook = hooksDirectory.appendingPathComponent(
            "cmux-codex-portable-hook-session-start-deadbeefcafebabe.sh",
            isDirectory: false
        )
        let capturedPayload = root.appendingPathComponent("resume-payload.json", isDirectory: false)
        let capturedDeliveryID = root.appendingPathComponent("resume-delivery-id.txt", isDirectory: false)
        let capturedCodexArgs = root.appendingPathComponent("codex-args.txt", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("wrapper")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let sessionID = "12345678-1234-1234-1234-123456789abc"
        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \"$*\" in",
            "  *ping*) exit 0 ;;",
            "  *\"hooks codex inject-args\"*) printf '%s\\0' --enable hooks -c \"hooks.SessionStart=[{hooks=[{type=\\\"command\\\",command='''$CMUX_TEST_RESUME_HOOK''',timeout=10000}]}]\"; exit 0 ;;",
            "esac",
            "exit 1",
        ])
        try makeCodexHookExecutableShellFile(at: resumeHook, lines: [
            "#!/bin/sh",
            "cat > \"$CMUX_TEST_RESUME_PAYLOAD\"",
            "printf '%s' \"$CMUX_AGENT_HOOK_DELIVERY_ID\" > \"$CMUX_TEST_RESUME_DELIVERY_ID\"",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$@\" > \"$CMUX_TEST_CODEX_ARGS\"",
        ])

        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: ["resume", sessionID],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SURFACE_ID": "surface-wrapper",
                "CMUX_WORKSPACE_ID": "workspace-wrapper",
                "CMUX_TEST_RESUME_PAYLOAD": capturedPayload.path,
                "CMUX_TEST_RESUME_DELIVERY_ID": capturedDeliveryID.path,
                "CMUX_TEST_RESUME_HOOK": resumeHook.path,
                "CMUX_TEST_CODEX_ARGS": capturedCodexArgs.path,
            ],
            timeout: 5
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: capturedPayload, encoding: .utf8) == #"{"session_id":"12345678-1234-1234-1234-123456789abc"}"#)
        let deliveryID = try String(contentsOf: capturedDeliveryID, encoding: .utf8)
        #expect(deliveryID.hasPrefix("codex-resume-"))
        let codexArgs = try String(contentsOf: capturedCodexArgs, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(codexArgs.prefix(2) == ["--enable", "hooks"])
        #expect(codexArgs.suffix(2) == ["resume", sessionID])
    }

    @Test func codexResumeBoundsLegacyCLIFallbackProcessGroup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-wrapper-legacy-resume-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let leaderPIDFile = root.appendingPathComponent("legacy-leader.pid", isDirectory: false)
        let descendantPIDFile = root.appendingPathComponent("legacy-descendant.pid", isDirectory: false)
        let codexDone = root.appendingPathComponent("codex-done", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("legacy")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let sessionID = "12345678-1234-1234-1234-123456789abc"
        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            for file in [leaderPIDFile, descendantPIDFile] {
                if let raw = try? String(contentsOf: file, encoding: .utf8),
                   let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \"$*\" in",
            "  *ping*) exit 0 ;;",
            "  *\"hooks codex inject-args\"*) printf '%s\\0' --enable hooks; exit 0 ;;",
            "  *\"hooks codex enqueue session-start\"*) exec /usr/bin/python3 -c 'import os, signal; os.setpgid(0, 0); open(os.environ[\"CMUX_TEST_LEGACY_LEADER\"], \"w\").write(str(os.getpid())); child=os.fork(); child == 0 and (signal.signal(signal.SIGTERM, signal.SIG_IGN), open(os.environ[\"CMUX_TEST_LEGACY_DESCENDANT\"], \"w\").write(str(os.getpid()))); signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.pause()' ;;",
            "esac",
            "exit 1",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf done > \"$CMUX_TEST_CODEX_DONE\"",
        ])

        let started = ContinuousClock.now
        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: ["resume", sessionID],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SURFACE_ID": "surface-wrapper-legacy",
                "CMUX_TEST_LEGACY_LEADER": leaderPIDFile.path,
                "CMUX_TEST_LEGACY_DESCENDANT": descendantPIDFile.path,
                "CMUX_TEST_CODEX_DONE": codexDone.path,
            ],
            timeout: 3
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(waitForCondition(timeout: 1) {
            FileManager.default.fileExists(atPath: leaderPIDFile.path)
                && FileManager.default.fileExists(atPath: descendantPIDFile.path)
                && FileManager.default.fileExists(atPath: codexDone.path)
        })
        for file in [leaderPIDFile, descendantPIDFile] {
            let raw = try String(contentsOf: file, encoding: .utf8)
            let pid = try #require(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(waitForCondition(timeout: 3) { Darwin.kill(pid, 0) == -1 })
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func codexInstalledStopHookHandsPayloadToInboxCommand() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stop-hook-async-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let capturedStdin = root.appendingPathComponent("hook-stdin.json", isDirectory: false)
        let capturedArgs = root.appendingPathComponent("hook-args.txt", isDirectory: false)
        let capturedPID = root.appendingPathComponent("hook-pid.txt", isDirectory: false)
        let doneFile = root.appendingPathComponent("hook-done.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$CMUX_TEST_ARGS\"",
            "printf '%s\\n' \"$CMUX_CODEX_PID\" > \"$CMUX_TEST_PID\"",
            "cat > \"$CMUX_TEST_STDIN\"",
            "printf done > \"$CMUX_TEST_DONE\"",
        ])

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let command = try #require(
            codexHookEntries(in: codexHome).first { $0.eventName == "Stop" }?.command
        )
        let payload = #"{"session_id":"codex-session","stop_hook_active":false}"#
        let run = runCodexHookProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": root.path,
                "CMUX_SURFACE_ID": "surface-123",
                "CMUX_SOCKET_PATH": "/tmp/cmux-test.sock",
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CODEX_PID": "4242",
                "CMUX_TEST_STDIN": capturedStdin.path,
                "CMUX_TEST_ARGS": capturedArgs.path,
                "CMUX_TEST_PID": capturedPID.path,
                "CMUX_TEST_DONE": doneFile.path,
            ],
            standardInput: payload,
            timeout: 1
        )

        #expect(!run.timedOut, Comment(rawValue: run.stderr))
        #expect(run.status == 0, Comment(rawValue: run.stderr))
        #expect(run.stdout == "{}\n")
        #expect(waitForFile(capturedStdin, containing: payload, timeout: 1))
        #expect(waitForFile(capturedArgs, containing: "--socket /tmp/cmux-test.sock hooks codex enqueue stop", timeout: 1))
        #expect(waitForFile(capturedPID, containing: "4242", timeout: 1))
        #expect(waitForFile(doneFile, containing: "done", timeout: 3))
    }

    @Test func codexInstalledAsyncStopDoesNotMarkNewerTurnIdle() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-installed-stale-stop-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-inst")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-installed-stale-stop-session"
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 24
        )

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "install", "--yes"],
            environment: codexHookTestEnvironment(root: root, codexHome: codexHome),
            timeout: 5
        )
        #expect(!install.timedOut, Comment(rawValue: install.stderr))
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let environment = [
            "HOME": root.path,
            "CODEX_HOME": codexHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "TMPDIR": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_BUNDLED_CLI_PATH": cliPath,
            "CMUX_CODEX_PID": "4242",
        ]

        let oldPrompt = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"old"}"#,
            timeout: 3
        )
        #expect(oldPrompt.status == 0, Comment(rawValue: oldPrompt.stderr))
        #expect(oldPrompt.stdout == "{}\n")
        #expect(waitForCondition(timeout: 2) {
            commands.snapshot().contains { $0.hasPrefix("set_status codex Running ") }
        })

        let currentPrompt = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "codex", "prompt-submit"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"current-turn","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"current"}"#,
            timeout: 3
        )
        #expect(currentPrompt.status == 0, Comment(rawValue: currentPrompt.stderr))
        #expect(currentPrompt.stdout == "{}\n")
        #expect(waitForCondition(timeout: 2) {
            let snapshot = commands.snapshot()
            return snapshot.contains { $0.hasPrefix("clear_notifications ") }
                && snapshot.contains { $0.hasPrefix("set_status codex Running ") }
        })

        let staleStopStart = commands.snapshot().count
        let staleStop = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "hooks", "codex", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"old-turn","cwd":"\#(root.path)","hook_event_name":"Stop","last_assistant_message":"old done"}"#,
            timeout: 3
        )
        #expect(staleStop.status == 0, Comment(rawValue: staleStop.stderr))
        #expect(staleStop.stdout == "{}\n")
        #expect(waitForCondition(timeout: 2) {
            commands.snapshot().count > staleStopStart
        })

        let staleStopCommands = Array(commands.snapshot().dropFirst(staleStopStart))
        #expect(
            !staleStopCommands.contains {
                $0.hasPrefix("notify_target") || ($0.hasPrefix("set_status codex ") && $0.contains(" Idle "))
            },
            "An installed async Stop from an older turn must not notify or mark a newer running turn idle, saw \(staleStopCommands)"
        )
    }

    @Test func codexPromptSubmitDoesNotReviveStoppedTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-prompt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-stale")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-stale-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "terminalPromptTurnIds": ["turn-done"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-done","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"late"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(!sentCommands.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "feed.push" })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
        #expect(session["terminalPromptTurnIds"] as? [String] == ["turn-done"])
    }

    @Test func codexSessionStartDoesNotOverwriteExistingTurnState() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-stale-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-start")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-start-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "agentLifecycle": "running",
                    "runtimeStatus": "running",
                    "activePromptDepth": 1,
                    "activePromptTurnId": "turn-active",
                    "activePromptTurnIds": ["turn-active"],
                    "lastPromptTurnId": "turn-active",
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "2",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "feed.push" })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "running")
        #expect(session["runtimeStatus"] as? String == "running")
        #expect(session["activePromptTurnIds"] as? [String] == ["turn-active"])
    }

    @Test func codexSessionStartRefreshesCompletedPriorTurn() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-fresh-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-fresh")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-fresh-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": 1,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "lastPromptTurnId": "turn-done",
                    "terminalPromptTurnIds": ["turn-done"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_AGENT_HOOK_DELIVERY_ID": "stable-feed-delivery-id",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
        #expect(sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })
        let feedPush = try #require(sentCommands.compactMap(codexHookJSONObject).first {
            $0["method"] as? String == "feed.push"
        })
        let feedParams = try #require(feedPush["params"] as? [String: Any])
        let feedEvent = try #require(feedParams["event"] as? [String: Any])
        #expect(feedEvent["_opencode_request_id"] as? String == "stable-feed-delivery-id")

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "unknown")
        #expect(session["runtimeStatus"] as? String == "running")
        #expect(session["lastPromptTurnId"] == nil)
        #expect(session["terminalPromptTurnIds"] as? [String] == ["turn-done"])

        let commandCountAfterSessionStart = sentCommands.count
        let latePrompt = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "prompt-submit"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "1",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","turn_id":"turn-done","cwd":"\#(root.path)","hook_event_name":"UserPromptSubmit","prompt":"late"}"#,
            timeout: 5
        )

        #expect(!latePrompt.timedOut, Comment(rawValue: latePrompt.stderr))
        #expect(latePrompt.status == 0, Comment(rawValue: latePrompt.stderr))
        #expect(latePrompt.stdout == "{}\n")
        let commandsAfterLatePrompt = Array(commands.snapshot().dropFirst(commandCountAfterSessionStart))
        #expect(!commandsAfterLatePrompt.contains { $0.hasPrefix("set_status codex Running ") })
        #expect(!commandsAfterLatePrompt.contains { $0.hasPrefix("clear_notifications ") })
        #expect(!commandsAfterLatePrompt.contains { codexHookJSONObject($0)?["method"] as? String == "feed.push" })
        #expect(!commandsAfterLatePrompt.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })
    }

    @Test func codexSessionStartDoesNotReviveCompletedTurnFromSamePID() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-same-pid-start-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeCodexHookSocketPath("codex-same")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let commands = CodexHookCapturedSocketCommands()
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "codex-same-pid-session"
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": root.path,
                    "pid": 4242,
                    "agentLifecycle": "idle",
                    "runtimeStatus": "idle",
                    "terminalPromptTurnIds": ["turn-done"],
                    "startedAt": now,
                    "updatedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        startCodexHookMockSocketServerAccepting(
            listenerFD: listenerFD,
            commands: commands,
            surfaceId: surfaceId,
            connectionLimit: 8
        )

        let result = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "codex", "session-start"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CODEX_PID": "4242",
            ],
            standardInput: #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "{}\n")
        let sentCommands = commands.snapshot()
        #expect(!sentCommands.contains { $0.hasPrefix("set_agent_lifecycle codex unknown ") })
        #expect(!sentCommands.contains { codexHookJSONObject($0)?["method"] as? String == "surface.resume.set" })

        let saved = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let session = try #require(sessions[sessionId] as? [String: Any])
        #expect(session["agentLifecycle"] as? String == "idle")
        #expect(session["runtimeStatus"] as? String == "idle")
        #expect(session["terminalPromptTurnIds"] as? [String] == ["turn-done"])
    }

    private func generatedCodexHookPath(
        in directory: URL,
        eventTag: String,
        native: Bool
    ) throws -> String {
        let prefix = native
            ? "cmux-codex-native-hook-\(eventTag)-"
            : "cmux-codex-portable-hook-\(eventTag)-"
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix) else { return false }
            let rawHash = name
                .dropFirst(prefix.count)
                .dropLast(native ? 0 : ".sh".count)
            return (native || name.hasSuffix(".sh"))
                && rawHash.count >= 8
                && rawHash.allSatisfy(\.isHexDigit)
        }
        return try #require(candidates.count == 1 ? candidates.first?.path : nil)
    }

    private func codexInjectedHookCommands(_ output: String) -> [String] {
        Array(codexInjectedHookCommandsByEvent(output).values)
    }

    private func codexInjectedHookCommandsByEvent(_ output: String) -> [String: String] {
        let entries: [(String, String)] = output.utf8.split(separator: 0).compactMap { rawField -> (String, String)? in
            let field = String(decoding: rawField, as: UTF8.self)
            guard field.hasPrefix("hooks."),
                  let eventEnd = field.firstIndex(of: "=") else { return nil }
            let eventStart = field.index(field.startIndex, offsetBy: "hooks.".count)
            let event = String(field[eventStart..<eventEnd])
            guard let prefix = field.range(of: "command='''") else { return nil }
            let remainder = field[prefix.upperBound...]
            guard let suffix = remainder.range(of: "''',timeout=") else { return nil }
            return (event, String(remainder[..<suffix.lowerBound]))
        }
        return entries.reduce(into: [String: String]()) { result, entry in
            result[entry.0] = entry.1
        }
    }

    private func isShellSafeBareHookPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let shellSyntax = CharacterSet(charactersIn: " \t\r\n\\\"'\u{60}$&;|<>()*?[]{}!")
        return path.unicodeScalars.allSatisfy { !shellSyntax.contains($0) }
    }

    private func isContentAddressedCodexHookPath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let withoutExtension = name.hasSuffix(".sh") ? String(name.dropLast(3)) : name
        guard let separator = withoutExtension.lastIndex(of: "-") else { return false }
        let hash = withoutExtension[withoutExtension.index(after: separator)...]
        return name.hasPrefix("cmux-codex-native-hook-")
            && hash.count >= 8
            && hash.allSatisfy(\.isHexDigit)
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }

    private func decodeNULSeparatedEnvironment(_ encoded: String) -> [String: String]? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, fields.count.isMultiple(of: 2) == false else { return nil }
        var environment: [String: String] = [:]
        var index = 0
        while index + 1 < fields.count - 1 {
            guard let key = String(data: fields[index], encoding: .utf8),
                  let value = String(data: fields[index + 1], encoding: .utf8) else {
                return nil
            }
            environment[key] = value
            index += 2
        }
        return environment
    }
}
