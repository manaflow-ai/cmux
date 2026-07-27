import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct VaultAgentProcessCandidateSelectorTests {
    @Test
    func builtInRegistryFullyDecodesOnlyCandidateProcesses() {
        let processCount = 512
        let candidateCount = 16
        let workspaceID = UUID()
        let processes = (0..<processCount).map { index in
            let isCandidate = index < candidateCount
            return processInfo(
                pid: 20_000 + index,
                workspaceID: workspaceID,
                panelID: UUID(),
                name: isCandidate ? (index.isMultiple(of: 2) ? "node" : "codex") : "zsh",
                path: isCandidate
                    ? (index.isMultiple(of: 2) ? "/opt/homebrew/bin/node" : "/usr/local/bin/codex")
                    : "/bin/zsh"
            )
        }
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

        #expect(rawFetchCounts.count == processCount)
        #expect(rawFetchCounts.values.allSatisfy { $0 == 1 })
        #expect(fullDecodeCount == candidateCount)
    }

    @Test
    func sharedLiveLoaderKeepsProductionCandidateFiltering() throws {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-shared-live-candidates-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: homeDirectory) }

        let candidateCount = 2
        let workspaceID = UUID()
        let processes = (0..<64).map { index in
            let isCandidate = index < candidateCount
            return processInfo(
                pid: 60_000 + index,
                workspaceID: workspaceID,
                panelID: UUID(),
                name: isCandidate ? (index == 0 ? "node" : "codex") : "zsh",
                path: isCandidate
                    ? (index == 0 ? "/opt/homebrew/bin/node" : "/usr/local/bin/codex")
                    : "/bin/zsh"
            )
        }
        let bytesByPID = Dictionary(uniqueKeysWithValues: processes.map { process in
            (
                process.pid,
                kernProcArgs(arguments: [process.path ?? process.name], environmentEntries: [])
            )
        })
        var fullDecodeCount = 0

        _ = SharedLiveAgentIndexLoader(
            homeDirectory: homeDirectory.path,
            fileManager: fileManager,
            registry: builtInRegistry,
            processSnapshotProvider: { processSnapshot(processes) },
            processArgumentBytesProvider: { bytesByPID[$0] },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: bytes)
            },
            processIdentityProvider: { _ in nil }
        ).loadResultSynchronously()

        #expect(fullDecodeCount == candidateCount)
    }

    @Test
    func globalCustomRuleKeepsExhaustiveDetection() throws {
        let processCount = 64
        let workspaceID = UUID()
        let matchingPID = 30_017
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
                ? ["/bin/zsh", "/tmp/custom-agent-entrypoint", "--session", "custom-session"]
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
        var fullDecodeCount = 0

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: [registration]),
            fileManager: .default,
            processSnapshot: processSnapshot(processes),
            capturedAt: 42,
            processArgumentBytesProvider: { bytesByPID[$0] },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: bytes)
            }
        )

        #expect(fullDecodeCount == processCount)
        #expect(try #require(detected.values.first).snapshot.sessionId == "custom-session")
    }

    @Test
    func rawArgumentNeedleAdmitsUnknownBackgroundProcess() {
        let process = processInfo(
            pid: 40_000,
            workspaceID: UUID(),
            panelID: UUID(),
            name: "python3",
            path: "/usr/bin/python3"
        )
        let bytes = kernProcArgs(
            arguments: [
                "/usr/bin/python3",
                "/opt/node_modules/@OH-MY-PI/pi-coding-agent/dist/cli.js",
            ],
            environmentEntries: ["PWD=/"]
        )
        var fullDecodeCount = 0

        _ = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: builtInRegistry,
            fileManager: .default,
            processSnapshot: processSnapshot([process]),
            capturedAt: 42,
            processArgumentBytesProvider: { _ in bytes },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: bytes)
            }
        )

        #expect(fullDecodeCount == 1)
    }

    @Test
    func productionFilterPreservesCustomClaudeForkFallback() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let parentSessionID = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
        let process = processInfo(
            pid: 45_000,
            workspaceID: workspaceID,
            panelID: panelID,
            name: "claude-custom",
            path: "/opt/tools/claude-custom"
        )
        let bytes = kernProcArgs(
            arguments: [
                "/opt/tools/claude-custom",
                "--resume",
                parentSessionID,
                "--fork-session",
                "--model",
                "sonnet",
            ],
            environmentEntries: [
                "CMUX_AGENT_LAUNCH_KIND=claude",
                "CMUX_AGENT_LAUNCH_EXECUTABLE=/opt/tools/claude-custom",
                "PWD=/tmp/project",
            ]
        )
        var fullDecodeCount = 0

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: builtInRegistry,
            fileManager: .default,
            processSnapshot: processSnapshot([process]),
            capturedAt: 42,
            processArgumentBytesProvider: { _ in bytes },
            processArgumentsDecoder: { bytes in
                fullDecodeCount += 1
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(fromKernProcArgs: bytes)
            }
        )

        let key = RestorableAgentSessionIndex.PanelKey(
            workspaceId: workspaceID,
            panelId: panelID
        )
        let entry = try #require(detected[key])
        #expect(entry.snapshot.kind == .claude)
        #expect(entry.snapshot.sessionId == parentSessionID)
        #expect(entry.snapshot.launchCommand?.arguments == ["claude", "--model", "sonnet"])
        #expect(fullDecodeCount == 1)
    }

    @Test
    func projectRuleAdmitsUnknownBackgroundProcess() throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-process-candidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: projectRoot) }
        let configDirectory = projectRoot.appendingPathComponent(".cmux", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "vault": {
            "agents": [{
              "id": "project-agent",
              "name": "Project Agent",
              "detect": { "argvContains": "project-agent-entrypoint" },
              "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
              "resumeCommand": "project-agent --session {{sessionId}}"
            }]
          }
        }
        """.write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            atomically: true,
            encoding: .utf8
        )

        let workspaceID = UUID()
        let panelID = UUID()
        let process = processInfo(
            pid: 50_000,
            workspaceID: workspaceID,
            panelID: panelID,
            name: "unknown-worker",
            path: "/tmp/unknown-worker"
        )
        let bytes = kernProcArgs(
            arguments: [
                "/tmp/unknown-worker",
                "project-agent-entrypoint",
                "--session",
                "project-session",
            ],
            environmentEntries: ["PWD=\(projectRoot.path)"]
        )

        let detected = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: builtInRegistry,
            fileManager: fileManager,
            processSnapshot: processSnapshot([process]),
            capturedAt: 42,
            processArgumentBytesProvider: { _ in bytes }
        )

        let entry = try #require(detected.values.first)
        #expect(entry.snapshot.kind == .custom("project-agent"))
        #expect(entry.snapshot.sessionId == "project-session")
    }

    @Test
    func projectWorkingDirectoryParserPrefersLaunchDirectory() {
        let bytes = kernProcArgs(
            arguments: ["/bin/zsh"],
            environmentEntries: [
                "PWD=/pwd-project",
                "CMUX_AGENT_LAUNCH_CWD=/launch-project",
            ]
        )

        #expect(
            CmuxTopProcessSnapshot.processProjectWorkingDirectory(fromKernProcArgs: bytes)
                == "/launch-project"
        )
        #expect(
            CmuxTopProcessSnapshot.processProjectWorkingDirectory(fromKernProcArgs: [1, 2, 3])
                == nil
        )
    }

    private var builtInRegistry: CmuxVaultAgentRegistry {
        CmuxVaultAgentRegistry(registrations: [
            .builtInPi,
            .builtInOmp,
            .builtInCampfire,
            .builtInAntigravity,
            .builtInGrok,
            .builtInKimi,
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
        path: String
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
            processGroupID: nil,
            terminalProcessGroupID: nil,
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
        var argc = Int32(arguments.count).littleEndian
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        appendCString(arguments.first ?? "", to: &bytes)
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
}
