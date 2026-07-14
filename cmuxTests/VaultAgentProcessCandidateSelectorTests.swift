import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VaultAgentProcessCandidateSelectorTests: XCTestCase {
    func testBuiltInRegistryFetchesEveryRawBufferButFullyDecodesOnlyCandidates() {
        let processCount = 2_048
        let agentCount = 64
        let workspaceID = UUID()
        let processes = (0..<processCount).map { index in
            let isAgentCandidate = index < agentCount
            let isNodeHost = index.isMultiple(of: 2)
            return processInfo(
                pid: 20_000 + index,
                workspaceID: workspaceID,
                panelID: UUID(),
                name: isAgentCandidate ? (isNodeHost ? "node" : "codex") : "zsh",
                path: isAgentCandidate
                    ? (isNodeHost ? "/opt/homebrew/bin/node" : "/usr/local/bin/codex")
                    : "/bin/zsh"
            )
        }
        let snapshot = processSnapshot(processes)
        let bytesByPID = Dictionary(uniqueKeysWithValues: processes.map { process in
            (
                process.pid,
                kernProcArgs(arguments: [process.path ?? process.name], environmentEntries: [])
            )
        })
        var rawFetchCounts: [Int: Int] = [:]
        var fullDecodeCount = 0

        _ = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: builtInRegistry,
            fileManager: .default,
            processSnapshot: snapshot,
            capturedAt: 42,
            processArgumentBytesProvider: { processID in
                rawFetchCounts[processID, default: 0] += 1
                return bytesByPID[processID]
            },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: bytes)
            }
        )

        XCTAssertEqual(rawFetchCounts.count, processCount)
        XCTAssertTrue(rawFetchCounts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(fullDecodeCount, agentCount)
    }

    func testGlobalCustomRuleFetchesAndDecodesEachProcessExactlyOnce() throws {
        let processCount = 256
        let workspaceID = UUID()
        let matchingPID = 30_173
        let sessionID = "custom-session"
        let processes = (0..<processCount).map { index in
            processInfo(
                pid: 30_000 + index,
                workspaceID: workspaceID,
                panelID: UUID(),
                name: "zsh",
                path: "/bin/zsh"
            )
        }
        let bytesByPID = Dictionary(uniqueKeysWithValues: processes.map { process in
            let arguments = process.pid == matchingPID
                ? ["/bin/zsh", "/tmp/custom-agent-entrypoint", "--session", sessionID]
                : ["/bin/zsh"]
            return (process.pid, kernProcArgs(arguments: arguments, environmentEntries: []))
        })
        let registration = CmuxVaultAgentRegistration(
            id: "custom-agent",
            name: "Custom Agent",
            detect: CmuxVaultAgentDetectRule(argvContains: ["custom-agent-entrypoint"]),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "custom-agent --session {{sessionId}}"
        )
        var rawFetchCounts: [Int: Int] = [:]
        var fullDecodeCount = 0

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: [registration]),
            fileManager: .default,
            processSnapshot: processSnapshot(processes),
            capturedAt: 42,
            processArgumentBytesProvider: { processID in
                rawFetchCounts[processID, default: 0] += 1
                return bytesByPID[processID]
            },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: bytes)
            }
        )

        XCTAssertEqual(rawFetchCounts.count, processCount)
        XCTAssertTrue(rawFetchCounts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(fullDecodeCount, processCount)
        XCTAssertEqual(try XCTUnwrap(detected.values.first).snapshot.sessionId, sessionID)
    }

    func testEnvOnlyProjectRuleAdmitsUnknownBackgroundProcess() throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-candidate-env-\(UUID().uuidString)", isDirectory: true)
        try writeProjectAgentConfig(
            projectRoot: projectRoot,
            id: "environment-agent",
            argumentNeedle: "environment-agent-entrypoint"
        )
        defer { try? fileManager.removeItem(at: projectRoot) }

        let workspaceID = UUID()
        let panelID = UUID()
        let foregroundPID = 40_000
        let backgroundPID = 40_001
        let sessionID = "environment-session"
        let processes = [
            processInfo(
                pid: foregroundPID,
                workspaceID: workspaceID,
                panelID: panelID,
                name: "zsh",
                path: "/bin/zsh",
                processGroupID: foregroundPID,
                terminalProcessGroupID: foregroundPID
            ),
            processInfo(
                pid: backgroundPID,
                workspaceID: workspaceID,
                panelID: panelID,
                name: "unknown-worker",
                path: "/tmp/unknown-worker"
            ),
        ]
        let bytesByPID = [
            foregroundPID: kernProcArgs(
                arguments: ["/bin/zsh"],
                environmentEntries: ["PWD=/"]
            ),
            backgroundPID: kernProcArgs(
                arguments: [
                    "/tmp/unknown-worker",
                    "environment-agent-entrypoint",
                    "--session",
                    sessionID,
                ],
                environmentEntries: ["PWD=\(projectRoot.path)"]
            ),
        ]
        var fullDecodeCount = 0

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: builtInRegistry,
            fileManager: fileManager,
            processSnapshot: processSnapshot(processes),
            capturedAt: 42,
            processArgumentBytesProvider: { bytesByPID[$0] },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: bytes)
            }
        )

        XCTAssertEqual(fullDecodeCount, 2)
        let entry = try XCTUnwrap(detected.values.first)
        XCTAssertEqual(entry.snapshot.kind, .custom("environment-agent"))
        XCTAssertEqual(entry.snapshot.sessionId, sessionID)
    }

    func testLaunchCWDProjectRegistryPreservesPrecedenceOverPWD() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-candidate-precedence-\(UUID().uuidString)", isDirectory: true)
        let pwdProject = root.appendingPathComponent("pwd-project", isDirectory: true)
        let launchProject = root.appendingPathComponent("launch-project", isDirectory: true)
        try writeProjectAgentConfig(
            projectRoot: pwdProject,
            id: "pwd-agent",
            argumentNeedle: "pwd-agent-entrypoint"
        )
        try writeProjectAgentConfig(
            projectRoot: launchProject,
            id: "launch-agent",
            argumentNeedle: "launch-agent-entrypoint"
        )
        defer { try? fileManager.removeItem(at: root) }

        let process = processInfo(
            pid: 50_000,
            workspaceID: UUID(),
            panelID: UUID(),
            name: "unknown-worker",
            path: "/tmp/unknown-worker"
        )
        let bytes = kernProcArgs(
            arguments: [
                "/tmp/unknown-worker",
                "launch-agent-entrypoint",
                "--session",
                "launch-session",
            ],
            environmentEntries: [
                "PWD=\(pwdProject.path)",
                "CMUX_AGENT_LAUNCH_CWD=\(launchProject.path)",
            ]
        )

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: builtInRegistry,
            fileManager: fileManager,
            processSnapshot: processSnapshot([process]),
            capturedAt: 42,
            processArgumentBytesProvider: { _ in bytes }
        )

        let entry = try XCTUnwrap(detected.values.first)
        XCTAssertEqual(entry.snapshot.kind, .custom("launch-agent"))
        XCTAssertEqual(entry.snapshot.sessionId, "launch-session")
    }

    func testProjectWorkingDirectoryParserHandlesPrecedenceAndMalformedBuffers() {
        let precedenceBytes = kernProcArgs(
            arguments: ["/bin/zsh"],
            environmentEntries: [
                "PWD=/pwd-project",
                "CMUX_AGENT_LAUNCH_CWD=/launch-project",
            ]
        )
        XCTAssertEqual(
            CmuxTopProcessSnapshot.processProjectWorkingDirectory(fromKernProcArgs: precedenceBytes),
            "/launch-project"
        )

        let pwdBytes = kernProcArgs(
            arguments: ["/bin/zsh"],
            environmentEntries: ["PWD=/pwd-project"]
        )
        XCTAssertEqual(
            CmuxTopProcessSnapshot.processProjectWorkingDirectory(fromKernProcArgs: pwdBytes),
            "/pwd-project"
        )
        XCTAssertNil(CmuxTopProcessSnapshot.processProjectWorkingDirectory(fromKernProcArgs: [1, 2, 3]))

        var truncatedArgc = Int32(1).littleEndian
        let truncatedAfterArgc = withUnsafeBytes(of: &truncatedArgc) { Array($0) } + [UInt8(ascii: "x")]
        XCTAssertNil(
            CmuxTopProcessSnapshot.processProjectWorkingDirectory(
                fromKernProcArgs: truncatedAfterArgc
            )
        )
        XCTAssertNil(
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(
                fromKernProcArgs: truncatedAfterArgc
            )
        )
    }

    func testUnknownForegroundProcessRemainsCandidate() {
        let process = processInfo(
            pid: 60_000,
            workspaceID: UUID(),
            panelID: UUID(),
            name: "custom-wrapper",
            path: "/tmp/custom-wrapper",
            processGroupID: 60_000,
            terminalProcessGroupID: 60_000
        )
        let selector = VaultAgentProcessCandidateSelector(
            processes: [process],
            registry: builtInRegistry
        )

        XCTAssertEqual(selector.processIDs, Set([process.pid]))
    }

    private var builtInRegistry: CmuxVaultAgentRegistry {
        CmuxVaultAgentRegistry(registrations: [
            .builtInPi,
            .builtInOmp,
            .builtInCampfire,
            .builtInAntigravity,
            .builtInGrok,
        ])
    }

    private func processSnapshot(_ processes: [CmuxTopProcessInfo]) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
    }

    private func processInfo(
        pid: Int,
        workspaceID: UUID,
        panelID: UUID,
        name: String,
        path: String,
        processGroupID: Int? = nil,
        terminalProcessGroupID: Int? = nil
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: panelID,
            cmuxAttributionReason: "candidate-selector-test",
            processGroupID: processGroupID,
            terminalProcessGroupID: terminalProcessGroupID,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }

    private func kernProcArgs(
        arguments: [String],
        environmentEntries: [String]
    ) -> [UInt8] {
        precondition(!arguments.isEmpty)
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        appendCString(arguments[0], to: &bytes)
        bytes.append(0)
        for argument in arguments {
            appendCString(argument, to: &bytes)
        }
        for entry in environmentEntries {
            appendCString(entry, to: &bytes)
        }
        return bytes
    }

    private func appendCString(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
    }

    private func writeProjectAgentConfig(
        projectRoot: URL,
        id: String,
        argumentNeedle: String
    ) throws {
        let configDirectory = projectRoot.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "vault": {
            "agents": [
              {
                "id": "\(id)",
                "name": "Project Agent",
                "detect": { "argvContains": "\(argumentNeedle)" },
                "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
                "resumeCommand": "project-agent --session {{sessionId}}"
              }
            ]
          }
        }
        """.write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
