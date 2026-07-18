import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func lateStopFromExitedOneShotCompletesGenerationWithoutFallbackAuthority() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-exited-one-shot-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let pid = Int(process.processIdentifier)
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let environment = [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
            "CMUX_RUNTIME_ID": "one-shot-runtime",
        ]
        let store = ClaudeHookSessionStore(processEnv: environment, agentName: "codex")
        let launchCommand = AgentHookLaunchCommandRecord(
            launcher: "codex",
            executablePath: executable.path,
            arguments: [],
            workingDirectory: root.path,
            environment: nil,
            capturedAt: Date().timeIntervalSince1970,
            source: "rejected"
        )
        let sessionID = "one-shot-session"
        #expect(try store.upsert(
            sessionId: sessionID,
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: launchCommand,
            markActive: true
        ))
        let original = try #require(try store.lookup(sessionId: sessionID))
        let originalRunID = try #require(original.activeRunId)
        #expect(original.runs?.first { $0.runId == originalRunID }?.processStartedAt != nil)

        process.terminate()
        process.waitUntilExit()

        let firstLateStop = try store.recordPromptStop(
            sessionId: sessionID,
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: launchCommand,
            lastSubtitle: nil,
            lastBody: nil
        )
        #expect(!firstLateStop.accepted)
        let completed = try #require(try store.lookup(sessionId: sessionID))
        #expect(completed.completedAt != nil)
        #expect(completed.sessionState == .ended)
        #expect(completed.restoreAuthority == false)
        #expect(completed.activeRunId == nil)
        #expect(completed.runs?.allSatisfy { $0.endedAt != nil && !$0.restoreAuthority } == true)
        #expect(completed.runs?.contains { $0.runId.hasPrefix("runtime:") } == false)
        #expect(store.snapshot().activeSessionsByWorkspace.isEmpty)
        #expect(store.snapshot().activeSessionsBySurface.isEmpty)

        let firstCompletedAt = completed.completedAt
        let firstUpdatedAt = completed.updatedAt
        let duplicateLateStop = try store.recordPromptStop(
            sessionId: sessionID,
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: launchCommand,
            lastSubtitle: nil,
            lastBody: nil
        )
        #expect(!duplicateLateStop.accepted)
        let afterDuplicate = try #require(try store.lookup(sessionId: sessionID))
        #expect(afterDuplicate.completedAt == firstCompletedAt)
        #expect(afterDuplicate.updatedAt == firstUpdatedAt)
        #expect(afterDuplicate.runs == completed.runs)
    }

    @Test func lateStopCannotReplaceAnewerActiveProcessGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-stale-stop-newer-run-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let currentPID = Int(process.processIdentifier)
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
            "CMUX_RUNTIME_ID": "current-runtime",
        ], agentName: "codex")
        let sessionID = "resumed-session"
        #expect(try store.upsert(
            sessionId: sessionID,
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: currentPID,
            launchCommand: nil,
            markActive: true
        ))
        let current = try #require(try store.lookup(sessionId: sessionID))
        let currentRunID = try #require(current.activeRunId)

        let staleStop = try store.recordPromptStop(
            sessionId: sessionID,
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: Int(Int32.max) - 91,
            launchCommand: nil,
            lastSubtitle: nil,
            lastBody: nil
        )
        #expect(!staleStop.accepted)
        let preserved = try #require(try store.lookup(sessionId: sessionID))
        #expect(preserved.completedAt == nil)
        #expect(preserved.activeRunId == currentRunID)
        #expect(preserved.runs?.first { $0.runId == currentRunID }?.endedAt == nil)
        #expect(preserved.runs?.first { $0.runId == currentRunID }?.restoreAuthority == true)
        #expect(store.snapshot().activeSessionsByWorkspace["workspace-a"]?.sessionId == sessionID)
        #expect(store.snapshot().activeSessionsBySurface["surface-a"]?.sessionId == sessionID)
    }

    @Test func reusedPIDStopCompletesTheRecordedGenerationInsteadOfPromotingTheReuse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-reused-stop-pid-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let pid = Int(process.processIdentifier)
        let liveLineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "reused-pid-session",
            pid: pid,
            environment: [:]
        )
        let liveStartedAt = try #require(liveLineage.processStartedAt)
        let recordedStartedAt = liveStartedAt - 10
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["reused-pid-session": [
                "sessionId": "reused-pid-session",
                "workspaceId": "workspace-a",
                "surfaceId": "surface-a",
                "pid": pid,
                "activeRunId": "recorded-generation",
                "runId": "recorded-generation",
                "restoreAuthority": true,
                "sessionState": "active",
                "startedAt": recordedStartedAt,
                "updatedAt": recordedStartedAt,
                "runs": [[
                    "runId": "recorded-generation",
                    "pid": pid,
                    "processStartedAt": recordedStartedAt,
                    "restoreAuthority": true,
                    "startedAt": recordedStartedAt,
                    "updatedAt": recordedStartedAt,
                ]],
            ]],
            "activeSessionsByWorkspace": ["workspace-a": [
                "sessionId": "reused-pid-session",
                "updatedAt": recordedStartedAt,
            ]],
            "activeSessionsBySurface": ["surface-a": [
                "sessionId": "reused-pid-session",
                "updatedAt": recordedStartedAt,
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
        ], agentName: "codex")

        let reusedStop = try store.recordPromptStop(
            sessionId: "reused-pid-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: nil,
            lastSubtitle: nil,
            lastBody: nil
        )
        #expect(!reusedStop.accepted)
        let completed = try #require(try store.lookup(sessionId: "reused-pid-session"))
        #expect(completed.completedAt != nil)
        #expect(completed.activeRunId == nil)
        #expect(completed.runs?.count == 1)
        #expect(completed.runs?.first?.runId == "recorded-generation")
        #expect(completed.runs?.first?.endedAt != nil)
        #expect(completed.runs?.first?.restoreAuthority == false)
        #expect(store.snapshot().activeSessionsByWorkspace.isEmpty)
        #expect(store.snapshot().activeSessionsBySurface.isEmpty)
    }

    @Test func liveLegacyPIDRecordMigratesToAnExactProcessGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-legacy-stop-generation-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let pid = Int(process.processIdentifier)
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "legacy-live-session",
            pid: pid,
            environment: [:]
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        let recordStartedAt = Date().timeIntervalSince1970
        #expect(processStartedAt <= recordStartedAt)
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "sessions": ["legacy-live-session": [
                "sessionId": "legacy-live-session",
                "workspaceId": "workspace-a",
                "surfaceId": "surface-a",
                "pid": pid,
                "startedAt": recordStartedAt,
                "updatedAt": recordStartedAt,
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
        ], agentName: "codex")

        let stop = try store.recordPromptStop(
            sessionId: "legacy-live-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: nil,
            lastSubtitle: nil,
            lastBody: nil
        )
        #expect(stop.accepted)
        let migrated = try #require(try store.lookup(sessionId: "legacy-live-session"))
        let runID = try #require(migrated.activeRunId)
        let run = try #require(migrated.runs?.first { $0.runId == runID })
        let runStartedAt = try #require(run.processStartedAt)
        #expect(migrated.completedAt == nil)
        #expect(run.pid == pid)
        #expect(abs(runStartedAt - processStartedAt) <= 0.001)
        #expect(run.endedAt == nil)
    }

    @Test func liveOneShotStopCompletesEverySupportedLaunchGeneration() throws {
        let launches: [(agent: String, executable: String, arguments: [String])] = [
            ("codex", "codex", ["exec", "fix this"]),
            ("codex", "codex", ["exec", "--future-output", "fix this"]),
            ("codex", "codex", ["review"]),
            ("kimi", "kimi", ["--print", "fix this", "--yolo"]),
            ("gemini", "gemini", ["-p", "fix this", "--yolo"]),
            ("grok", "grok", ["--single", "fix this", "--always-approve"]),
            ("pi", "pi", ["-p", "fix this", "--verbose"]),
            ("cursor", "cursor-agent", ["-p", "fix this", "--auto-review"]),
            ("amp", "amp", ["-x", "fix this", "--no-archive-after-execute"]),
            ("amp", "amp", ["-x", "fix this", "--plugin-ready-timeout", "30"]),
            ("opencode", "opencode", ["run", "fix this", "--format", "json", "--pure"]),
            ("claude", "claude", ["-p", "fix this"]),
            ("claude", "claude", ["--print", "fix this"]),
            ("gemini", "gemini", ["-p", "fix this"]),
            ("gemini", "gemini", ["--prompt", "fix this"]),
            ("cursor", "cursor-agent", ["--print", "fix this"]),
            ("factory", "droid", ["exec", "fix this"]),
            ("opencode", "opencode", ["run", "fix this"]),
            ("grok", "grok", ["--single", "fix this"]),
            ("pi", "pi", ["--print", "fix this"]),
            ("omp", "omp", ["--print", "fix this"]),
            ("campfire", "campfire", ["--print", "fix this"]),
            ("amp", "amp", ["--execute", "fix this"]),
            ("amp", "amp", ["--print", "fix this"]),
            ("antigravity", "agy", ["--prompt", "fix this"]),
            ("antigravity", "agy", ["--print", "fix this"]),
            ("rovodev", "acli", ["rovodev", "run", "--prompt", "fix this"]),
            ("rovodev", "acli", ["rovodev", "run", "fix this"]),
            ("hermes-agent", "hermes", ["--oneshot", "fix this"]),
            ("hermes-agent", "hermes", ["chat", "-q", "fix this"]),
            ("copilot", "copilot", ["--prompt", "fix this"]),
            ("codebuddy", "codebuddy", ["--print", "fix this"]),
            ("qoder", "qodercli", ["--print", "fix this"]),
            ("kiro", "kiro-cli", ["chat", "--no-interactive", "fix this"]),
            ("kimi", "kimi", ["--print", "fix this"]),
            ("kimi", "kimi", ["--quiet", "fix this"]),
        ]

        for (index, launch) in launches.enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-agent-live-one-shot-\(index)-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent(launch.executable, isDirectory: false)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/yes", toPath: executable.path)
            defer { try? FileManager.default.removeItem(at: root) }

            let process = Process()
            process.executableURL = executable
            process.arguments = launch.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            let pid = Int(process.processIdentifier)
            let sessionID = "live-one-shot-\(index)"
            let command = AgentHookLaunchCommandRecord(
                launcher: launch.agent,
                executablePath: executable.path,
                arguments: [executable.path] + launch.arguments,
                workingDirectory: root.path,
                environment: nil,
                capturedAt: Date().timeIntervalSince1970,
                source: "process"
            )
            let store = ClaudeHookSessionStore(processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("hook-sessions.json").path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
                "CMUX_RUNTIME_ID": "live-one-shot-runtime-\(index)",
            ], agentName: launch.agent)
            #expect(try store.upsert(
                sessionId: sessionID,
                workspaceId: "workspace-\(index)",
                surfaceId: "surface-\(index)",
                cwd: root.path,
                pid: pid,
                launchCommand: command,
                markActive: true
            ))

            let stop = try store.recordPromptStop(
                sessionId: sessionID,
                workspaceId: "workspace-\(index)",
                surfaceId: "surface-\(index)",
                cwd: root.path,
                pid: pid,
                launchCommand: command,
                lastSubtitle: nil,
                lastBody: nil
            )

            #expect(!stop.accepted, "\(launch.agent) \(launch.arguments) stayed active")
            let completed = try #require(try store.lookup(sessionId: sessionID))
            #expect(completed.completedAt != nil)
            #expect(completed.sessionState == .ended)
            #expect(completed.restoreAuthority == false)
            #expect(completed.activeRunId == nil)
            #expect(completed.runs?.allSatisfy { $0.endedAt != nil && !$0.restoreAuthority } == true)
            #expect(store.snapshot().activeSessionsByWorkspace.isEmpty)
            #expect(store.snapshot().activeSessionsBySurface.isEmpty)
        }
    }

    @Test func nestedOneShotStopPreservesTheRootGenerationUntilTheFinalBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-nested-one-shot-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/yes", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["exec", "fix this"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let pid = Int(process.processIdentifier)
        let command = AgentHookLaunchCommandRecord(
            launcher: "codex",
            executablePath: executable.path,
            arguments: [executable.path, "exec", "fix this"],
            workingDirectory: root.path,
            environment: nil,
            capturedAt: Date().timeIntervalSince1970,
            source: "process"
        )
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("hook-sessions.json").path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
        ], agentName: "codex")
        #expect(try store.upsert(
            sessionId: "nested-one-shot",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: command,
            markActive: true
        ))
        for _ in 0..<2 {
            let submit = try store.recordPromptSubmit(
                sessionId: "nested-one-shot",
                workspaceId: "workspace-a",
                surfaceId: "surface-a",
                cwd: root.path,
                pid: pid,
                launchCommand: command
            )
            #expect(submit.accepted)
        }

        let nestedStop = try store.recordPromptStop(
            sessionId: "nested-one-shot",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: command,
            lastSubtitle: nil,
            lastBody: nil
        )
        #expect(nestedStop.accepted)
        #expect(nestedStop.nested)
        #expect(!nestedStop.completedGeneration)
        let afterNestedStop = try #require(try store.lookup(sessionId: "nested-one-shot"))
        #expect(afterNestedStop.activePromptDepth == 1)
        #expect(afterNestedStop.completedAt == nil)
        #expect(afterNestedStop.activeRunId != nil)

        let rootStop = try store.recordPromptStop(
            sessionId: "nested-one-shot",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            launchCommand: command,
            lastSubtitle: nil,
            lastBody: nil
        )
        #expect(!rootStop.accepted)
        #expect(rootStop.completedGeneration)
        #expect(rootStop.completionReason == .terminalLaunch)
    }

    @Test func oneShotStopPreservesLiveBackgroundAuthority() throws {
        for evidence in ["incoming-pending", "stored-workload"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-agent-one-shot-background-\(evidence)-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent("claude", isDirectory: false)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/yes", toPath: executable.path)
            defer { try? FileManager.default.removeItem(at: root) }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["--print", "fix this"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            let pid = Int(process.processIdentifier)
            let command = AgentHookLaunchCommandRecord(
                launcher: "claude",
                executablePath: executable.path,
                arguments: [executable.path, "--print", "fix this"],
                workingDirectory: root.path,
                environment: nil,
                capturedAt: Date().timeIntervalSince1970,
                source: "process"
            )
            let store = ClaudeHookSessionStore(processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("hook-sessions.json").path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
            ], agentName: "claude")
            #expect(try store.upsert(
                sessionId: evidence,
                workspaceId: "workspace-a",
                surfaceId: "surface-a",
                cwd: root.path,
                pid: pid,
                launchCommand: command,
                markActive: true
            ))
            if evidence == "stored-workload" {
                try store.reconcileSemanticState(
                    sessionId: evidence,
                    workloads: [AgentWorkloadRecord(
                        id: "background-terminal",
                        kind: .backgroundTerminal,
                        phase: .running,
                        keepsSessionBusy: true,
                        startedAt: Date().timeIntervalSince1970,
                        updatedAt: Date().timeIntervalSince1970,
                        endedAt: nil,
                        endReason: nil
                    )]
                )
            }

            let stop: AgentPromptStopResult
            if evidence == "incoming-pending" {
                stop = try store.upsertPromptStop(
                    sessionId: evidence,
                    workspaceId: "workspace-a",
                    surfaceId: "surface-a",
                    cwd: root.path,
                    pid: pid,
                    launchCommand: command,
                    agentLifecycle: .running,
                    hadPendingBackgroundWorkAtStop: true,
                    markActive: true
                )
            } else {
                stop = try store.recordPromptStop(
                    sessionId: evidence,
                    workspaceId: "workspace-a",
                    surfaceId: "surface-a",
                    cwd: root.path,
                    pid: pid,
                    launchCommand: command,
                    lastSubtitle: nil,
                    lastBody: nil
                )
            }
            #expect(stop.accepted, "\(evidence) was consumed")
            #expect(!stop.completedGeneration)
            let active = try #require(try store.lookup(sessionId: evidence))
            #expect(active.completedAt == nil)
            #expect(active.activeRunId != nil)
            #expect(store.snapshot().activeSessionsByWorkspace["workspace-a"]?.sessionId == evidence)

            let drainedStop: AgentPromptStopResult
            if evidence == "incoming-pending" {
                drainedStop = try store.upsertPromptStop(
                    sessionId: evidence,
                    workspaceId: "workspace-a",
                    surfaceId: "surface-a",
                    cwd: root.path,
                    pid: pid,
                    launchCommand: command,
                    agentLifecycle: .idle,
                    hadPendingBackgroundWorkAtStop: false,
                    markActive: true
                )
            } else {
                drainedStop = try store.recordPromptStop(
                    sessionId: evidence,
                    workspaceId: "workspace-a",
                    surfaceId: "surface-a",
                    cwd: root.path,
                    pid: pid,
                    launchCommand: command,
                    lastSubtitle: nil,
                    lastBody: nil,
                    hadPendingBackgroundWorkAtStop: false
                )
            }
            #expect(!drainedStop.accepted)
            #expect(drainedStop.completedGeneration)
            #expect(drainedStop.completionReason == .terminalLaunch)
        }
    }

    @Test func liveInteractiveStopRemainsATurnBoundaryForEverySupportedAgent() throws {
        let launches: [(agent: String, executable: String, arguments: [String])] = [
            ("codex", "codex", []),
            ("codex", "codex", ["--future-launch-mode"]),
            ("claude", "claude", []),
            ("claude", "claude", ["--no-session-persistence"]),
            ("claude", "claude", ["--background", "fix this"]),
            ("claude", "claude", ["--print", "--input-format", "stream-json", "--output-format", "stream-json"]),
            ("codex", "codex", ["app-server"]),
            ("codex", "codex", ["mcp-server"]),
            ("codex", "codex", ["exec-server"]),
            ("gemini", "gemini", []),
            ("gemini", "gemini", ["--prompt-interactive", "fix this"]),
            ("cursor", "cursor-agent", []),
            ("factory", "droid", []),
            ("factory", "droid", ["exec", "--input-format", "stream-jsonrpc", "--output-format", "stream-jsonrpc"]),
            ("factory", "droid", ["exec", "--future-protocol", "fix this"]),
            ("opencode", "opencode", []),
            ("opencode", "opencode", ["pr", "123"]),
            ("opencode", "opencode", ["run", "--interactive", "fix this"]),
            ("opencode", "opencode", ["run", "--future-protocol", "fix this"]),
            ("opencode", "opencode", ["acp"]),
            ("opencode", "opencode", ["serve"]),
            ("opencode", "opencode", ["web"]),
            ("grok", "grok", []),
            ("grok", "grok", ["agent", "stdio", "--single", "fix this"]),
            ("grok", "grok", ["agent", "serve"]),
            ("grok", "grok", ["agent", "leader"]),
            ("pi", "pi", []),
            ("pi", "pi", ["--no-session"]),
            ("pi", "pi", ["--mode", "rpc", "--print", "fix this"]),
            ("omp", "omp", []),
            ("omp", "omp", ["--prompt", "fix this"]),
            ("omp", "omp", ["--mode", "rpc-ui", "--print", "fix this"]),
            ("omp", "omp", ["acp", "--print", "fix this"]),
            ("campfire", "campfire", []),
            ("campfire", "campfire", ["--no-session"]),
            ("campfire", "campfire", ["--prompt", "fix this"]),
            ("campfire", "campfire", ["--mode", "rpc", "--print", "fix this"]),
            ("amp", "amp", []),
            ("antigravity", "agy", []),
            ("antigravity", "agy", ["--prompt-interactive", "fix this"]),
            ("rovodev", "acli", []),
            ("rovodev", "acli", ["rovodev", "run"]),
            ("rovodev", "acli", ["rovodev", "run", "--prompt-interactive", "fix this"]),
            ("rovodev", "acli", ["rovodev", "config"]),
            ("hermes-agent", "hermes", []),
            ("hermes-agent", "hermes", ["-q", "fix this"]),
            ("hermes-agent", "hermes", ["acp", "--oneshot", "fix this"]),
            ("hermes-agent", "hermes", ["gateway", "run"]),
            ("copilot", "copilot", []),
            ("codebuddy", "codebuddy", []),
            ("qoder", "qodercli", []),
            ("qoder", "qodercli", ["--prompt-interactive", "fix this"]),
            ("qoder", "qodercli", ["--acp", "--print", "fix this"]),
            ("qoder", "qodercli", ["--input-format", "stream-json", "--print", "fix this"]),
            ("kiro", "kiro-cli", []),
            ("kiro", "kiro-cli", ["--no-interactive"]),
            ("kiro", "kiro-cli", ["doctor", "--no-interactive"]),
            ("kimi", "kimi", []),
            ("kimi", "kimi", ["--prompt", "fix this"]),
            ("kimi", "kimi", ["-p", "fix this"]),
            ("kimi", "kimi", ["--acp", "--print", "fix this"]),
            ("kimi", "kimi", ["acp"]),
        ]

        for (index, launch) in launches.enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-agent-live-interactive-\(index)-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent(launch.executable, isDirectory: false)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/yes", toPath: executable.path)
            defer { try? FileManager.default.removeItem(at: root) }

            let process = Process()
            process.executableURL = executable
            process.arguments = launch.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            let pid = Int(process.processIdentifier)
            let sessionID = "live-interactive-\(index)"
            let command = AgentHookLaunchCommandRecord(
                launcher: launch.agent,
                executablePath: executable.path,
                arguments: [executable.path] + launch.arguments,
                workingDirectory: root.path,
                environment: nil,
                capturedAt: Date().timeIntervalSince1970,
                source: "process"
            )
            let store = ClaudeHookSessionStore(processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("hook-sessions.json").path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
            ], agentName: launch.agent)
            #expect(try store.upsert(
                sessionId: sessionID,
                workspaceId: "workspace-\(index)",
                surfaceId: "surface-\(index)",
                cwd: root.path,
                pid: pid,
                launchCommand: command,
                markActive: true
            ))

            let stop = try store.recordPromptStop(
                sessionId: sessionID,
                workspaceId: "workspace-\(index)",
                surfaceId: "surface-\(index)",
                cwd: root.path,
                pid: pid,
                launchCommand: command,
                lastSubtitle: nil,
                lastBody: nil
            )

            #expect(stop.accepted, "\(launch.agent) interactive Stop was consumed")
            let active = try #require(try store.lookup(sessionId: sessionID))
            let runID = try #require(active.activeRunId)
            #expect(active.completedAt == nil)
            #expect(active.sessionState == .active)
            #expect(active.runs?.first { $0.runId == runID }?.endedAt == nil)
            #expect(active.runs?.first { $0.runId == runID }?.restoreAuthority == true)
        }
    }

    @Test func alreadyEndedPromptStopIsRejectedWithoutClearingAReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-ended-stop-replacement-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let pid = Int(process.processIdentifier)
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("hook-sessions.json").path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
        ], agentName: "codex")
        #expect(try store.upsert(
            sessionId: "ended-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            markActive: true
        ))
        _ = try #require(try store.consume(
            sessionId: "ended-session",
            workspaceId: nil,
            surfaceId: nil
        ))
        #expect(try store.upsert(
            sessionId: "replacement-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            markActive: true
        ))

        let staleStop = try store.upsertPromptStop(
            sessionId: "ended-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid
        )

        #expect(!staleStop.accepted)
        #expect(!staleStop.completedGeneration)
        #expect(staleStop.completionReason == nil)
        #expect(!staleStop.clearedActiveBoundary)
        #expect(store.snapshot().activeSessionsByWorkspace["workspace-a"]?.sessionId == "replacement-session")
        #expect(store.snapshot().activeSessionsBySurface["surface-a"]?.sessionId == "replacement-session")
        let replacement = try #require(try store.lookup(sessionId: "replacement-session"))
        #expect(replacement.completedAt == nil)
        #expect(replacement.restoreAuthority == true)
    }

    @Test func reusedPIDStopCompletesOldRecordWithoutClearingTheLiveReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-reused-stop-replacement-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let pid = Int(process.processIdentifier)
        let liveStartedAt = try #require(AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "replacement-session",
            pid: pid,
            environment: [:]
        ).processStartedAt)
        let recordedStartedAt = liveStartedAt - 10
        let stateURL = root.appendingPathComponent("hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["old-session": [
                "sessionId": "old-session",
                "workspaceId": "workspace-a",
                "surfaceId": "surface-a",
                "pid": pid,
                "activeRunId": "old-generation",
                "runId": "old-generation",
                "restoreAuthority": true,
                "sessionState": "active",
                "startedAt": recordedStartedAt,
                "updatedAt": recordedStartedAt,
                "runs": [[
                    "runId": "old-generation",
                    "pid": pid,
                    "processStartedAt": recordedStartedAt,
                    "restoreAuthority": true,
                    "startedAt": recordedStartedAt,
                    "updatedAt": recordedStartedAt,
                ]],
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
        ], agentName: "codex")
        #expect(try store.upsert(
            sessionId: "replacement-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            markActive: true
        ))

        let staleStop = try store.upsertPromptStop(
            sessionId: "old-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid
        )

        #expect(!staleStop.accepted)
        #expect(staleStop.completedGeneration)
        #expect(staleStop.completionReason == .processIdentityChanged)
        #expect(!staleStop.clearedActiveBoundary)
        #expect(store.snapshot().activeSessionsByWorkspace["workspace-a"]?.sessionId == "replacement-session")
        #expect(store.snapshot().activeSessionsBySurface["surface-a"]?.sessionId == "replacement-session")
        let replacement = try #require(try store.lookup(sessionId: "replacement-session"))
        #expect(replacement.completedAt == nil)
        #expect(replacement.restoreAuthority == true)
        let old = try #require(try store.lookup(sessionId: "old-session"))
        #expect(old.completedAt != nil)
        #expect(old.restoreAuthority == false)
    }

    @Test func noPIDStopCannotResurrectAnEndedRecordOverAReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-no-pid-ended-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("hook-sessions.json").path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
        ], agentName: "codex")
        #expect(try store.upsert(
            sessionId: "ended-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            markActive: true
        ))
        _ = try #require(try store.consume(
            sessionId: "ended-session",
            workspaceId: nil,
            surfaceId: nil
        ))
        #expect(try store.upsert(
            sessionId: "replacement-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            markActive: true
        ))

        let staleStop = try store.upsertPromptStop(
            sessionId: "ended-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: nil
        )

        #expect(!staleStop.accepted)
        #expect(!staleStop.completedGeneration)
        #expect(store.snapshot().activeSessionsByWorkspace["workspace-a"]?.sessionId == "replacement-session")
        #expect(store.snapshot().activeSessionsBySurface["surface-a"]?.sessionId == "replacement-session")
        let ended = try #require(try store.lookup(sessionId: "ended-session"))
        #expect(ended.completedAt != nil)
        #expect(ended.sessionState == .ended)
        #expect(ended.restoreAuthority == false)
    }

    @Test func noPIDStopCannotMutateANewerLiveGenerationOfTheSameSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-no-pid-newer-generation-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let pid = Int(process.processIdentifier)
        let store = ClaudeHookSessionStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("hook-sessions.json").path,
            "CMUX_AGENT_SESSION_REGISTRY_PATH": root.appendingPathComponent("sessions.sqlite3").path,
        ], agentName: "codex")
        #expect(try store.upsert(
            sessionId: "same-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: pid,
            markActive: true
        ))
        let before = try #require(try store.lookup(sessionId: "same-session"))
        let activeRunID = try #require(before.activeRunId)

        let staleStop = try store.recordPromptStop(
            sessionId: "same-session",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            cwd: root.path,
            pid: nil,
            launchCommand: nil,
            lastSubtitle: nil,
            lastBody: nil
        )

        #expect(!staleStop.accepted)
        #expect(!staleStop.completedGeneration)
        let after = try #require(try store.lookup(sessionId: "same-session"))
        #expect(after.updatedAt == before.updatedAt)
        #expect(after.activeRunId == activeRunID)
        #expect(after.runs == before.runs)
        #expect(after.completedAt == nil)
        #expect(store.snapshot().activeSessionsByWorkspace["workspace-a"]?.sessionId == "same-session")
        #expect(store.snapshot().activeSessionsBySurface["surface-a"]?.sessionId == "same-session")
    }

    @Test func rejectedLaunchSourceIsNonRestorableAcrossListTreeAndForkDiagnostics() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-rejected-restore-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let records: [String: Any] = [
            "rejected-nil": [
                "sessionId": "rejected-nil",
                "workspaceId": "workspace-a",
                "surfaceId": "surface-a",
                "startedAt": 100.0,
                "updatedAt": 200.0,
                "launchCommand": [
                    "launcher": "opencode",
                    "executablePath": "opencode",
                    "arguments": ["opencode"],
                    "source": "rejected",
                ],
            ],
            "rejected-true": [
                "sessionId": "rejected-true",
                "workspaceId": "workspace-b",
                "surfaceId": "surface-b",
                "isRestorable": true,
                "startedAt": 100.0,
                "updatedAt": 201.0,
                "launchCommand": [
                    "launcher": "opencode",
                    "executablePath": "opencode",
                    "arguments": ["opencode"],
                    "source": "rejected",
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": records,
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("opencode-hook-sessions.json"),
            options: .atomic
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_AGENT_SESSION_REGISTRY_PATH"] = root.appendingPathComponent("sessions.sqlite3").path

        let historyList = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "opencode", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(historyList.status == 0, Comment(rawValue: historyList.stdout))
        let historyListObject = try #require(
            JSONSerialization.jsonObject(with: Data(historyList.stdout.utf8)) as? [String: Any]
        )
        let historyRows = try #require(historyListObject["sessions"] as? [[String: Any]])
        #expect(Set(historyRows.compactMap { $0["session_id"] as? String }) == Set(records.keys))
        #expect(historyRows.allSatisfy { $0["hook_record_restorable"] as? Bool == false })
        #expect(historyRows.allSatisfy { $0["fork_supported"] as? Bool == false })

        let defaultList = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--agent", "opencode", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(defaultList.status == 0, Comment(rawValue: defaultList.stdout))
        let defaultListObject = try #require(
            JSONSerialization.jsonObject(with: Data(defaultList.stdout.utf8)) as? [String: Any]
        )
        #expect((defaultListObject["sessions"] as? [[String: Any]])?.isEmpty == true)

        let defaultTree = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--agent", "opencode", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(defaultTree.status == 0, Comment(rawValue: defaultTree.stdout))
        let defaultTreeObject = try #require(
            JSONSerialization.jsonObject(with: Data(defaultTree.stdout.utf8)) as? [String: Any]
        )
        #expect((defaultTreeObject["nodes"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func lateHookFromCompletedProcessCannotReactivateSession() throws {
        let pid = Int(getpid())
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "completed-session",
            pid: pid,
            environment: [:]
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "completed-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "completedAt": now,
            "startedAt": now - 10,
            "updatedAt": now,
            "runs": [[
                "runId": lineage.runId,
                "pid": pid,
                "processStartedAt": processStartedAt,
                "restoreAuthority": false,
                "startedAt": now - 10,
                "updatedAt": now,
                "endedAt": now,
            ]],
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)

        #expect(!AgentHookSessionActivationPolicy().canActivate(
            record: record,
            lineage: lineage,
            hasIncomingPID: true
        ))
        #expect(!AgentSessionSemanticUpdatePolicy().canUpdate(record: record))
    }

    @Test func verifiedReplacementRootRegainsRestoreAuthority() throws {
        let completedRoot = AgentSessionRunRecord(
            runId: "stable-root-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: false,
            startedAt: 100,
            updatedAt: 110,
            endedAt: 110
        )
        let replacement = AgentHookSessionLineage(
            runId: "stable-root-run",
            pid: 202,
            processStartedAt: 200,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [completedRoot],
            activeRunId: completedRoot.runId,
            lineage: replacement,
            now: 210
        )
        let run = try #require(runs.first)

        #expect(run.restoreAuthority)
        #expect(run.relationship == nil)
        #expect(run.endedAt == nil)
    }

    @Test func replacingActiveRunCreatesResumedEdge() throws {
        let previous = AgentSessionRunRecord(
            runId: "previous-root-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: 100,
            updatedAt: 110,
            endedAt: nil
        )
        let resumed = AgentHookSessionLineage(
            runId: "resumed-root-run",
            pid: 202,
            processStartedAt: 200,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [previous],
            activeRunId: previous.runId,
            lineage: resumed,
            now: 210
        )
        let previousRun = try #require(runs.first { $0.runId == previous.runId })
        let resumedRun = try #require(runs.first { $0.runId == resumed.runId })

        #expect(previousRun.endedAt == 210)
        #expect(previousRun.restoreAuthority == false)
        #expect(resumedRun.parentRunId == previous.runId)
        #expect(resumedRun.relationship == .resumed)
    }

    @Test func processStateRequiresMatchingLiveProcessGeneration() throws {
        let pid = Int(getpid())
        let lineage = AgentHookSessionLineageResolver().resolve(
            agentName: "codex",
            sessionId: "live-session",
            pid: pid,
            environment: [:]
        )
        let processStartedAt = try #require(lineage.processStartedAt)
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "live-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "startedAt": now - 10,
            "updatedAt": now,
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)
        let liveRun = AgentSessionRunRecord(
            runId: lineage.runId,
            pid: pid,
            processStartedAt: processStartedAt,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: now - 10,
            updatedAt: now,
            endedAt: nil
        )
        var staleRun = liveRun
        staleRun.processStartedAt = processStartedAt - 1

        #expect(AgentSessionStateProjection(record: record, run: liveRun).process == .alive)
        #expect(AgentSessionStateProjection(record: record, run: staleRun).process == .exited)
    }

    @Test func exitedProcessCannotRemainEffectivelyWorking() throws {
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "stale-working-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "runtimeStatus": "running",
            "startedAt": now - 10,
            "updatedAt": now,
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)
        let staleRun = AgentSessionRunRecord(
            runId: "stale-working-run",
            pid: Int(getpid()),
            processStartedAt: 0,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: now - 10,
            updatedAt: now,
            endedAt: nil
        )

        let projection = AgentSessionStateProjection(record: record, run: staleRun)

        #expect(projection.process == .exited)
        #expect(projection.effective == .ended)
    }

    @Test func hibernatedAndRestoringSessionsOutrankAnExitedProcessObservation() throws {
        let now = Date().timeIntervalSince1970
        let staleRun = AgentSessionRunRecord(
            runId: "hibernated-run",
            pid: Int(getpid()),
            processStartedAt: 0,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: now - 10,
            updatedAt: now,
            endedAt: nil
        )

        for (storedState, expectedState) in [
            ("hibernated", AgentEffectiveState.hibernated),
            ("restoring", AgentEffectiveState.restoring),
        ] {
            let recordData = try JSONSerialization.data(withJSONObject: [
                "sessionId": "lifecycle-session",
                "workspaceId": "workspace-a",
                "surfaceId": "surface-a",
                "sessionState": storedState,
                "runtimeStatus": "running",
                "startedAt": now - 10,
                "updatedAt": now,
            ])
            let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)
            let projection = AgentSessionStateProjection(record: record, run: staleRun)

            #expect(projection.process == .exited)
            #expect(projection.effective == expectedState)
        }
    }

    @Test func missingActivityEvidenceRemainsUnknown() throws {
        let now = Date().timeIntervalSince1970
        let recordData = try JSONSerialization.data(withJSONObject: [
            "sessionId": "legacy-session",
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "startedAt": now - 10,
            "updatedAt": now,
        ])
        let record = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: recordData)
        let run = AgentSessionRunRecord(
            runId: "legacy-run",
            pid: nil,
            processStartedAt: nil,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: now - 10,
            updatedAt: now,
            endedAt: nil
        )

        let projection = AgentSessionStateProjection(record: record, run: run)

        #expect(projection.activity.state == .unknown)
        #expect(!projection.activity.busy)
        #expect(projection.effective == .unknown)
    }

    @Test func queuedRootExitCannotCompleteNewerRecordGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-completion-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "replacement-session": [
                    "sessionId": "replacement-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "activeRunId": "replacement-run",
                    "restoreAuthority": true,
                    "sessionState": "active",
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                    "runs": [[
                        "runId": "replacement-run",
                        "restoreAuthority": true,
                        "startedAt": 200.0,
                        "updatedAt": 200.0,
                    ]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        )

        writer.completeSynchronously(
            kind: .codex,
            sessionId: "replacement-session",
            expectedRecordUpdatedAt: 150,
            now: 210
        )

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["replacement-session"] as? [String: Any])
        #expect(record["completedAt"] == nil)
        #expect(record["sessionState"] as? String == "active")
        #expect(record["activeRunId"] as? String == "replacement-run")
        #expect(record["restoreAuthority"] as? Bool == true)
    }

    @Test func queuedRootExitCannotDeleteNewerActiveSlot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-completion-slot-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "resumed-session"
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "activeRunId": "old-run",
            "restoreAuthority": true,
            "startedAt": 50.0,
            "updatedAt": 100.0,
        ]
        let active: [String: Any] = [
            "sessionId": sessionID,
            "updatedAt": 300.0,
        ]
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(
            provider: "codex",
            records: [CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 100,
                json: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            )],
            activeSlots: [CmuxAgentSessionRegistry.ActiveSlot(
                provider: "codex",
                scope: .surface,
                scopeID: "surface-a",
                sessionID: sessionID,
                updatedAt: 300,
                json: try JSONSerialization.data(withJSONObject: active, options: [.sortedKeys])
            )]
        )
        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            ]
        )

        writer.completeSynchronously(
            kind: .codex,
            sessionId: sessionID,
            expectedRecordUpdatedAt: 100,
            now: 200
        )

        let snapshot = try registry.snapshot(provider: "codex")
        let slot = try #require(snapshot.activeSlots.first)
        #expect(slot.sessionID == sessionID)
        #expect(slot.updatedAt == 300)
    }

    @Test func workloadHistoryAppliesHardCapWhenEveryRecordIsActive() {
        let incoming = (0..<300).map { index in
            AgentWorkloadRecord(
                id: "monitor-\(index)",
                kind: .monitor,
                phase: .watching,
                keepsSessionBusy: true,
                startedAt: Double(index),
                updatedAt: Double(index),
                endedAt: nil,
                endReason: nil
            )
        }

        let reconciled = AgentSessionWorkloadReconciler().replacingActiveWorkloads(
            [],
            with: incoming,
            now: 300
        )

        #expect(reconciled.count == 256)
        #expect(reconciled.allSatisfy { $0.phase.isActive })
        #expect(reconciled.map(\.id).contains("monitor-299"))
    }

    @Test func childRunCannotGainRestoreAuthorityWhenAncestorEvidenceDisappears() throws {
        let existing = AgentSessionRunRecord(
            runId: "stable-child-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: "root-run",
            parentSessionId: "root-session",
            relationship: .spawned,
            restoreAuthority: false,
            startedAt: 100,
            updatedAt: 110,
            endedAt: nil
        )
        let missingEvidence = AgentHookSessionLineage(
            runId: "stable-child-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [existing],
            activeRunId: existing.runId,
            lineage: missingEvidence,
            now: 120
        )
        let run = try #require(runs.first)

        #expect(run.restoreAuthority == false)
        #expect(run.relationship == .spawned)
        #expect(run.parentRunId == "root-run")
        #expect(run.parentSessionId == "root-session")
    }

    @Test func childRunCannotGainRestoreAuthorityAfterProcessGenerationChanges() throws {
        let existing = AgentSessionRunRecord(
            runId: "stable-child-run",
            pid: 101,
            processStartedAt: 100,
            parentRunId: "root-run",
            parentSessionId: "root-session",
            relationship: .spawned,
            restoreAuthority: false,
            startedAt: 100,
            updatedAt: 110,
            endedAt: nil
        )
        let replacement = AgentHookSessionLineage(
            runId: "stable-child-run",
            pid: 202,
            processStartedAt: 200,
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true
        )

        let runs = AgentSessionRunReconciler(maximumRecords: 128).reconciling(
            [existing],
            activeRunId: existing.runId,
            lineage: replacement,
            now: 210
        )
        let run = try #require(runs.first)

        #expect(run.processStartedAt == 200)
        #expect(run.relationship == .spawned)
        #expect(run.restoreAuthority == false)
    }

    @Test func agentsTreeReportsMalformedProviderStore() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{not-json".utf8)
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(result.stdout.contains("codex-hook-sessions.json"))
    }
}
