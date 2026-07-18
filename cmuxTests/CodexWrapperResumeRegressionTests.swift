import Darwin
import Foundation
import XCTest

final class CodexWrapperResumeRegressionTests: XCTestCase {
    func testResumeSessionStartParsesSelectorsAndUsesEnvironmentForComplexCwd() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-resume-parser-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("quote\" slash\\ newline\nproject", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("cmux", isDirectory: false)
        let fakeCodex = root.appendingPathComponent("codex-real", isDirectory: false)
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
        let optionUUID = "019dad34-d218-7943-b81a-eddac5c87951"
        let directoryUUID = "019dad34-d218-7943-b81a-eddac5c87952"
        let sessionID = "019dad34-d218-7943-b81a-eddac5c87953"
        let cases: [(arguments: [String], expectedSessionID: String?)] = [
            (["resume", "-c", "feature=\(optionUUID)", "--add-dir", directoryUUID, sessionID], sessionID),
            (["resume", "-i", "/tmp/a.png", optionUUID, "--model", "gpt-5.4", sessionID], sessionID),
            (["resume", "--", sessionID], sessionID),
            (["resume", "--last"], nil),
            (["resume", "--all"], nil),
            (["resume", "named-session", sessionID], nil),
        ]

        for (index, testCase) in cases.enumerated() {
            let payload = root.appendingPathComponent("payload-\(index).json", isDirectory: false)
            let cwdCapture = root.appendingPathComponent("cwd-\(index).txt", isDirectory: false)
            let cliCapture = root.appendingPathComponent("cli-\(index).txt", isDirectory: false)
            let codexCapture = root.appendingPathComponent("codex-\(index).txt", isDirectory: false)
            let result = runCodexHookProcess(
                executablePath: wrapper.path,
                arguments: testCase.arguments,
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
            XCTAssertFalse(result.timedOut, "\(testCase.arguments): \(result.stderr)")
            XCTAssertEqual(result.status, 0, "\(testCase.arguments): \(result.stderr)")

            if let expectedSessionID = testCase.expectedSessionID {
                XCTAssertTrue(waitForFile(payload, containing: expectedSessionID, timeout: 1))
                let payloadObject = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: payload)) as? [String: Any]
                )
                XCTAssertEqual(payloadObject["session_id"] as? String, expectedSessionID)
                XCTAssertNil(payloadObject["cwd"], "cwd is inherited from the wrapper environment")
                XCTAssertTrue(waitForFile(cwdCapture, containing: project.path, timeout: 1))
                XCTAssertEqual(try String(contentsOf: cwdCapture, encoding: .utf8), project.path)
            } else {
                Thread.sleep(forTimeInterval: 0.1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path), "\(testCase.arguments)")
            }
        }
    }

    func testForkReliesOnInstalledPersistentSessionStartWithoutRebindingParent() throws {
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
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(waitForFile(cliCapture, containing: "hooks codex install --yes", timeout: 1))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: syntheticPayload.path))
    }
}
