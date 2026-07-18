import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func agentsListTextRendersLifecycleAndIdentityState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-list-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["session-a": [
                "sessionId": "session-a",
                "workspaceId": "workspace-a",
                "surfaceId": "surface-a",
                "runId": "run-a",
                "activeRunId": "run-a",
                "sessionState": "active",
                "foregroundState": "working",
                "attentionState": "none",
                "restoreAuthority": true,
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("opencode-hook-sessions.json"),
            options: .atomic
        )

        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: [
                "agents", "list", "--agent", "opencode", "--all", "--state-dir", root.path,
            ],
            environment: isolatedAgentTreeEnvironment(home: root),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("opencode session-a"))
        #expect(result.stdout.contains("state=working"))
        #expect(result.stdout.contains("activity=busy"))
        #expect(result.stdout.contains("identity=hook_session"))
        #expect(result.stdout.contains("state_source=lifecycle"))
        #expect(result.stdout.contains("restore_owner=yes"))
    }

    @Test func terminalObservationJoinsExactProcessGenerationAndUpdatesState() throws {
        let observation = makeTerminalObservation(state: .working, lifecycleAuthoritative: false)
        let node = makeTerminalNodeCandidate(
            sessionID: "codex-session",
            observation: observation,
            effectiveState: .idle
        )

        let merged = AgentTerminalObservationJoiner().merge(
            nodes: [node], observations: [observation], activeSessionBySurface: [:]
        )

        let result = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(result.sessionId == "codex-session")
        #expect(result.effectiveState == .working)
        #expect(result.terminalStateApplied)
        #expect(result.activity.counts.foreground == 1)
    }

    @Test func lifecycleAuthoritativeObservationDoesNotOverrideKnownHookState() throws {
        let observation = makeTerminalObservation(state: .blocked, lifecycleAuthoritative: true)
        let node = makeTerminalNodeCandidate(
            sessionID: "claude-session",
            observation: observation,
            effectiveState: .idle
        )

        let result = try #require(AgentTerminalObservationJoiner().merge(
            nodes: [node], observations: [observation], activeSessionBySurface: [:]
        ).first)

        #expect(result.effectiveState == .idle)
        #expect(!result.terminalStateApplied)
        #expect(result.terminalObservation == observation)
    }

    @Test func activeSurfaceSlotDisambiguatesSessionsSharingOneProcess() throws {
        let observation = makeTerminalObservation(state: .blocked, lifecycleAuthoritative: false)
        let first = makeTerminalNodeCandidate(
            sessionID: "old-session", observation: observation, effectiveState: .idle
        )
        let active = makeTerminalNodeCandidate(
            sessionID: "active-session", observation: observation, effectiveState: .idle
        )
        let surfaceKey = AgentTerminalObservationJoiner.surfaceKey(
            provider: observation.sessionProviderID,
            runtimeID: observation.runtimeID,
            surfaceID: observation.surfaceID.uuidString
        )

        let merged = AgentTerminalObservationJoiner().merge(
            nodes: [first, active],
            observations: [observation],
            activeSessionBySurface: [surfaceKey: "active-session"]
        )

        #expect(merged.first(where: { $0.sessionId == "old-session" })?.effectiveState == .idle)
        #expect(merged.first(where: { $0.sessionId == "active-session" })?.effectiveState == .needsInput)
    }

    @Test func unmatchedObservationBecomesTerminalProcessNodeWithoutInventedSessionID() throws {
        let observation = makeTerminalObservation(state: .idle, lifecycleAuthoritative: false)

        let result = try #require(AgentTerminalObservationJoiner().merge(
            nodes: [], observations: [observation], activeSessionBySurface: [:]
        ).first)

        #expect(result.sessionId == nil)
        #expect(result.identitySource == "terminal_process")
        #expect(result.pid == Int(observation.pid))
        #expect(result.cwd == observation.cwd)
        #expect(result.effectiveState == .idle)
        #expect(!result.restoreAuthority)
    }

    @Test func olderCompatibilityWriterCannotHideCurrentCodexRunFromAgentsTree() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-version-clobber-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let sessionID = "current-codex"
        let richRecord: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "runId": "current-run",
            "activeRunId": "current-run",
            "restoreAuthority": true,
            "foregroundState": "working",
            "startedAt": 100.0,
            "updatedAt": 200.0,
            "runs": [[
                "runId": "current-run",
                "restoreAuthority": true,
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ]
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 200,
                json: try JSONSerialization.data(withJSONObject: richRecord, options: [.sortedKeys])
            ),
        ])

        let oldWriterStore: [String: Any] = [
            "version": 2,
            "sessions": [
                sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "startedAt": 100.0,
                    "updatedAt": 300.0,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: oldWriterStore, options: [.sortedKeys])
            .write(to: stateURL, options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let nodes = try #require(output["nodes"] as? [[String: Any]])
        #expect(nodes.contains {
            $0["session_id"] as? String == sessionID && $0["run_id"] as? String == "current-run"
        })
    }

    @Test func agentsListRejectsPartiallyDecodableRegistrySnapshot() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-partial-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let legacySessionID = "legacy-complete"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [legacySessionID: [
                "sessionId": legacySessionID,
                "workspaceId": "workspace-legacy",
                "surfaceId": "surface-legacy",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)

        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        _ = try registry.snapshotImportingLegacy(
            provider: "codex", legacyURL: stateURL, fileManager: .default
        )
        let registryOnlySessionID = "registry-only"
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex", sessionID: registryOnlySessionID, updatedAt: 400,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": registryOnlySessionID,
                    "workspaceId": "workspace-registry",
                    "surfaceId": "surface-registry",
                    "startedAt": 300.0,
                    "updatedAt": 400.0,
                ], options: [.sortedKeys])
            ),
            CmuxAgentSessionRegistry.Record(
                provider: "codex", sessionID: "malformed", updatedAt: 500,
                json: Data("{}".utf8)
            ),
        ])

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "list", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path, "--codex-home", root.path,
            ],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(output["sessions"] as? [[String: Any]])
        #expect(sessions.contains { $0["session_id"] as? String == legacySessionID })
        #expect(
            !sessions.contains { $0["session_id"] as? String == registryOnlySessionID },
            "One malformed registry record must reject the entire CLI projection instead of returning partial state."
        )
    }

    @Test func kimiHookProviderHasLifecycleRestoreAndHelpParity() throws {
        #expect(AgentHibernationLifecycleStatusKeys.isAllowed("kimi"))

        let kind = try #require(RestorableAgentKind(rawValue: "kimi"))
        #expect(kind.customAgentID == nil)
        #expect(RestorableAgentKind.allCases.contains { $0.rawValue == "kimi" })

        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: ["hooks", "--help"],
            environment: ["CMUX_CLI_SENTRY_DISABLED": "1"],
            timeout: 5
        )
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("kimi"))
        #expect(result.stdout.contains("~/.kimi-code/config.toml"))
    }

    @Test func providerStopAdapterDistinguishesInterruptionsFromCompletion() throws {
        let adapter = AgentStopStateAdapter()
        let kimiInterrupt = ClaudeHookParsedInput(
            rawObject: ["hook_event_name": "Interrupt"],
            object: ["hook_event_name": "Interrupt"],
            rawFallback: nil,
            sessionId: "kimi-session",
            turnId: "kimi-turn",
            cwd: nil,
            transcriptPath: nil
        )
        #expect(adapter.isInterrupted(provider: "kimi", input: kimiInterrupt))

        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-interrupted-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        try #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"codex-turn"}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let codexInterrupt = ClaudeHookParsedInput(
            rawObject: nil,
            object: nil,
            rawFallback: nil,
            sessionId: "codex-session",
            turnId: "codex-turn",
            cwd: nil,
            transcriptPath: transcript.path
        )
        #expect(adapter.isInterrupted(provider: "codex", input: codexInterrupt))

        let normalStop = ClaudeHookParsedInput(
            rawObject: ["hook_event_name": "Stop"],
            object: ["hook_event_name": "Stop"],
            rawFallback: nil,
            sessionId: "session",
            turnId: "turn",
            cwd: nil,
            transcriptPath: nil
        )
        #expect(!adapter.isInterrupted(provider: "claude", input: normalStop))
    }

    @Test func agentsTreeReportsWorkloadsSpawnAndForkRelationshipsWithoutGrantingChildrenRestoreAuthority() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "root-run",
                    "restoreAuthority": true,
                    "foregroundState": "completed",
                    "workloads": [[
                        "id": "monitor-1",
                        "kind": "monitor",
                        "phase": "watching",
                        "keepsSessionBusy": true,
                        "startedAt": 105.0,
                        "updatedAt": 130.0,
                    ]],
                    "startedAt": 100.0,
                    "updatedAt": 130.0,
                ],
                "child-session": [
                    "sessionId": "child-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "child-run",
                    "parentRunId": "root-run",
                    "parentSessionId": "root-session",
                    "relationship": "spawned",
                    "restoreAuthority": false,
                    "startedAt": 110.0,
                    "updatedAt": 120.0,
                ],
                "fork-session": [
                    "sessionId": "fork-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-b",
                    "runId": "fork-run",
                    "parentSessionId": "root-session",
                    "relationship": "forked",
                    "restoreAuthority": true,
                    "startedAt": 115.0,
                    "updatedAt": 125.0,
                ],
                "grandchild-session": [
                    "sessionId": "grandchild-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "grandchild-run",
                    "parentRunId": "child-run",
                    "parentSessionId": "child-session",
                    "relationship": "spawned",
                    "restoreAuthority": false,
                    "startedAt": 118.0,
                    "updatedAt": 121.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(output["schema_version"] as? Int == 2)
        let nodes = try #require(output["nodes"] as? [[String: Any]])
        let edges = try #require(output["edges"] as? [[String: Any]])
        #expect(nodes.count == 4)
        let rootNode = try #require(nodes.first { $0["run_id"] as? String == "root-run" })
        #expect(rootNode["node_id"] as? String == "codex\u{1F}root-session\u{1F}root-run")
        #expect(rootNode["restore_authority"] as? Bool == true)
        #expect(rootNode["effective_state"] as? String == "monitoring")
        let activity = try #require(rootNode["activity"] as? [String: Any])
        #expect(activity["busy"] as? Bool == true)
        #expect(activity["modes"] as? [String] == ["monitoring"])
        let counts = try #require(activity["counts"] as? [String: Any])
        #expect(counts["monitor"] as? Int == 1)
        let subtree = try #require(rootNode["subtree_activity"] as? [String: Any])
        #expect(subtree["total_descendants"] as? Int == 3)
        #expect(subtree["busy_descendants"] as? Int == 0)
        #expect(subtree["restore_owners"] as? Int == 1)
        #expect(nodes.first { $0["run_id"] as? String == "child-run" }?["restore_authority"] as? Bool == false)
        #expect(edges.contains {
            $0["from_run_id"] as? String == "root-run"
                && $0["to_run_id"] as? String == "child-run"
                && $0["relationship"] as? String == "spawned"
        })
        #expect(edges.contains {
            $0["from_session_id"] as? String == "root-session"
                && $0["to_run_id"] as? String == "fork-run"
                && $0["relationship"] as? String == "forked"
        })

        let textTree = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all"],
            environment: environment,
            timeout: 5
        )
        #expect(textTree.status == 0, Comment(rawValue: textTree.stdout))
        #expect(textTree.stdout.contains("└── codex fork-session"))
        let textLines = textTree.stdout.split(separator: "\n").map(String.init)
        #expect(textLines.contains { $0.hasPrefix("├── codex child-session") })
        #expect(textLines.contains { $0.hasPrefix("│   └── codex grandchild-session") })

        let filteredTree = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--surface", "surface-b", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!filteredTree.timedOut, Comment(rawValue: filteredTree.stdout))
        #expect(filteredTree.status == 0, Comment(rawValue: filteredTree.stdout))
        let filteredTreeOutput = try #require(
            JSONSerialization.jsonObject(with: Data(filteredTree.stdout.utf8)) as? [String: Any]
        )
        let filteredTreeNodes = try #require(filteredTreeOutput["nodes"] as? [[String: Any]])
        let filteredTreeEdges = try #require(filteredTreeOutput["edges"] as? [[String: Any]])
        #expect(filteredTreeNodes.compactMap { $0["run_id"] as? String } == ["fork-run"])
        #expect(filteredTreeEdges.isEmpty)

        let monitoring = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--all", "--activity", "busy", "--work-kind", "monitor", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!monitoring.timedOut, Comment(rawValue: monitoring.stdout))
        #expect(monitoring.status == 0, Comment(rawValue: monitoring.stdout))
        let monitoringOutput = try #require(
            JSONSerialization.jsonObject(with: Data(monitoring.stdout.utf8)) as? [String: Any]
        )
        #expect(monitoringOutput["total_matches"] as? Int == 1)
        let monitoringSessions = try #require(monitoringOutput["sessions"] as? [[String: Any]])
        #expect(monitoringSessions.first?["session_id"] as? String == "root-session")
    }

    @Test func agentsTreeHandlesDuplicateRunIdentifiersWithoutCrashing() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-duplicate-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "duplicate-session": [
                    "sessionId": "duplicate-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "startedAt": 100.0,
                    "updatedAt": 120.0,
                    "runs": [
                        [
                            "runId": "duplicate-run",
                            "restoreAuthority": false,
                            "startedAt": 100.0,
                            "updatedAt": 110.0,
                        ],
                        [
                            "runId": "duplicate-run",
                            "restoreAuthority": true,
                            "startedAt": 100.0,
                            "updatedAt": 120.0,
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("duplicate-session"))
    }

    @Test func agentsTreeTextPreservesDepthFirstOrderingAndGuideBytes() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-guides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAgentTreeStore(
            parentIndices: [nil, 0, 1, 0],
            to: root.appendingPathComponent("opencode-hook-sessions.json")
        )

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "tree", "--agent", "opencode", "--all",
                "--state-dir", root.path,
            ],
            environment: isolatedAgentTreeEnvironment(home: root),
            timeout: 5
        )

        let expected = [
            "opencode session-00000 IDLE restore-owner workspace:workspace-00000 surface:surface-00000",
            "├── opencode session-00001 IDLE child workspace:workspace-00001 surface:surface-00001",
            "│   └── opencode session-00002 IDLE child workspace:workspace-00002 surface:surface-00002",
            "└── opencode session-00003 IDLE child workspace:workspace-00003 surface:surface-00003",
            "",
        ].joined(separator: "\n")
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        #expect(result.stdout == expected, Comment(rawValue: result.stdout))
    }

    @Test func agentsTreeTextExposesAnIncrementalLineSequence() throws {
        func node(sessionID: String, runID: String, updatedAt: TimeInterval) -> AgentSessionGraphNode {
            AgentSessionGraphNode(
                provider: "opencode", sessionId: sessionID, runId: runID,
                pid: nil, processStartedAt: nil, cmuxRuntime: nil,
                workspaceId: "workspace-\(sessionID)", surfaceId: "surface-\(sessionID)",
                processState: .unknown, sessionState: .active,
                foregroundState: .idle, attentionState: .none,
                activity: AgentActivitySnapshot(state: .idle, busy: false, modes: [], counts: .init()),
                effectiveState: .idle, workloads: [], restoreAuthority: true,
                startedAt: 100, updatedAt: updatedAt, endedAt: nil
            )
        }

        let root = node(sessionID: "root", runID: "root-run", updatedAt: 100)
        let child = node(sessionID: "child", runID: "child-run", updatedAt: 101)
        let edge = AgentSessionGraphEdge(
            fromRunId: root.runId, fromSessionId: root.sessionId,
            toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
        )
        var iterator = AgentTreeTextLineSequence(
            snapshot: AgentSessionGraphSnapshot(nodes: [root, child], edges: [edge]),
            maximumDepth: 64
        ).makeIterator()

        #expect(iterator.next() == "opencode root IDLE restore-owner workspace:workspace-root surface:surface-root")
        #expect(iterator.next() == "└── opencode child IDLE restore-owner workspace:workspace-child surface:surface-child")
        #expect(iterator.next() == nil)
    }

    @Test func agentsTreeDepthLimitDoesNotReemitDescendantsAsRoots() throws {
        func node(sessionID: String, runID: String) -> AgentSessionGraphNode {
            AgentSessionGraphNode(
                provider: "opencode", sessionId: sessionID, runId: runID,
                pid: nil, processStartedAt: nil, cmuxRuntime: nil,
                workspaceId: "workspace-\(sessionID)", surfaceId: "surface-\(sessionID)",
                processState: .unknown, sessionState: .active,
                foregroundState: .idle, attentionState: .none,
                activity: AgentActivitySnapshot(state: .idle, busy: false, modes: [], counts: .init()),
                effectiveState: .idle, workloads: [], restoreAuthority: true,
                startedAt: 100, updatedAt: 100, endedAt: nil
            )
        }

        let root = node(sessionID: "root", runID: "root-run")
        let child = node(sessionID: "child", runID: "child-run")
        let grandchild = node(sessionID: "grandchild", runID: "grandchild-run")
        let snapshot = AgentSessionGraphSnapshot(
            nodes: [root, child, grandchild],
            edges: [
                AgentSessionGraphEdge(
                    fromRunId: root.runId, fromSessionId: root.sessionId,
                    toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
                ),
                AgentSessionGraphEdge(
                    fromRunId: child.runId, fromSessionId: child.sessionId,
                    toNodeId: grandchild.nodeId, toRunId: grandchild.runId, relationship: .spawned
                ),
            ]
        )
        var iterator = AgentTreeTextLineSequence(snapshot: snapshot, maximumDepth: 1).makeIterator()

        #expect(iterator.next()?.contains("opencode root ") == true)
        #expect(iterator.next()?.contains("opencode child ") == true)
        #expect(iterator.next() == nil)
    }

    @Test func limitedAgentListRetainsOnlyTheExactSortedPrefix() {
        var entries = SessionListEntryAccumulator(limit: 2)
        entries.insert(updatedAt: 10, payload: ["session_id": "session-a"])
        entries.insert(updatedAt: 30, payload: ["session_id": "session-b"])
        entries.insert(updatedAt: 20, payload: ["session_id": "session-c"])
        entries.insert(updatedAt: 30, payload: ["session_id": "session-d"])

        #expect(entries.totalCount == 4)
        #expect(entries.retainedCount == 2)
        #expect(entries.sortedPayloads.compactMap { $0["session_id"] as? String } == [
            "session-b", "session-d",
        ])
    }

    @Test func limitedAgentListTieSelectionIsIndependentOfInsertionOrder() {
        let payloads: [[String: Any]] = [
            [
                "session_id": NSNull(), "agent": "codex", "run_id": "run-b",
                "workspace_id": "workspace-b", "surface_id": "surface-b", "pid": 3,
                "process_started_at": 30.0,
            ],
            [
                "session_id": NSNull(), "agent": "claude", "run_id": "run-z",
                "workspace_id": "workspace-z", "surface_id": "surface-z", "pid": 2,
                "process_started_at": 20.0,
            ],
            [
                "session_id": NSNull(), "agent": "codex", "run_id": "run-a",
                "workspace_id": "workspace-a", "surface_id": "surface-a", "pid": 1,
                "process_started_at": 10.0,
            ],
        ]
        let insertionOrders = [
            [0, 1, 2], [0, 2, 1], [1, 0, 2],
            [1, 2, 0], [2, 0, 1], [2, 1, 0],
        ]

        for order in insertionOrders {
            var entries = SessionListEntryAccumulator(limit: 2)
            for index in order {
                entries.insert(updatedAt: 100, payload: payloads[index])
            }
            #expect(entries.sortedPayloads.compactMap { $0["run_id"] as? String } == [
                "run-z", "run-a",
            ])
        }
    }

    @Test func limitedAgentListTextAndJSONPreserveCountLimitAndOrdering() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-list-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAgentTreeStore(
            parentIndices: [nil, nil, nil, nil],
            to: root.appendingPathComponent("opencode-hook-sessions.json")
        )
        let baseArguments = [
            "agents", "list", "--agent", "opencode", "--limit", "2",
            "--state-dir", root.path,
        ]
        let environment = isolatedAgentTreeEnvironment(home: root)

        let text = runProcess(
            executablePath: cliPath,
            arguments: baseArguments,
            environment: environment,
            timeout: 5
        )
        let lines = text.stdout.split(separator: "\n").map(String.init)
        #expect(text.status == 0, Comment(rawValue: text.stdout))
        #expect(lines.count == 3)
        #expect(lines[0].contains("opencode session-00003 "))
        #expect(lines[1].contains("opencode session-00002 "))
        #expect(lines[2] == "... 2 more. Pass --all or --limit <n>.")

        let json = runProcess(
            executablePath: cliPath,
            arguments: baseArguments + ["--json"],
            environment: environment,
            timeout: 5
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(json.status == 0, Comment(rawValue: json.stdout))
        #expect(object["total_matches"] as? Int == 4)
        #expect(object["limit"] as? Int == 2)
        #expect(sessions.compactMap { $0["session_id"] as? String } == [
            "session-00003", "session-00002",
        ])
    }

    @Test func agentsTreeTextDoesNotOverflowTheStackBeyondTwoThousandFiveHundredLevels() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-deep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAgentTreeStore(
            parentIndices: (0..<3_000).map { $0 == 0 ? nil : $0 - 1 },
            to: root.appendingPathComponent("opencode-hook-sessions.json")
        )

        let command = [
            "exec",
            shellQuoteAgentTreeArgument(cliPath),
            "agents tree --agent opencode --all --depth 3000",
            "--state-dir \(shellQuoteAgentTreeArgument(root.path))",
            "> /dev/null",
        ].joined(separator: " ")
        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            environment: isolatedAgentTreeEnvironment(home: root),
            timeout: 30
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
    }

    @Test func sessionOnlyGraphParentsStayWithinTheChildProvider() {
        func node(provider: String, sessionID: String, runID: String, updatedAt: TimeInterval) -> AgentSessionGraphNode {
            AgentSessionGraphNode(
                provider: provider, sessionId: sessionID, runId: runID,
                pid: nil, processStartedAt: nil, cmuxRuntime: nil,
                workspaceId: "workspace", surfaceId: "surface-\(provider)-\(runID)",
                processState: .unknown, sessionState: .active,
                foregroundState: .idle, attentionState: .none,
                activity: AgentActivitySnapshot(state: .idle, busy: false, modes: [], counts: .init()),
                effectiveState: .idle, workloads: [], restoreAuthority: true,
                startedAt: 100, updatedAt: updatedAt, endedAt: nil
            )
        }
        let codexParent = node(provider: "codex", sessionID: "shared-session", runID: "codex-parent", updatedAt: 200)
        let claudeParent = node(provider: "claude", sessionID: "shared-session", runID: "claude-parent", updatedAt: 300)
        let child = node(provider: "codex", sessionID: "child", runID: "child-run", updatedAt: 400)
        let edge = AgentSessionGraphEdge(
            fromRunId: nil, fromSessionId: "shared-session",
            toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
        )

        #expect(
            AgentSessionGraphEdgeResolver(nodes: [codexParent, claudeParent, child]).parentNodeId(for: edge)
                == codexParent.nodeId
        )
    }

    @Test func runOnlyGraphParentsStayWithinTheChildProvider() {
        func node(provider: String, sessionID: String, runID: String, updatedAt: TimeInterval) -> AgentSessionGraphNode {
            AgentSessionGraphNode(
                provider: provider, sessionId: sessionID, runId: runID,
                pid: nil, processStartedAt: nil, cmuxRuntime: nil,
                workspaceId: "workspace", surfaceId: "surface-\(provider)-\(sessionID)",
                processState: .unknown, sessionState: .active,
                foregroundState: .idle, attentionState: .none,
                activity: AgentActivitySnapshot(state: .idle, busy: false, modes: [], counts: .init()),
                effectiveState: .idle, workloads: [], restoreAuthority: true,
                startedAt: 100, updatedAt: updatedAt, endedAt: nil
            )
        }
        let codexParent = node(provider: "codex", sessionID: "codex-parent", runID: "shared-run", updatedAt: 200)
        let claudeParent = node(provider: "claude", sessionID: "claude-parent", runID: "shared-run", updatedAt: 300)
        let child = node(provider: "codex", sessionID: "child", runID: "child-run", updatedAt: 400)
        let edge = AgentSessionGraphEdge(
            fromRunId: "shared-run", fromSessionId: nil,
            toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
        )

        #expect(
            AgentSessionGraphEdgeResolver(nodes: [codexParent, claudeParent, child]).parentNodeId(for: edge)
                == codexParent.nodeId
        )
    }

    @Test func explicitEndedFiltersBypassDefaultHistorySuppression() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-ended-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": ["ended-session": [
                "sessionId": "ended-session",
                "workspaceId": "workspace",
                "surfaceId": "surface",
                "sessionState": "ended",
                "foregroundState": "completed",
                "workloads": [[
                    "id": "stale-monitor",
                    "kind": "monitor",
                    "phase": "watching",
                    "keepsSessionBusy": true,
                    "startedAt": 100.0,
                    "updatedAt": 150.0,
                ]],
                "completedAt": 200.0,
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(
            to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        for arguments in [
            ["agents", "list", "--state", "ended", "--json"],
            ["agents", "tree", "--session", "ended-session", "--json"],
        ] {
            let result = runProcess(
                executablePath: cliPath, arguments: arguments,
                environment: environment, timeout: 5
            )
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let matches = (payload["sessions"] as? [Any]) ?? (payload["nodes"] as? [Any]) ?? []
            #expect(matches.count == 1)
            if arguments[1] == "list",
               let session = (payload["sessions"] as? [[String: Any]])?.first {
                #expect((session["workloads"] as? [Any])?.isEmpty == true)
            }
        }
    }

    @Test func rootExitCancelsEveryOwnedWorkloadAndRetainsHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-root-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        let now = Date().timeIntervalSince1970
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "root-run",
                    "activeRunId": "root-run",
                    "restoreAuthority": true,
                    "foregroundState": "interrupted",
                    "startedAt": now - 10,
                    "updatedAt": now,
                    "runs": [
                        [
                            "runId": "orphan-open-run",
                            "restoreAuthority": true,
                            "startedAt": now - 10,
                            "updatedAt": now - 5,
                        ],
                        [
                            "runId": "root-run",
                            "restoreAuthority": true,
                            "startedAt": now - 5,
                            "updatedAt": now,
                        ],
                    ],
                    "workloads": [
                        [
                            "id": "terminal-1",
                            "kind": "background_terminal",
                            "phase": "running",
                            "keepsSessionBusy": true,
                            "startedAt": now - 9,
                            "updatedAt": now,
                        ],
                        [
                            "id": "monitor-1",
                            "kind": "monitor",
                            "phase": "watching",
                            "keepsSessionBusy": true,
                            "startedAt": now - 8,
                            "updatedAt": now,
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)

        let writer = AgentHookSessionStateWriter(
            homeDirectory: root.path,
            environment: ["CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path]
        )
        writer.completeSynchronously(kind: .claude, sessionId: "root-session", now: now + 1)
        writer.completeSynchronously(kind: .claude, sessionId: "root-session", now: now + 2)

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try #require(saved["sessions"] as? [String: Any])
        let record = try #require(sessions["root-session"] as? [String: Any])
        #expect(record["completedAt"] as? Double != nil)
        #expect(record["restoreAuthority"] as? Bool == false)
        #expect(record["foregroundState"] as? String == "interrupted")
        #expect(record["activeRunId"] == nil)
        let runs = try #require(record["runs"] as? [[String: Any]])
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0["restoreAuthority"] as? Bool == false })
        #expect(runs.allSatisfy { $0["endedAt"] as? Double != nil })
        let workloads = try #require(record["workloads"] as? [[String: Any]])
        #expect(workloads.count == 2)
        #expect(workloads.allSatisfy { $0["phase"] as? String == "cancelled" })
        #expect(workloads.allSatisfy { $0["endReason"] as? String == "root_exited" })
        #expect(workloads.allSatisfy { $0["endedAt"] as? Double != nil })
    }

    @Test func agentsTreeScansTenThousandSavedSessionsWithinTheCLITimeout() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var sessions: [String: Any] = [:]
        sessions.reserveCapacity(10_000)
        for index in 0..<10_000 {
            let id = "session-\(index)"
            sessions[id] = [
                "sessionId": id,
                "workspaceId": "workspace-\(index % 100)",
                "surfaceId": "surface-\(index)",
                "runId": "run-\(index)",
                "foregroundState": "completed",
                "restoreAuthority": true,
                "startedAt": Double(index),
                "updatedAt": Double(index),
            ]
        }
        try JSONSerialization.data(
            withJSONObject: ["version": 2, "sessions": sessions],
            options: []
        ).write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--state", "monitoring", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, "The graph reader must stay bounded at the 10,000-record retention limit")
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect((output["nodes"] as? [Any])?.isEmpty == true)
    }

    @Test func agentsTreeRejectsUnknownAgentLikeAgentsList() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-unknown-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "tree", "--agent", "definitely-not-an-agent",
                "--state-dir", root.path, "--json",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(result.status != 0)
        #expect((result.stdout + result.stderr).contains("unknown agent 'definitely-not-an-agent'"))
    }

    @Test func agentsTreeRejectsBlankAgentFilter() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--agent", "", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status != 0)
        #expect((result.stdout + result.stderr).contains("--agent requires a value"))
    }

}

private func writeAgentTreeStore(parentIndices: [Int?], to url: URL) throws {
    var sessions: [String: Any] = [:]
    sessions.reserveCapacity(parentIndices.count)
    for (index, parentIndex) in parentIndices.enumerated() {
        let sessionID = String(format: "session-%05d", index)
        let runID = String(format: "run-%05d", index)
        var run: [String: Any] = [
            "runId": runID,
            "restoreAuthority": parentIndex == nil,
            "startedAt": Double(index),
            "updatedAt": Double(index),
        ]
        var record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": String(format: "workspace-%05d", index),
            "surfaceId": String(format: "surface-%05d", index),
            "runId": runID,
            "activeRunId": runID,
            "restoreAuthority": parentIndex == nil,
            "foregroundState": "idle",
            "attentionState": "none",
            "sessionState": "active",
            "startedAt": Double(index),
            "updatedAt": Double(index),
        ]
        if let parentIndex {
            let parentSessionID = String(format: "session-%05d", parentIndex)
            let parentRunID = String(format: "run-%05d", parentIndex)
            run["parentRunId"] = parentRunID
            run["parentSessionId"] = parentSessionID
            run["relationship"] = "spawned"
            record["parentRunId"] = parentRunID
            record["parentSessionId"] = parentSessionID
            record["relationship"] = "spawned"
        }
        record["runs"] = [run]
        sessions[sessionID] = record
    }
    try JSONSerialization.data(
        withJSONObject: ["version": 2, "sessions": sessions],
        options: [.sortedKeys]
    ).write(to: url, options: .atomic)
}

private func isolatedAgentTreeEnvironment(home: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
        environment.removeValue(forKey: key)
    }
    environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
    environment["HOME"] = home.path
    return environment
}

private func shellQuoteAgentTreeArgument(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private func makeTerminalObservation(
    state: CmuxAgentObservedState,
    lifecycleAuthoritative: Bool
) -> CmuxAgentTerminalObservation {
    CmuxAgentTerminalObservation(
        runtimeID: "runtime-test",
        workspaceID: UUID(),
        surfaceID: UUID(),
        surfaceGeneration: 9,
        revision: 4,
        familyID: "codex",
        sessionProviderID: lifecycleAuthoritative ? "claude" : "codex",
        lifecycleAuthoritative: lifecycleAuthoritative,
        state: state,
        pid: 42,
        processStartSeconds: 100,
        processStartMicroseconds: 123,
        cwd: "/tmp/project",
        publishedAt: 200
    )
}

private func makeTerminalNodeCandidate(
    sessionID: String,
    observation: CmuxAgentTerminalObservation,
    effectiveState: AgentEffectiveState
) -> AgentSessionGraphNode {
    AgentSessionGraphNode(
        provider: observation.sessionProviderID,
        sessionId: sessionID,
        runId: "run-\(sessionID)",
        pid: Int(observation.pid),
        processStartedAt: TimeInterval(observation.processStartSeconds)
            + TimeInterval(observation.processStartMicroseconds) / 1_000_000,
        cmuxRuntime: AgentCmuxRuntimeIdentity(
            id: observation.runtimeID, socketPath: nil, bundleIdentifier: nil
        ),
        workspaceId: observation.workspaceID.uuidString,
        surfaceId: observation.surfaceID.uuidString,
        processState: .alive,
        sessionState: .active,
        foregroundState: .idle,
        attentionState: .none,
        activity: AgentActivitySnapshot(state: .idle, busy: false, modes: [], counts: .init()),
        effectiveState: effectiveState,
        workloads: [],
        restoreAuthority: true,
        startedAt: 100,
        updatedAt: 150,
        endedAt: nil
    )
}
