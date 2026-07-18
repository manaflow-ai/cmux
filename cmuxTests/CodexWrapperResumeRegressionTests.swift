import Darwin
import Foundation
import Testing

@Suite
struct CodexWrapperResumeRegressionTests {
    struct ResumeInvocationCase: Sendable, CustomTestStringConvertible {
        let arguments: [String]
        let expectedSessionID: String?

        var testDescription: String {
            arguments.joined(separator: " ")
        }
    }

    static let resumeInvocationCases: [ResumeInvocationCase] = {
        let optionUUID = "019dad34-d218-7943-b81a-eddac5c87951"
        let directoryUUID = "019dad34-d218-7943-b81a-eddac5c87952"
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87953"
        let rejectedRootBooleanOptions = [
            "--strict-config",
            "--oss",
            "--yolo",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
            "--search",
            "--no-alt-screen",
        ]
        let rejectedResumeBooleanOptions = [
            "--all",
            "--include-non-interactive",
            "--last",
        ]
        let rejectedBooleanAssignments = rejectedRootBooleanOptions.map {
            ResumeInvocationCase(
                arguments: ["\($0)=false", "resume", sessionID],
                expectedSessionID: nil
            )
        } + rejectedResumeBooleanOptions.map {
            ResumeInvocationCase(
                arguments: ["resume", "\($0)=false", sessionID],
                expectedSessionID: nil
            )
        }
        return [
            ResumeInvocationCase(
                arguments: ["resume", "-c", "feature=\(optionUUID)", "--add-dir", directoryUUID, sessionID],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(
                arguments: ["--model=gpt-5.4", "-c=feature=\(optionUUID)", "resume", sessionID],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(
                arguments: ["-mgpt-5.4", "-cfeature=true", "resume", sessionID],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(
                arguments: ["resume", "--model=gpt-5.4", "--add-dir=\(directoryUUID)", sessionID],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(
                arguments: ["resume", "-mgpt-5.4", "-cfeature=true", "-i/tmp/a.png", sessionID],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(arguments: ["resume", "--yolo", sessionID], expectedSessionID: sessionID),
            ResumeInvocationCase(
                arguments: ["resume", "-i", "/tmp/a.png", optionUUID, "--model", "gpt-5.4", sessionID],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(
                arguments: ["resume", "--image=/tmp/a.png", sessionID],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(
                arguments: ["resume", sessionID, "--image", "/tmp/a.png"],
                expectedSessionID: sessionID
            ),
            ResumeInvocationCase(arguments: ["resume", sessionID, "--image"], expectedSessionID: nil),
            ResumeInvocationCase(arguments: ["resume", sessionID, "--model"], expectedSessionID: nil),
            ResumeInvocationCase(arguments: ["--all", "resume", sessionID], expectedSessionID: nil),
            ResumeInvocationCase(arguments: ["--last", "resume", sessionID], expectedSessionID: nil),
            // Unknown options still reach Codex unchanged, but the wrapper
            // cannot infer their width and therefore must not synthesize a rebind.
            ResumeInvocationCase(
                arguments: ["--future-mode=fast", "resume", sessionID],
                expectedSessionID: nil
            ),
            ResumeInvocationCase(
                arguments: ["resume", "--future-mode=fast", sessionID],
                expectedSessionID: nil
            ),
        ] + rejectedBooleanAssignments + [
            ResumeInvocationCase(arguments: ["resume", "--", sessionID], expectedSessionID: sessionID),
            ResumeInvocationCase(arguments: ["resume", "--last"], expectedSessionID: nil),
            ResumeInvocationCase(arguments: ["resume", "--all"], expectedSessionID: nil),
            ResumeInvocationCase(arguments: ["resume", "named-session", sessionID], expectedSessionID: nil),
        ]
    }()

    @Test(arguments: resumeInvocationCases)
    func `Resume SessionStart parses selectors and uses environment for complex cwd`(
        invocation: ResumeInvocationCase
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-resume-parser-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("quote\" slash\\ newline\nproject", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let payload = root.appendingPathComponent("payload.json", isDirectory: false)
        let cwdCapture = root.appendingPathComponent("cwd.txt", isDirectory: false)
        let cliCapture = root.appendingPathComponent("cli.txt", isDirectory: false)
        let codexCapture = root.appendingPathComponent("codex.txt", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("resume")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "case \" $* \" in",
            "  *\" hooks codex session-start \"*)",
            "    printf '%s' \"${CMUX_AGENT_LAUNCH_CWD:-${PWD:-}}\" > \"$TEST_SESSION_CWD\"",
            "    cat > \"$TEST_SESSION_PAYLOAD\"",
            "    ;;",
            "esac",
            "printf '%s\\n' \"$*\" >> \"$TEST_CLI_CAPTURE\"",
            "exit 0",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" > \"$TEST_CODEX_CAPTURE\"",
        ])

        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: invocation.arguments,
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-resume-parser",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                "TEST_SESSION_PAYLOAD": payload.path,
                "TEST_SESSION_CWD": cwdCapture.path,
                "TEST_CLI_CAPTURE": cliCapture.path,
                "TEST_CODEX_CAPTURE": codexCapture.path,
            ],
            currentDirectoryURL: project,
            timeout: 3
        )
        #expect(!result.timedOut, "\(invocation.arguments): \(result.stderr)")
        #expect(result.status == 0, "\(invocation.arguments): \(result.stderr)")
        #expect(
            try String(contentsOf: codexCapture, encoding: .utf8)
                .trimmingCharacters(in: .newlines) == invocation.arguments.joined(separator: " ")
        )

        if let expectedSessionID = invocation.expectedSessionID {
            #expect(waitForFile(payload, containing: expectedSessionID, timeout: 1))
            let payloadObject = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: payload)) as? [String: Any]
            )
            #expect(payloadObject["session_id"] as? String == expectedSessionID)
            #expect(payloadObject["cwd"] == nil, "cwd is inherited from the wrapper environment")
            #expect(waitForFile(cwdCapture, containing: project.path, timeout: 1))
            #expect(try String(contentsOf: cwdCapture, encoding: .utf8) == project.path)
        } else {
            Thread.sleep(forTimeInterval: 0.1)
            #expect(!FileManager.default.fileExists(atPath: payload.path), "\(invocation.arguments)")
            let cliInvocations = (try? String(contentsOf: cliCapture, encoding: .utf8)) ?? ""
            #expect(
                !cliInvocations.contains("hooks codex session-start"),
                "\(invocation.arguments): \(cliInvocations)"
            )
        }
    }

    @Test
    func `Fork relies on installed persistent SessionStart without rebinding parent`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-fork-session-start-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
        let cliCapture = root.appendingPathComponent("cli.txt", isDirectory: false)
        let syntheticPayload = root.appendingPathComponent("synthetic.json", isDirectory: false)
        let socketPath = makeCodexHookSocketPath("fork")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }

        try makeCodexHookExecutableShellFile(at: fakeCLI, lines: [
            "#!/bin/sh",
            "printf '%s\\n' \"$*\" >> \"$TEST_CLI_CAPTURE\"",
            "case \" $* \" in",
            "  *\" hooks codex session-start \"*) cat > \"$TEST_SESSION_PAYLOAD\" ;;",
            "esac",
            "exit 0",
        ])
        try makeCodexHookExecutableShellFile(at: fakeCodex, lines: ["#!/bin/sh", "exit 0"])
        let wrapper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/cmux-codex-wrapper", isDirectory: false)
        let result = runCodexHookProcess(
            executablePath: wrapper.path,
            arguments: ["fork", "019dad34-d218-7943-b81a-eddac5c87951"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SURFACE_ID": "surface-fork",
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_BUNDLED_CLI_PATH": fakeCLI.path,
                "CMUX_CUSTOM_CODEX_PATH": fakeCodex.path,
                "TEST_CLI_CAPTURE": cliCapture.path,
                "TEST_SESSION_PAYLOAD": syntheticPayload.path,
            ],
            timeout: 3
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(waitForFile(cliCapture, containing: "hooks codex install --yes", timeout: 1))
        Thread.sleep(forTimeInterval: 0.1)
        #expect(!FileManager.default.fileExists(atPath: syntheticPayload.path))
    }
}
