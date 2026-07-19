import CmuxFoundation
import Foundation
import SQLite3
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func legacyDefaultListAndTreeUseRunRestoreAuthority() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-run-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func session(
            id: String,
            recordAuthority: Bool,
            runAuthority: Bool,
            updatedAt: TimeInterval
        ) -> [String: Any] {
            [
                "sessionId": id,
                "workspaceId": "workspace-\(id)",
                "surfaceId": "surface-\(id)",
                "isRestorable": true,
                "runId": "run-\(id)",
                "activeRunId": "run-\(id)",
                "restoreAuthority": recordAuthority,
                "sessionState": "active",
                "startedAt": updatedAt - 1,
                "updatedAt": updatedAt,
                "runs": [[
                    "runId": "run-\(id)",
                    "restoreAuthority": runAuthority,
                    "startedAt": updatedAt - 1,
                    "updatedAt": updatedAt,
                ]],
            ]
        }
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "record-only-owner": session(
                    id: "record-only-owner",
                    recordAuthority: true,
                    runAuthority: false,
                    updatedAt: 100
                ),
                "run-owner": session(
                    id: "run-owner",
                    recordAuthority: false,
                    runAuthority: true,
                    updatedAt: 200
                ),
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("opencode-hook-sessions.json"), options: .atomic)
        var environment = isolatedAgentTreeEnvironment(home: root)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        for arguments in [
            ["agents", "list", "--agent", "opencode", "--json"],
            ["agents", "tree", "--agent", "opencode", "--json"],
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut)
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let rows = (payload["sessions"] as? [[String: Any]])
                ?? (payload["nodes"] as? [[String: Any]])
                ?? []
            #expect(rows.map { $0["session_id"] as? String } == ["run-owner"])
        }
    }

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

    @Test func exactSessionProcessCohortRejectsPIDReuseAndPreservesLegacyFallback() throws {
        func record(processStartedAt: TimeInterval?) throws -> ClaudeHookSessionRecord {
            var run: [String: Any] = [
                "runId": "run-a",
                "pid": 123,
                "cmuxRuntime": ["id": "runtime-a"],
                "restoreAuthority": true,
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
            if let processStartedAt { run["processStartedAt"] = processStartedAt }
            let data = try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "sessions": [
                    "session-a": [
                        "sessionId": "session-a",
                        "workspaceId": "workspace-a",
                        "surfaceId": "surface-a",
                        "cmuxRuntime": ["id": "runtime-a"],
                        "runs": [run],
                        "startedAt": 100.0,
                        "updatedAt": 200.0,
                    ],
                ],
            ], options: [.sortedKeys])
            return try #require(
                JSONDecoder().decode(ClaudeHookSessionStoreFile.self, from: data)
                    .sessions["session-a"]
            )
        }

        let target = try record(processStartedAt: 1_000)
        let sameGeneration = try record(processStartedAt: 1_000.0004)
        let reusedPID = try record(processStartedAt: 2_000)
        let legacy = try record(processStartedAt: nil)
        var exactMatcher = AgentSessionProcessCohortMatcher()
        exactMatcher.insert(provider: "codex", record: target, run: try #require(target.runs?.first))

        #expect(exactMatcher.matches(
            provider: "codex", record: sameGeneration, run: try #require(sameGeneration.runs?.first)
        ))
        #expect(!exactMatcher.matches(
            provider: "codex", record: reusedPID, run: try #require(reusedPID.runs?.first)
        ))
        #expect(exactMatcher.matches(
            provider: "codex", record: legacy, run: try #require(legacy.runs?.first)
        ))

        var legacyMatcher = AgentSessionProcessCohortMatcher()
        legacyMatcher.insert(provider: "codex", record: legacy, run: try #require(legacy.runs?.first))
        #expect(legacyMatcher.matches(
            provider: "codex", record: reusedPID, run: try #require(reusedPID.runs?.first)
        ))
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

    @Test func duplicateTerminalObservationsUseNewestPublishedStateOnce() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let stale = makeTerminalObservation(
            state: .idle,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            revision: 99,
            publishedAt: 100
        )
        let newest = makeTerminalObservation(
            state: .blocked,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            revision: 1,
            publishedAt: 200
        )

        for observations in [[stale, newest], [newest, stale]] {
            let merged = AgentTerminalObservationJoiner().merge(
                nodes: [], observations: observations, activeSessionBySurface: [:]
            )

            #expect(merged.count == 1)
            #expect(merged.first?.effectiveState == .needsInput)
            #expect(merged.first?.terminalObservation?.publishedAt == 200)
        }
    }

    @Test func terminalObservationCanonicalizationUsesRevisionAsPublishedAtTieBreak() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let lowerRevision = makeTerminalObservation(
            state: .idle,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            revision: 4,
            publishedAt: 200
        )
        let higherRevision = makeTerminalObservation(
            state: .working,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            revision: 5,
            publishedAt: 200
        )

        for observations in [[lowerRevision, higherRevision], [higherRevision, lowerRevision]] {
            let canonical = AgentTerminalObservationJoiner().merge(
                nodes: [], observations: observations, activeSessionBySurface: [:]
            )

            #expect(canonical.count == 1)
            #expect(canonical.first?.terminalObservation == higherRevision)
        }
    }

    @Test func terminalObservationCanonicalizationPreservesDistinctProcessGenerations() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let first = makeTerminalObservation(
            state: .idle,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            surfaceGeneration: 9,
            publishedAt: 100
        )
        let second = makeTerminalObservation(
            state: .working,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            surfaceGeneration: 10,
            publishedAt: 200
        )

        #expect(AgentTerminalObservationJoiner().merge(
            nodes: [], observations: [first, second], activeSessionBySurface: [:]
        ).count == 2)
    }

    @Test func terminalObservationCanonicalizationPreservesDistinctKernelProcessLifetimes() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let first = makeTerminalObservation(
            state: .idle,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            publishedAt: 100,
            processStartSeconds: 100
        )
        let reusedPID = makeTerminalObservation(
            state: .working,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            publishedAt: 200,
            processStartSeconds: 101
        )

        #expect(AgentTerminalObservationJoiner().merge(
            nodes: [], observations: [first, reusedPID], activeSessionBySurface: [:]
        ).count == 2)
    }

    @Test func terminalObservationCanonicalizationBreaksExactClockTiesDeterministically() {
        let surfaceID = UUID()
        let lowerWorkspace = makeTerminalObservation(
            state: .working,
            lifecycleAuthoritative: false,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            surfaceID: surfaceID,
            revision: 5,
            publishedAt: 200
        )
        let higherWorkspace = makeTerminalObservation(
            state: .idle,
            lifecycleAuthoritative: false,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            surfaceID: surfaceID,
            revision: 5,
            publishedAt: 200
        )

        for observations in [[lowerWorkspace, higherWorkspace], [higherWorkspace, lowerWorkspace]] {
            let canonical = AgentTerminalObservationJoiner().merge(
                nodes: [], observations: observations, activeSessionBySurface: [:]
            )

            #expect(canonical.count == 1)
            #expect(canonical.first?.terminalObservation == higherWorkspace)
        }
    }

    @Test func terminalObservationCanonicalizationTreatsProviderAsProcessMetadata() {
        let surfaceID = UUID()
        let staleProvider = makeTerminalObservation(
            state: .working,
            lifecycleAuthoritative: false,
            surfaceID: surfaceID,
            revision: 4,
            publishedAt: 100
        )
        let currentProvider = makeTerminalObservation(
            state: .idle,
            lifecycleAuthoritative: false,
            workspaceID: staleProvider.workspaceID,
            surfaceID: surfaceID,
            revision: 5,
            publishedAt: 200,
            sessionProviderID: "claude"
        )

        for observations in [[staleProvider, currentProvider], [currentProvider, staleProvider]] {
            let canonical = AgentTerminalObservationJoiner().merge(
                nodes: [], observations: observations, activeSessionBySurface: [:]
            )

            #expect(canonical.count == 1)
            #expect(canonical.first?.provider == "claude")
            #expect(canonical.first?.terminalObservation == currentProvider)
        }
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

        var environment = isolatedAgentTreeEnvironment(home: root)
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

    @Test func agentsListAndTreeWarnWhenAuthoritativeSnapshotCannotDecode() throws {
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
        let registryPath = root.appendingPathComponent(CmuxAgentSessionRegistry.filename).path
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

        let environment = isolatedAgentTreeEnvironment(home: root)
        let commands: [(arguments: [String], rowsKey: String)] = [
            ([
                "agents", "list", "--agent", "codex", "--all", "--limit", "100", "--json",
                "--state-dir", root.path, "--codex-home", root.path,
            ], "sessions"),
            ([
                "agents", "tree", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path,
            ], "nodes"),
        ]
        for command in commands {
            let result = runProcess(
                executablePath: cliPath,
                arguments: command.arguments,
                environment: environment,
                timeout: 5
            )

            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let output = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let warnings = try #require(output["store_warnings"] as? [[String: Any]])
            #expect(warnings.count == 1)
            #expect(warnings.first?["provider"] as? String == "codex")
            #expect(warnings.first?["path"] as? String == registryPath)
            #expect(warnings.first?["code"] as? String == "authoritative_snapshot_decode_failed")
            #expect(warnings.first?["fallback"] as? String == "legacy")
            let rows = try #require(output[command.rowsKey] as? [[String: Any]])
            #expect(rows.contains { $0["session_id"] as? String == legacySessionID })
            #expect(
                !rows.contains { $0["session_id"] as? String == registryOnlySessionID },
                "One malformed registry record must reject the entire CLI projection instead of returning partial state."
            )
        }

        for (index, arguments) in [
            [
                "agents", "list", "--agent", "codex", "--all", "--limit", "100",
                "--state-dir", root.path, "--codex-home", root.path,
            ],
            [
                "agents", "tree", "--agent", "codex", "--all",
                "--state-dir", root.path,
            ],
        ].enumerated() {
            let stderrURL = root.appendingPathComponent("warning-\(index).txt")
            let command = ([cliPath] + arguments)
                .map(shellQuoteAgentTreeArgument)
                .joined(separator: " ")
            let result = runProcess(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "\(command) 2>\(shellQuoteAgentTreeArgument(stderrURL.path))",
                ],
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            #expect(!result.stdout.contains("authoritative_snapshot_decode_failed"))
            #expect(result.stdout.contains(legacySessionID))
            #expect(!result.stdout.contains(registryOnlySessionID))
            let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
            #expect(stderr.contains("authoritative_snapshot_decode_failed"))
            #expect(stderr.contains("codex"))
            #expect(stderr.contains(registryPath))
        }

        try registry.apply(provider: "opencode", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "opencode", sessionID: "malformed-without-fallback", updatedAt: 600,
                json: Data("{}".utf8)
            ),
        ])
        for arguments in [
            [
                "agents", "list", "--agent", "opencode", "--all", "--limit", "100", "--json",
                "--state-dir", root.path,
            ],
            [
                "agents", "tree", "--agent", "opencode", "--all", "--json",
                "--state-dir", root.path,
            ],
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status != 0, Comment(rawValue: result.stdout))
            #expect(result.stdout.contains("authoritative_snapshot_decode_failed"))
            #expect(result.stdout.contains("opencode"))
            #expect(result.stdout.contains(registryPath))
            #expect(!result.stdout.contains("NSCocoaErrorDomain"))
        }
    }

    @Test func boundedAgentListLegacyFallbackKeepsExactCountsAndGlobalOrder() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-bounded-fallback-counts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codexLegacyURL = root.appendingPathComponent("codex-hook-sessions.json")
        let legacyRows: [(id: String, updatedAt: TimeInterval)] = [
            ("codex-older", 100),
            ("codex-middle", 400),
            ("codex-newest", 600),
        ]
        let legacySessions = Dictionary(uniqueKeysWithValues: legacyRows.map { row in
            (row.id, [
                "sessionId": row.id,
                "workspaceId": "workspace-\(row.id)",
                "surfaceId": "surface-\(row.id)",
                "startedAt": row.updatedAt,
                "updatedAt": row.updatedAt,
            ] as [String: Any])
        })
        try JSONSerialization.data(
            withJSONObject: ["version": 2, "sessions": legacySessions],
            options: [.sortedKeys]
        ).write(to: codexLegacyURL, options: .atomic)

        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        _ = try registry.snapshotImportingLegacy(
            provider: "codex",
            legacyURL: codexLegacyURL,
            fileManager: .default
        )
        try registry.apply(provider: "codex", records: [
            .init(
                provider: "codex",
                sessionID: "codex-malformed",
                updatedAt: 700,
                json: Data("{}".utf8)
            ),
        ])
        try registry.apply(provider: "opencode", records: [
            try agentSessionRegistryRecord(
                provider: "opencode",
                sessionID: "opencode-newest",
                updatedAt: 550
            ),
            try agentSessionRegistryRecord(
                provider: "opencode",
                sessionID: "opencode-older",
                updatedAt: 300
            ),
        ])

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "list", "--all", "--limit", "2", "--json",
                "--state-dir", root.path, "--codex-home", root.path,
            ],
            environment: isolatedAgentTreeEnvironment(home: root),
            timeout: 10
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(output["total_matches"] as? Int == 5)
        let rows = try #require(output["sessions"] as? [[String: Any]])
        #expect(rows.compactMap { $0["session_id"] as? String } == [
            "codex-newest", "opencode-newest",
        ])
        let stores = try #require(output["stores"] as? [[String: Any]])
        let codexStore = try #require(stores.first { $0["agent"] as? String == "codex" })
        #expect(codexStore["exists"] as? Bool == true)
        #expect(codexStore["session_count"] as? Int == 3)
        let opencodeStore = try #require(stores.first { $0["agent"] as? String == "opencode" })
        #expect(opencodeStore["exists"] as? Bool == true)
        #expect(opencodeStore["session_count"] as? Int == 2)
        let warnings = try #require(output["store_warnings"] as? [[String: Any]])
        #expect(warnings.count == 1)
        #expect(warnings.first?["provider"] as? String == "codex")
        #expect(warnings.first?["code"] as? String == "authoritative_snapshot_decode_failed")
        #expect(warnings.first?["fallback"] as? String == "legacy")
    }

    @Test func boundedAgentListPreservesGenericCanonicalReadFailures() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-bounded-generic-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(provider: "codex", records: [
            try agentSessionRegistryRecord(
                provider: "codex",
                sessionID: "canonical-session",
                updatedAt: 100
            ),
        ])
        // Storage preflight does not read this column, while the canonical list
        // query does. This injects a canonical SQLite error after preflight.
        try executeAgentSessionSQLite(
            at: registryURL,
            sql: "ALTER TABLE agent_sessions RENAME COLUMN writer_generation TO missing_writer_generation"
        )

        var caught: (any Error)?
        do {
            _ = try AgentHookSessionRegistryBridge.boundedRecentSnapshotsForList(
                specifications: [(provider: "codex", suffix: "codex")],
                stateDirectory: root.path,
                environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path],
                fileManager: .default,
                maximumRecordsPerProvider: 1
            )
        } catch {
            caught = error
        }

        #expect(caught != nil)
        #expect(
            !(caught is AgentHookSessionStoreLoadFailure),
            "A canonical query failure must not be relabeled as a legacy import failure."
        )
    }

    @Test func agentsListAndTreeFailClosedForMalformedLegacyWithoutRegistryFallback() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-malformed-legacy-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try Data("{ malformed".utf8).write(to: stateURL, options: .atomic)
        let environment = isolatedAgentTreeEnvironment(home: root)

        for arguments in [
            [
                "agents", "list", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path, "--codex-home", root.path,
            ],
            [
                "agents", "tree", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path,
            ],
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status != 0, Comment(rawValue: result.stdout))
            #expect(result.stdout.contains("legacy_source_import_failed"))
            #expect(result.stdout.contains("codex"))
            #expect(result.stdout.contains(stateURL.path))
            #expect(!result.stdout.contains("NSCocoaErrorDomain"))
            #expect(!result.stdout.contains("JSON text did not start"))
        }
    }

    @Test func agentsListAndTreeWarnWhenMalformedLegacyUsesRegistryFallback() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-malformed-legacy-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registrySessionID = "registry-complete"
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: registrySessionID,
                updatedAt: 200,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": registrySessionID,
                    "workspaceId": "workspace-registry",
                    "surfaceId": "surface-registry",
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ], options: [.sortedKeys])
            ),
        ])
        try Data("{ malformed".utf8).write(to: stateURL, options: .atomic)
        let environment = isolatedAgentTreeEnvironment(home: root)

        for command in [
            (arguments: [
                "agents", "list", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path, "--codex-home", root.path,
            ], rowsKey: "sessions"),
            (arguments: [
                "agents", "tree", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path,
            ], rowsKey: "nodes"),
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: command.arguments,
                environment: environment,
                timeout: 5
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let output = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let warnings = try #require(output["store_warnings"] as? [[String: Any]])
            #expect(warnings.count == 1)
            #expect(warnings.first?["provider"] as? String == "codex")
            #expect(warnings.first?["path"] as? String == stateURL.path)
            #expect(warnings.first?["code"] as? String == "legacy_source_import_failed")
            #expect(warnings.first?["fallback"] as? String == "registry")
            let rows = try #require(output[command.rowsKey] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["session_id"] as? String == registrySessionID)
        }
    }

    @Test func agentsListAndTreeFailClosedForLegacySessionIdentityMismatchWithoutRegistryFallback() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-legacy-identity-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "outer-session": [
                    "sessionId": "inner-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let environment = isolatedAgentTreeEnvironment(home: root)

        for arguments in [
            [
                "agents", "list", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path, "--codex-home", root.path,
            ],
            [
                "agents", "tree", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path,
            ],
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 15
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status != 0, Comment(rawValue: result.stdout))
            #expect(result.stdout.contains("legacy_source_import_failed"))
            #expect(result.stdout.contains("codex"))
            #expect(result.stdout.contains(stateURL.path))
            #expect(!result.stdout.contains("outer-session"))
            #expect(!result.stdout.contains("inner-session"))
        }
    }

    @Test func agentsListAndTreeWarnWhenLegacySessionIdentityMismatchUsesRegistryFallback() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-legacy-identity-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registrySessionID = "registry-complete"
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: registrySessionID,
                updatedAt: 200,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": registrySessionID,
                    "workspaceId": "workspace-registry",
                    "surfaceId": "surface-registry",
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ], options: [.sortedKeys])
            ),
        ])
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "outer-session": [
                    "sessionId": "inner-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "startedAt": 300.0,
                    "updatedAt": 400.0,
                ],
            ],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let environment = isolatedAgentTreeEnvironment(home: root)

        for command in [
            (arguments: [
                "agents", "list", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path, "--codex-home", root.path,
            ], rowsKey: "sessions"),
            (arguments: [
                "agents", "tree", "--agent", "codex", "--all", "--json",
                "--state-dir", root.path,
            ], rowsKey: "nodes"),
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: command.arguments,
                environment: environment,
                timeout: 15
            )
            #expect(!result.timedOut, Comment(rawValue: result.stdout))
            #expect(result.status == 0, Comment(rawValue: result.stdout))
            let output = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let warnings = try #require(output["store_warnings"] as? [[String: Any]])
            #expect(warnings.count == 1)
            #expect(warnings.first?["provider"] as? String == "codex")
            #expect(warnings.first?["path"] as? String == stateURL.path)
            #expect(warnings.first?["code"] as? String == "legacy_source_import_failed")
            #expect(warnings.first?["fallback"] as? String == "registry")
            let rows = try #require(output[command.rowsKey] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["session_id"] as? String == registrySessionID)
            #expect(!result.stdout.contains("outer-session"))
            #expect(!result.stdout.contains("inner-session"))
        }
    }

    @Test func authoritativeDecodeDoesNotUseLegacySessionIdentityMismatchAsFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-legacy-identity-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "outer-session": [
                    "sessionId": "inner-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let bridge = AgentHookSessionRegistryBridge(
            provider: "codex",
            statePath: stateURL.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path],
            fileManager: .default
        )
        var loadFailure: AgentHookSessionStoreLoadFailure?
        do {
            _ = try bridge.loadForInspection(snapshot: CmuxAgentSessionRegistry.Snapshot(
                records: [CmuxAgentSessionRegistry.Record(
                    provider: "codex",
                    sessionID: "malformed-registry-record",
                    updatedAt: 300,
                    json: Data("{}".utf8)
                )],
                activeSlots: []
            ))
        } catch let failure as AgentHookSessionStoreLoadFailure {
            loadFailure = failure
        }
        let failure = try #require(loadFailure)
        #expect(failure.provider == "codex")
        #expect(failure.path == root.appendingPathComponent(CmuxAgentSessionRegistry.filename).path)
        #expect(failure.code == .authoritativeSnapshotDecodeFailed)
    }

    @Test func authoritativeDecodeDoesNotUseLegacySlotIdentityMismatchAsFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-legacy-slot-identity-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "session-a": [
                    "sessionId": "session-a",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
            "activeSessionsByWorkspace": [
                "workspace-b": [
                    "sessionId": "session-a",
                    "updatedAt": 200.0,
                ],
            ],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let bridge = AgentHookSessionRegistryBridge(
            provider: "codex",
            statePath: stateURL.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path],
            fileManager: .default
        )
        var loadFailure: AgentHookSessionStoreLoadFailure?
        do {
            _ = try bridge.loadForInspection(snapshot: CmuxAgentSessionRegistry.Snapshot(
                records: [CmuxAgentSessionRegistry.Record(
                    provider: "codex",
                    sessionID: "malformed-registry-record",
                    updatedAt: 300,
                    json: Data("{}".utf8)
                )],
                activeSlots: []
            ))
        } catch let failure as AgentHookSessionStoreLoadFailure {
            loadFailure = failure
        }
        let failure = try #require(loadFailure)
        #expect(failure.provider == "codex")
        #expect(failure.path == root.appendingPathComponent(CmuxAgentSessionRegistry.filename).path)
        #expect(failure.code == .authoritativeSnapshotDecodeFailed)
    }

    @Test func boundedAuthoritativeDecodeValidatesOmittedNestedRecordPayloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-bounded-record-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = "codex"
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        let malformedID = "omitted-malformed"
        let newestID = "newest-valid"
        try registry.apply(provider: provider, records: [
            .init(
                provider: provider,
                sessionID: malformedID,
                updatedAt: 1,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": malformedID,
                    "workspaceId": "old-workspace",
                    "surfaceId": "old-surface",
                    "startedAt": 1.0,
                    "updatedAt": 1.0,
                    "cmuxRuntime": ["id": 42],
                ], options: [.sortedKeys])
            ),
            .init(
                provider: provider,
                sessionID: newestID,
                updatedAt: 2,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": newestID,
                    "workspaceId": "new-workspace",
                    "surfaceId": "new-surface",
                    "startedAt": 2.0,
                    "updatedAt": 2.0,
                ], options: [.sortedKeys])
            ),
        ])
        let bounded = try registry.hookBoundedRecentSnapshot(
            provider: provider,
            maximumRecords: 1
        )
        #expect(bounded.snapshot.records.map(\.sessionID) == [newestID])
        let bridge = AgentHookSessionRegistryBridge(
            provider: provider,
            statePath: root.appendingPathComponent("codex-hook-sessions.json").path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path],
            fileManager: .default
        )
        let snapshots = try AgentHookSessionRegistryBridge.boundedRecentSnapshotsForList(
            specifications: [(provider: provider, suffix: provider)],
            stateDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path],
            fileManager: .default,
            maximumRecordsPerProvider: 1
        )
        #expect(snapshots.boundedValidationFailures == Set([provider]))

        var loadFailure: AgentHookSessionStoreLoadFailure?
        do {
            _ = try bridge.loadBoundedForInspection(
                snapshot: try #require(snapshots.snapshots[provider]),
                authoritativeValidationFailed: true
            )
        } catch let failure as AgentHookSessionStoreLoadFailure {
            loadFailure = failure
        }

        #expect(try #require(loadFailure).code == .authoritativeSnapshotDecodeFailed)
    }

    @Test func boundedAuthoritativeDecodeValidatesOmittedActiveSlotPayloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-bounded-slot-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = "opencode"
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        let olderID = "omitted-slot-owner"
        let newestID = "newest-valid"
        let records = try [
            (olderID, "old-workspace", "old-surface", 1.0),
            (newestID, "new-workspace", "new-surface", 2.0),
        ].map { item in
            let (sessionID, workspaceID, surfaceID, timestamp) = item
            return CmuxAgentSessionRegistry.Record(
                provider: provider,
                sessionID: sessionID,
                updatedAt: timestamp,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": sessionID,
                    "workspaceId": workspaceID,
                    "surfaceId": surfaceID,
                    "startedAt": timestamp,
                    "updatedAt": timestamp,
                ], options: [.sortedKeys])
            )
        }
        let malformedSlot = CmuxAgentSessionRegistry.ActiveSlot(
            provider: provider,
            scope: .surface,
            scopeID: "old-surface",
            sessionID: olderID,
            updatedAt: 1,
            json: try JSONSerialization.data(withJSONObject: [
                "sessionId": olderID,
                "updatedAt": 1.0,
                "allowsNewSessionReplacement": "yes",
            ], options: [.sortedKeys])
        )
        try registry.apply(
            provider: provider,
            records: records,
            activeSlots: [malformedSlot]
        )
        let bounded = try registry.hookBoundedRecentSnapshot(
            provider: provider,
            maximumRecords: 1
        )
        #expect(bounded.snapshot.records.map(\.sessionID) == [newestID])
        #expect(bounded.snapshot.activeSlots.isEmpty)
        let bridge = AgentHookSessionRegistryBridge(
            provider: provider,
            statePath: root.appendingPathComponent("opencode-hook-sessions.json").path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path],
            fileManager: .default
        )
        let snapshots = try AgentHookSessionRegistryBridge.boundedRecentSnapshotsForList(
            specifications: [(provider: provider, suffix: provider)],
            stateDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": root.path],
            fileManager: .default,
            maximumRecordsPerProvider: 1
        )
        #expect(snapshots.boundedValidationFailures == Set([provider]))

        var loadFailure: AgentHookSessionStoreLoadFailure?
        do {
            _ = try bridge.loadBoundedForInspection(
                snapshot: try #require(snapshots.snapshots[provider]),
                authoritativeValidationFailed: true
            )
        } catch let failure as AgentHookSessionStoreLoadFailure {
            loadFailure = failure
        }

        #expect(try #require(loadFailure).code == .authoritativeSnapshotDecodeFailed)
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
        #expect(result.stdout.contains("~/.kimi/config.toml"))
        #expect(!result.stdout.contains("~/.kimi-code/config.toml"))
    }

    @Test func agentInspectionAcceptsProviderExecutableAliasesAndOllama() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-filter-aliases-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = isolatedAgentTreeEnvironment(home: root)
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDirectory.path
        let cliPath = try bundledCLIPath()
        let aliases = [
            "hermes",
            "kiro-cli",
            "qodercli",
            "kimi-cli",
            "kimi-code",
            "ollama",
        ]

        for command in ["list", "tree"] {
            for alias in aliases {
                let result = runProcess(
                    executablePath: cliPath,
                    arguments: [
                        "agents", command,
                        "--agent", alias,
                        "--state-dir", stateDirectory.path,
                        "--all",
                        "--json",
                    ],
                    environment: environment,
                    timeout: 5
                )
                #expect(
                    !result.timedOut,
                    Comment(rawValue: "\(command) --agent \(alias): \(result.stdout)")
                )
                #expect(
                    result.status == 0,
                    Comment(rawValue: "\(command) --agent \(alias): \(result.stdout)")
                )
                let payload = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
                        as? [String: Any]
                )
                #expect(payload["schema_version"] as? Int == 2)
                if command == "list" {
                    #expect((payload["sessions"] as? [[String: Any]])?.isEmpty == true)
                } else {
                    #expect((payload["nodes"] as? [[String: Any]])?.isEmpty == true)
                    #expect((payload["edges"] as? [[String: Any]])?.isEmpty == true)
                }
            }
        }
    }

    @Test func agentInspectionDiscoversConfiguredVaultSidecarsWithoutALiveObservation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-configured-provider-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".config/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = "custom-sidecar"
        try Data("""
        {
          // Offline inspection must use the configured provider catalog.
          "vault": {
            "agents": [{
              "id": "\(provider)",
              "name": "Custom Sidecar",
              "detect": { "processName": "custom-sidecar" },
              "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
              "resumeCommand": "custom-sidecar --session {{sessionId}}",
            }],
          },
        }
        """.utf8).write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            options: .atomic
        )
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: stateDirectory.appendingPathComponent("\(provider)-hook-sessions.json")
        )

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            for filters in [[], ["--agent", provider]] {
                let result = runProcess(
                    executablePath: cliPath,
                    arguments: ["agents", subcommand]
                        + filters
                        + ["--all", "--json", "--state-dir", stateDirectory.path],
                    environment: environment,
                    timeout: 5
                )
                let context = "agents \(subcommand) \(filters.joined(separator: " ")): \(result.stdout)"

                #expect(!result.timedOut, Comment(rawValue: context))
                #expect(result.status == 0, Comment(rawValue: context))
                let payload = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                    Comment(rawValue: context)
                )
                let rows = subcommand == "list"
                    ? try #require(payload["sessions"] as? [[String: Any]])
                    : try #require(payload["nodes"] as? [[String: Any]])
                #expect(rows.contains {
                    ($0["agent"] as? String) == provider || ($0["provider"] as? String) == provider
                }, Comment(rawValue: context))
            }
        }
    }

    @Test func agentInspectionDiscoversRegistryOnlyProvidersWithoutALiveObservation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-registry-provider-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = "custom-sqlite"
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try seedAuthoritativeAgentSessions(count: 1, provider: provider, registry: registry)

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            for filters in [[], ["--agent", provider]] {
                let result = runProcess(
                    executablePath: cliPath,
                    arguments: ["agents", subcommand]
                        + filters
                        + ["--all", "--json", "--state-dir", stateDirectory.path],
                    environment: environment,
                    timeout: 5
                )
                let context = "agents \(subcommand) \(filters.joined(separator: " ")): \(result.stdout)"

                #expect(!result.timedOut, Comment(rawValue: context))
                #expect(result.status == 0, Comment(rawValue: context))
                let payload = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                    Comment(rawValue: context)
                )
                let rows = subcommand == "list"
                    ? try #require(payload["sessions"] as? [[String: Any]])
                    : try #require(payload["nodes"] as? [[String: Any]])
                #expect(rows.contains {
                    ($0["agent"] as? String) == provider || ($0["provider"] as? String) == provider
                }, Comment(rawValue: context))
            }
        }
    }

    @Test func exactCustomProviderIDWinsOverStaticAliasWhileUnclaimedAliasStillWorks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-exact-alias-\(UUID().uuidString)", isDirectory: true)
        let customState = root.appendingPathComponent("custom-state", isDirectory: true)
        let aliasState = root.appendingPathComponent("alias-state", isDirectory: true)
        try FileManager.default.createDirectory(at: customState, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aliasState, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = CmuxAgentSessionRegistry(
            url: customState.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try seedAuthoritativeAgentSessions(count: 1, provider: "cursor-agent", registry: registry)
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: customState.appendingPathComponent("cursor-agent-hook-sessions.json")
        )
        // Keep the aliased built-in sidecar present too, so the selected row
        // proves which provider the exact filter resolved.
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: customState.appendingPathComponent("cursor-hook-sessions.json")
        )
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: aliasState.appendingPathComponent("cursor-hook-sessions.json")
        )

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            for (stateDirectory, expectedProvider) in [
                (customState, "cursor-agent"),
                (aliasState, "cursor"),
            ] {
                let result = runProcess(
                    executablePath: cliPath,
                    arguments: [
                        "agents", subcommand, "--agent", "cursor-agent", "--all", "--json",
                        "--state-dir", stateDirectory.path,
                    ],
                    environment: environment,
                    timeout: 5
                )
                let context = "agents \(subcommand) exact alias in \(stateDirectory.lastPathComponent): \(result.stdout)"
                #expect(!result.timedOut, Comment(rawValue: context))
                #expect(result.status == 0, Comment(rawValue: context))
                let payload = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                    Comment(rawValue: context)
                )
                let rows = subcommand == "list"
                    ? try #require(payload["sessions"] as? [[String: Any]])
                    : try #require(payload["nodes"] as? [[String: Any]])
                #expect(rows.count == 1, Comment(rawValue: context))
                let provider = rows.first?["agent"] as? String
                    ?? rows.first?["provider"] as? String
                #expect(provider == expectedProvider, Comment(rawValue: context))
            }
        }
    }

    @Test func configurableBuiltInProviderUsesNearestConfiguredDisplayNameOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-static-display-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let globalConfigDirectory = root.appendingPathComponent(".config/cmux", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let projectConfigDirectory = projectDirectory.appendingPathComponent(".cmux", isDirectory: true)
        let workingDirectory = projectDirectory.appendingPathComponent("nested", isDirectory: true)
        for directory in [
            stateDirectory,
            globalConfigDirectory,
            projectConfigDirectory,
            workingDirectory,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        func writeConfig(piName: String, codexName: String, to url: URL) throws {
            try JSONSerialization.data(withJSONObject: [
                "vault": [
                    "agents": [
                        [
                            "id": "pi",
                            "name": piName,
                            "sessionIdSource": ["type": "argvOption", "argvOption": "--session"],
                            "resumeCommand": "pi --session {{sessionId}}",
                        ],
                        [
                            "id": "codex",
                            "name": codexName,
                            "sessionIdSource": ["type": "argvOption", "argvOption": "--session"],
                            "resumeCommand": "codex resume {{sessionId}}",
                        ],
                    ],
                ],
            ], options: [.sortedKeys]).write(to: url, options: .atomic)
        }
        try writeConfig(
            piName: "Global Pi",
            codexName: "Fake Global Codex",
            to: globalConfigDirectory.appendingPathComponent("cmux.json")
        )
        try writeConfig(
            piName: "Project Pi",
            codexName: "Fake Project Codex",
            to: projectConfigDirectory.appendingPathComponent("cmux.json")
        )
        for provider in ["pi", "codex"] {
            try writeAgentTreeStore(
                parentIndices: [nil],
                to: stateDirectory.appendingPathComponent("\(provider)-hook-sessions.json")
            )
        }

        var environment = isolatedAgentTreeEnvironment(home: root)
        environment["PWD"] = workingDirectory.path
        let cliPath = try bundledCLIPath()
        for (provider, expectedDisplayName) in [
            ("pi", "Project Pi"),
            ("codex", "Codex"),
        ] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", "list", "--agent", provider, "--all", "--json",
                    "--state-dir", stateDirectory.path,
                ],
                environment: environment,
                timeout: 5
            )
            let context = "agents list --agent \(provider): \(result.stdout)"
            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status == 0, Comment(rawValue: context))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: context)
            )
            let rows = try #require(payload["sessions"] as? [[String: Any]])
            #expect(rows.count == 1, Comment(rawValue: context))
            #expect(
                rows.first?["agent_display_name"] as? String == expectedDisplayName,
                Comment(rawValue: context)
            )
        }
    }

    @Test func exactAgentInspectionSurvivesRegistryProviderEnumerationOverflow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-provider-overflow-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetProvider = "overflow-target"
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try seedAuthoritativeAgentSessions(count: 1, provider: targetProvider, registry: registry)
        try seedAuthoritativeAgentProviders(
            (0..<CmuxAgentSessionRegistry.maximumProviderEnumerationCount).map {
                String(format: "overflow-provider-%03d", $0)
            },
            registry: registry
        )

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            let filtered = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--agent", targetProvider, "--all", "--json",
                    "--state-dir", stateDirectory.path,
                ],
                environment: environment,
                timeout: 5
            )
            let filteredContext = "agents \(subcommand) exact overflow: \(filtered.stdout)"
            #expect(!filtered.timedOut, Comment(rawValue: filteredContext))
            #expect(filtered.status == 0, Comment(rawValue: filteredContext))
            let filteredPayload = try #require(
                JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [String: Any],
                Comment(rawValue: filteredContext)
            )
            let rows = subcommand == "list"
                ? try #require(filteredPayload["sessions"] as? [[String: Any]])
                : try #require(filteredPayload["nodes"] as? [[String: Any]])
            #expect(rows.contains {
                ($0["agent"] as? String) == targetProvider
                    || ($0["provider"] as? String) == targetProvider
            }, Comment(rawValue: filteredContext))

            let unfiltered = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--all", "--json",
                    "--state-dir", stateDirectory.path,
                ],
                environment: environment,
                timeout: 5
            )
            let unfilteredContext = "agents \(subcommand) unfiltered overflow: \(unfiltered.stdout)"
            #expect(!unfiltered.timedOut, Comment(rawValue: unfilteredContext))
            #expect(unfiltered.status != 0, Comment(rawValue: unfilteredContext))
            let unfilteredPayload = try #require(
                JSONSerialization.jsonObject(with: Data(unfiltered.stdout.utf8)) as? [String: Any],
                Comment(rawValue: unfilteredContext)
            )
            let error = try #require(unfilteredPayload["error"] as? [String: Any])
            #expect(error["code"] as? String == "agent_provider_catalog_limit_exceeded")
            #expect(
                error["maximum_count"] as? Int
                    == CmuxAgentSessionRegistry.maximumProviderEnumerationCount
            )
            #expect(
                error["observed_at_least"] as? Int
                    == CmuxAgentSessionRegistry.maximumProviderEnumerationCount + 1
            )
        }
    }

    @Test func caseCollidingConfiguredAndRegistryProvidersFailBeforeSidecarImport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-provider-collision-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".config/cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("""
        {
          "vault": {
            "agents": [{
              "id": "Custom",
              "name": "Configured Custom",
              "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
              "resumeCommand": "custom --session {{sessionId}}"
            }]
          }
        }
        """.utf8).write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            options: .atomic
        )
        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try seedAuthoritativeAgentSessions(count: 1, provider: "custom", registry: registry)
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: stateDirectory.appendingPathComponent("Custom-hook-sessions.json")
        )

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            for filter in [[], ["--agent", "Custom"]] {
                let result = runProcess(
                    executablePath: cliPath,
                    arguments: ["agents", subcommand]
                        + filter
                        + ["--all", "--json", "--state-dir", stateDirectory.path],
                    environment: environment,
                    timeout: 5
                )
                let context = "agents \(subcommand) case collision \(filter): \(result.stdout)"
                #expect(!result.timedOut, Comment(rawValue: context))
                #expect(result.status != 0, Comment(rawValue: context))
                let payload = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                    Comment(rawValue: context)
                )
                let error = try #require(payload["error"] as? [String: Any])
                #expect(error["code"] as? String == "agent_provider_identifier_collision")
                #expect(Set([
                    error["provider"] as? String,
                    error["conflicting_provider"] as? String,
                ].compactMap { $0 }) == Set(["Custom", "custom"]))
            }
        }
    }

    @Test func providerSelectionPreservesCanonicalCaseAndExactSidecarOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-provider-selection-canonical-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let configURL = root.appendingPathComponent(".config/cmux/cmux.json")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: stateDirectory.appendingPathComponent("cursor-agent-hook-sessions.json")
        )
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: stateDirectory.appendingPathComponent("ollama-hook-sessions.json")
        )

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            let exactSidecar = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--agent", "cursor-agent", "--all", "--json",
                    "--state-dir", stateDirectory.path,
                ],
                environment: environment,
                timeout: 5
            )
            let context = "agents \(subcommand) exact cursor-agent sidecar: \(exactSidecar.stdout)"
            #expect(!exactSidecar.timedOut, Comment(rawValue: context))
            #expect(exactSidecar.status == 0, Comment(rawValue: context))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(exactSidecar.stdout.utf8))
                    as? [String: Any],
                Comment(rawValue: context)
            )
            let rows = subcommand == "list"
                ? try #require(payload["sessions"] as? [[String: Any]])
                : try #require(payload["nodes"] as? [[String: Any]])
            #expect(rows.count == 1, Comment(rawValue: context))
            let provider = rows.first?["agent"] as? String
                ?? rows.first?["provider"] as? String
            #expect(provider == "cursor-agent", Comment(rawValue: context))
        }

        try Data("""
        {"vault":{"agents":[{
          "id":"Ollama","name":"Ambiguous Ollama",
          "sessionIdSource":{"type":"argvOption","argvOption":"--session"},
          "resumeCommand":"ollama --session {{sessionId}}"
        }]}}
        """.utf8).write(to: configURL)
        for subcommand in ["list", "tree"] {
            let collision = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--agent", "ollama", "--all", "--json",
                    "--state-dir", stateDirectory.path,
                ],
                environment: environment,
                timeout: 5
            )
            let context = "agents \(subcommand) configured Ollama collision: \(collision.stdout)"
            #expect(!collision.timedOut, Comment(rawValue: context))
            #expect(collision.status != 0, Comment(rawValue: context))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(collision.stdout.utf8))
                    as? [String: Any],
                Comment(rawValue: context)
            )
            let error = try #require(payload["error"] as? [String: Any])
            #expect(error["code"] as? String == "agent_provider_identifier_collision")
        }

        try Data("""
        {"vault":{"agents":[{
          "id":"ollama","name":"Project Ollama",
          "sessionIdSource":{"type":"argvOption","argvOption":"--session"},
          "resumeCommand":"ollama --session {{sessionId}}"
        }]}}
        """.utf8).write(to: configURL)
        let exactOverride = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "list", "--agent", "ollama", "--all", "--json",
                "--state-dir", stateDirectory.path,
            ],
            environment: environment,
            timeout: 5
        )
        let exactOverrideContext = "agents list exact configured ollama: \(exactOverride.stdout)"
        #expect(!exactOverride.timedOut, Comment(rawValue: exactOverrideContext))
        #expect(exactOverride.status == 0, Comment(rawValue: exactOverrideContext))
        let exactOverridePayload = try #require(
            JSONSerialization.jsonObject(with: Data(exactOverride.stdout.utf8))
                as? [String: Any],
            Comment(rawValue: exactOverrideContext)
        )
        let exactOverrideRows = try #require(
            exactOverridePayload["sessions"] as? [[String: Any]]
        )
        #expect(exactOverrideRows.count == 1, Comment(rawValue: exactOverrideContext))
        #expect(exactOverrideRows.first?["agent"] as? String == "ollama")
        #expect(exactOverrideRows.first?["agent_display_name"] as? String == "Project Ollama")
    }

    @Test func uniqueCaseFoldProviderCanonicalizesLiveObservationBeforeDurableJoin() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let liveObservation = makeTerminalObservation(
            state: .working,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionProviderID: "custom"
        )
        let selection = AgentSessionProviderSelection(
            providerID: "Custom",
            exactObservationProviderID: nil,
            caseFoldedObservationProviderID: "Custom"
        )
        #expect(selection.ownedProviderMatch(for: liveObservation) == true)
        let canonicalObservation = selection.canonicalizedObservation(liveObservation)
        #expect(canonicalObservation.sessionProviderID == "Custom")

        let durableObservation = makeTerminalObservation(
            state: .idle,
            lifecycleAuthoritative: false,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionProviderID: "Custom"
        )
        let durableNode = makeTerminalNodeCandidate(
            sessionID: "durable-custom-session",
            observation: durableObservation,
            effectiveState: .idle
        )
        let merged = AgentTerminalObservationJoiner().merge(
            nodes: [durableNode],
            observations: [canonicalObservation],
            activeSessionBySurface: [:]
        )
        let node = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(node.provider == "Custom")
        #expect(node.sessionId == "durable-custom-session")
        #expect(node.effectiveState == .working)
        #expect(node.identitySource == "hook_session")
        #expect(!merged.contains { $0.identitySource == "terminal_process" })

        let literalAliasSelection = AgentSessionProviderSelection(
            providerID: "cursor-agent",
            exactObservationProviderID: "cursor-agent"
        )
        let aliasFamilyObservation = makeTerminalObservation(
            state: .working,
            lifecycleAuthoritative: false,
            sessionProviderID: "CURSOR-AGENT"
        )
        #expect(literalAliasSelection.ownedProviderMatch(for: aliasFamilyObservation) == false)
        #expect(literalAliasSelection.canonicalizedObservation(
            aliasFamilyObservation
        ).sessionProviderID == "CURSOR-AGENT")
    }

    @Test func caseDifferentStaticProviderCollisionsFailWhileExactStaticIDsRemainUsable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-static-provider-collision-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = CmuxAgentSessionRegistry(
            url: stateDirectory.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try seedAuthoritativeAgentSessions(count: 1, provider: "codex", registry: registry)

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            let exactStatic = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--agent", "codex", "--all", "--json",
                    "--state-dir", stateDirectory.path,
                ],
                environment: environment,
                timeout: 5
            )
            let staticContext = "agents \(subcommand) exact static: \(exactStatic.stdout)"
            #expect(!exactStatic.timedOut, Comment(rawValue: staticContext))
            #expect(exactStatic.status == 0, Comment(rawValue: staticContext))
        }

        try seedAuthoritativeAgentSessions(count: 1, provider: "Codex", registry: registry)
        for subcommand in ["list", "tree"] {

            for filter in [[], ["--agent", "codex"], ["--agent", "Codex"]] {
                let collision = runProcess(
                    executablePath: cliPath,
                    arguments: ["agents", subcommand]
                        + filter
                        + ["--all", "--json", "--state-dir", stateDirectory.path],
                    environment: environment,
                    timeout: 5
                )
                let context = "agents \(subcommand) static collision \(filter): \(collision.stdout)"
                #expect(!collision.timedOut, Comment(rawValue: context))
                #expect(collision.status != 0, Comment(rawValue: context))
                let payload = try #require(
                    JSONSerialization.jsonObject(with: Data(collision.stdout.utf8)) as? [String: Any],
                    Comment(rawValue: context)
                )
                let error = try #require(payload["error"] as? [String: Any])
                #expect(error["code"] as? String == "agent_provider_identifier_collision")
            }
        }
    }

    @Test func unsafeConfiguredProviderIDsCannotEscapeTheStateDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-unsafe-provider-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".config/cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unsafeProvider = "../escape"
        try Data("""
        {
          "vault": {
            "agents": [{
              "id": "\(unsafeProvider)",
              "name": "Unsafe Provider",
              "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
              "resumeCommand": "unsafe --session {{sessionId}}"
            }]
          }
        }
        """.utf8).write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            options: .atomic
        )
        try writeAgentTreeStore(
            parentIndices: [nil],
            to: root.appendingPathComponent("escape-hook-sessions.json")
        )

        let cliPath = try bundledCLIPath()
        let environment = isolatedAgentTreeEnvironment(home: root)
        for subcommand in ["list", "tree"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [
                    "agents", subcommand, "--all", "--json",
                    "--state-dir", stateDirectory.path,
                ],
                environment: environment,
                timeout: 5
            )
            let context = "agents \(subcommand) unsafe provider: \(result.stdout)"
            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status == 0, Comment(rawValue: context))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: context)
            )
            let rows = subcommand == "list"
                ? try #require(payload["sessions"] as? [[String: Any]])
                : try #require(payload["nodes"] as? [[String: Any]])
            #expect(!rows.contains {
                ($0["agent"] as? String) == unsafeProvider
                    || ($0["provider"] as? String) == unsafeProvider
            }, Comment(rawValue: context))
        }
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
        #expect(rootNode["node_id"] as? String == "session:5:codex12:root-session8:root-run")
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
        #expect(textTree.stdout.contains("└── forked codex fork-session"))
        let textLines = textTree.stdout.split(separator: "\n").map(String.init)
        #expect(textLines.contains { $0.hasPrefix("├── spawned codex child-session") })
        #expect(textLines.contains { $0.hasPrefix("│   └── spawned codex grandchild-session") })

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

    @Test func agentsTreeTextLabelsEveryRelationshipAndMatchesRelationFilteredJSON() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-relationship-labels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var sessions: [String: Any] = [
            "root-session": [
                "sessionId": "root-session",
                "workspaceId": "workspace-root",
                "surfaceId": "surface-root",
                "runId": "root-run",
                "restoreAuthority": true,
                "startedAt": 100.0,
                "updatedAt": 100.0,
            ],
        ]
        for (index, relationship) in ["spawned", "forked", "resumed"].enumerated() {
            let sessionID = "\(relationship)-session"
            sessions[sessionID] = [
                "sessionId": sessionID,
                "workspaceId": "workspace-\(relationship)",
                "surfaceId": "surface-\(relationship)",
                "runId": "\(relationship)-run",
                "parentRunId": "root-run",
                "parentSessionId": "root-session",
                "relationship": relationship,
                "restoreAuthority": relationship != "spawned",
                "startedAt": 110.0 + Double(index),
                "updatedAt": 110.0 + Double(index),
            ]
        }
        try JSONSerialization.data(
            withJSONObject: ["version": 2, "sessions": sessions],
            options: [.sortedKeys]
        ).write(to: root.appendingPathComponent("opencode-hook-sessions.json"), options: .atomic)
        let environment = isolatedAgentTreeEnvironment(home: root)
        let baseArguments = [
            "agents", "tree", "--agent", "opencode", "--all", "--state-dir", root.path,
        ]

        let unfilteredText = runProcess(
            executablePath: cliPath,
            arguments: baseArguments,
            environment: environment,
            timeout: 5
        )
        #expect(!unfilteredText.timedOut, Comment(rawValue: unfilteredText.stdout))
        #expect(unfilteredText.status == 0, Comment(rawValue: unfilteredText.stdout))
        for relationship in ["spawned", "forked", "resumed"] {
            #expect(
                unfilteredText.stdout.contains("\(relationship) opencode \(relationship)-session"),
                Comment(rawValue: unfilteredText.stdout)
            )
        }

        for relationship in ["spawned", "forked", "resumed"] {
            let filteredArguments = baseArguments + ["--relation", relationship]
            let jsonResult = runProcess(
                executablePath: cliPath,
                arguments: filteredArguments + ["--json"],
                environment: environment,
                timeout: 5
            )
            let textResult = runProcess(
                executablePath: cliPath,
                arguments: filteredArguments,
                environment: environment,
                timeout: 5
            )
            #expect(!jsonResult.timedOut, Comment(rawValue: jsonResult.stdout))
            #expect(!textResult.timedOut, Comment(rawValue: textResult.stdout))
            #expect(jsonResult.status == 0, Comment(rawValue: jsonResult.stdout))
            #expect(textResult.status == 0, Comment(rawValue: textResult.stdout))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any]
            )
            let edges = try #require(payload["edges"] as? [[String: Any]])
            #expect(edges.count == 1)
            #expect(edges.first?["relationship"] as? String == relationship)
            #expect(edges.first?["to_run_id"] as? String == "\(relationship)-run")
            #expect(
                textResult.stdout.contains("\(relationship) opencode \(relationship)-session"),
                Comment(rawValue: textResult.stdout)
            )
            for other in ["spawned", "forked", "resumed"] where other != relationship {
                #expect(
                    !textResult.stdout.contains("\(other) opencode \(other)-session"),
                    Comment(rawValue: textResult.stdout)
                )
            }
        }
    }

    @Test func agentsTreeBreaksCorruptParentCyclesAndKeepsOrphansAsRoots() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-corrupt-cycles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions: [String: Any] = [
            "self-session": [
                "sessionId": "self-session",
                "workspaceId": "workspace-self",
                "surfaceId": "surface-self",
                "runId": "self-run",
                "parentRunId": "self-run",
                "parentSessionId": "self-session",
                "relationship": "spawned",
                "restoreAuthority": false,
                "startedAt": 100.0,
                "updatedAt": 100.0,
            ],
            "cycle-a": [
                "sessionId": "cycle-a",
                "workspaceId": "workspace-cycle-a",
                "surfaceId": "surface-cycle-a",
                "runId": "run-a",
                "parentRunId": "run-b",
                "parentSessionId": "cycle-b",
                "relationship": "spawned",
                "restoreAuthority": false,
                "startedAt": 200.0,
                "updatedAt": 200.0,
            ],
            "cycle-b": [
                "sessionId": "cycle-b",
                "workspaceId": "workspace-cycle-b",
                "surfaceId": "surface-cycle-b",
                "runId": "run-b",
                "parentRunId": "run-a",
                "parentSessionId": "cycle-a",
                "relationship": "spawned",
                "restoreAuthority": false,
                "startedAt": 300.0,
                "updatedAt": 300.0,
            ],
            "orphan-session": [
                "sessionId": "orphan-session",
                "workspaceId": "workspace-orphan",
                "surfaceId": "surface-orphan",
                "runId": "orphan-run",
                "parentRunId": "missing-run",
                "parentSessionId": "missing-session",
                "relationship": "spawned",
                "restoreAuthority": false,
                "startedAt": 400.0,
                "updatedAt": 400.0,
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: ["version": 2, "sessions": sessions],
            options: [.sortedKeys]
        ).write(to: root.appendingPathComponent("opencode-hook-sessions.json"), options: .atomic)
        let environment = isolatedAgentTreeEnvironment(home: root)
        let baseArguments = [
            "agents", "tree", "--agent", "opencode", "--all", "--state-dir", root.path,
        ]

        let firstJSON = runProcess(
            executablePath: cliPath,
            arguments: baseArguments + ["--json"],
            environment: environment,
            timeout: 5
        )
        let secondJSON = runProcess(
            executablePath: cliPath,
            arguments: baseArguments + ["--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!firstJSON.timedOut, Comment(rawValue: firstJSON.stdout))
        #expect(!secondJSON.timedOut, Comment(rawValue: secondJSON.stdout))
        #expect(firstJSON.status == 0, Comment(rawValue: firstJSON.stdout))
        #expect(secondJSON.status == 0, Comment(rawValue: secondJSON.stdout))
        #expect(firstJSON.stdout == secondJSON.stdout, Comment(rawValue: secondJSON.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(firstJSON.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(payload["nodes"] as? [[String: Any]])
        let edges = try #require(payload["edges"] as? [[String: Any]])
        let nodeIDs = nodes.compactMap { $0["node_id"] as? String }
        #expect(nodes.count == 4)
        #expect(Set(nodeIDs).count == nodes.count)
        #expect(edges.count == 1)
        #expect(edges.first?["from_run_id"] as? String == "run-b")
        #expect(edges.first?["to_run_id"] as? String == "run-a")
        #expect(!edges.contains { $0["to_run_id"] as? String == "self-run" })
        #expect(!edges.contains { $0["to_run_id"] as? String == "orphan-run" })

        let firstText = runProcess(
            executablePath: cliPath,
            arguments: baseArguments,
            environment: environment,
            timeout: 5
        )
        let secondText = runProcess(
            executablePath: cliPath,
            arguments: baseArguments,
            environment: environment,
            timeout: 5
        )
        #expect(!firstText.timedOut, Comment(rawValue: firstText.stdout))
        #expect(!secondText.timedOut, Comment(rawValue: secondText.stdout))
        #expect(firstText.status == 0, Comment(rawValue: firstText.stdout))
        #expect(secondText.status == 0, Comment(rawValue: secondText.stdout))
        #expect(firstText.stdout == secondText.stdout, Comment(rawValue: secondText.stdout))
        let lines = firstText.stdout.split(separator: "\n").map(String.init)
        for sessionID in ["self-session", "cycle-a", "cycle-b", "orphan-session"] {
            #expect(
                lines.filter { $0.contains("opencode \(sessionID) ") }.count == 1,
                Comment(rawValue: firstText.stdout)
            )
        }
        #expect(lines.contains { $0.hasPrefix("opencode self-session ") })
        #expect(lines.contains { $0.hasPrefix("opencode cycle-b ") })
        #expect(lines.contains { $0.hasPrefix("└── spawned opencode cycle-a ") })
        #expect(lines.contains { $0.hasPrefix("opencode orphan-session ") })
    }

    @Test func agentsListAndTreeCanonicalizeDuplicateRunsBeforeProjection() throws {
        let cliPath = try bundledCLIPath()
        let resumeProof = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-duplicate-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store: [String: Any] = [
            "version": 2,
            "sessions": [
                "older-parent": [
                    "sessionId": "older-parent",
                    "workspaceId": "workspace-older-parent",
                    "surfaceId": "surface-older-parent",
                    "runId": "older-parent-run",
                    "activeRunId": "older-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 80.0,
                    "updatedAt": 100.0,
                    "runs": [[
                        "runId": "older-parent-run",
                        "restoreAuthority": true,
                        "startedAt": 80.0,
                        "updatedAt": 100.0,
                    ]],
                ],
                "winning-parent": [
                    "sessionId": "winning-parent",
                    "workspaceId": "workspace-winning-parent",
                    "surfaceId": "surface-winning-parent",
                    "runId": "winning-parent-run",
                    "activeRunId": "winning-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 90.0,
                    "updatedAt": 100.0,
                    "runs": [[
                        "runId": "winning-parent-run",
                        "restoreAuthority": true,
                        "startedAt": 90.0,
                        "updatedAt": 100.0,
                    ]],
                ],
                "duplicate-session": [
                    "sessionId": "duplicate-session",
                    "workspaceId": "workspace-a",
                    "surfaceId": "surface-a",
                    "runId": "duplicate-run",
                    "activeRunId": "duplicate-run",
                    "startedAt": 100.0,
                    "updatedAt": 120.0,
                    "runs": [
                        [
                            "runId": "duplicate-run",
                            "parentRunId": "older-parent-run",
                            "parentSessionId": "older-parent",
                            "relationship": "spawned",
                            "restoreAuthority": false,
                            "startedAt": 100.0,
                            "updatedAt": 110.0,
                        ],
                        [
                            "runId": "duplicate-run",
                            "parentRunId": "winning-parent-run",
                            "parentSessionId": "winning-parent",
                            "relationship": "forked",
                            "restoreAuthority": true,
                            "cmuxHibernationResumeAttemptId": resumeProof,
                            "startedAt": 100.0,
                            "updatedAt": 120.0,
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        var environment = isolatedAgentTreeEnvironment(home: root)
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path

        let jsonResult = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!jsonResult.timedOut)
        #expect(jsonResult.status == 0, Comment(rawValue: jsonResult.stdout))
        #expect(!jsonResult.stdout.contains(resumeProof))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(payload["nodes"] as? [[String: Any]])
        let edges = try #require(payload["edges"] as? [[String: Any]])
        #expect(nodes.filter { $0["session_id"] as? String == "duplicate-session" }.count == 1)
        let childEdges = edges.filter { $0["to_run_id"] as? String == "duplicate-run" }
        #expect(childEdges.count == 1)
        #expect(childEdges.first?["from_run_id"] as? String == "winning-parent-run")
        #expect(childEdges.first?["from_session_id"] as? String == "winning-parent")
        #expect(childEdges.first?["relationship"] as? String == "forked")

        let listResult = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "list", "--session", "duplicate-session", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(!listResult.timedOut)
        #expect(listResult.status == 0, Comment(rawValue: listResult.stdout))
        #expect(!listResult.stdout.contains(resumeProof))
        let listPayload = try #require(
            JSONSerialization.jsonObject(with: Data(listResult.stdout.utf8)) as? [String: Any]
        )
        #expect(listPayload["schema_version"] as? Int == 2)
        let sessions = try #require(listPayload["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions.first?["session_id"] as? String == "duplicate-session")
        #expect(sessions.first?["run_id"] as? String == "duplicate-run")
        #expect(sessions.first?["restore_authority"] as? Bool == true)

        let textResult = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--all"],
            environment: environment,
            timeout: 5
        )
        #expect(!textResult.timedOut)
        #expect(textResult.status == 0, Comment(rawValue: textResult.stdout))
        #expect(!textResult.stdout.contains(resumeProof))
        let lines = textResult.stdout.split(separator: "\n").map(String.init)
        let winningParentIndex = try #require(lines.firstIndex { $0.contains("codex winning-parent ") })
        let childIndex = try #require(lines.firstIndex { $0.contains("codex duplicate-session ") })
        #expect(lines.filter { $0.contains("codex duplicate-session ") }.count == 1)
        #expect(childIndex == winningParentIndex + 1)
        #expect(lines[childIndex].hasPrefix("└── "))
    }

    @Test func equalTimeDuplicateRunsMergeMetadataAndDemotionInEitherOrder() throws {
        let runtimeWithBundle = AgentCmuxRuntimeIdentity(
            id: "runtime-a", socketPath: nil, bundleIdentifier: "com.cmux.test"
        )
        let runtimeWithSocket = AgentCmuxRuntimeIdentity(
            id: "runtime-a", socketPath: "/tmp/cmux-test.sock", bundleIdentifier: nil
        )
        let authoritative = AgentSessionRunRecord(
            runId: "shared-run", pid: 42, processStartedAt: 100,
            cmuxRuntime: runtimeWithBundle,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, authorityEvidence: nil,
            startedAt: 100, updatedAt: 200, endedAt: nil
        )
        let child = AgentSessionRunRecord(
            runId: "shared-run", pid: 42, processStartedAt: 100,
            cmuxRuntime: runtimeWithSocket,
            parentRunId: "parent-run", parentSessionId: "parent-session", relationship: .spawned,
            restoreAuthority: false, authorityEvidence: .managedChild,
            startedAt: 100, updatedAt: 200, endedAt: nil
        )

        let canonical: [AgentSessionRunRecord?] = [[authoritative, child], [child, authoritative]].map { runs in
            let values = AgentSessionRunCanonicalizer().runs(
                record: ClaudeHookSessionRecord(
                    sessionId: "session", workspaceId: "workspace", surfaceId: "surface",
                    startedAt: 100, updatedAt: 200, runs: runs
                ),
                provider: "codex"
            )
            return values.first
        }
        let first = try #require(canonical[0])
        let second = try #require(canonical[1])
        #expect(first == second)
        #expect(first.restoreAuthority == false)
        #expect(first.relationship == .spawned)
        #expect(first.authorityEvidence == .managedChild)
        #expect(first.parentRunId == "parent-run")
        #expect(first.pid == 42)
        #expect(first.processStartedAt == 100)
        #expect(first.cmuxRuntime?.id == "runtime-a")
        #expect(first.cmuxRuntime?.socketPath == "/tmp/cmux-test.sock")
        #expect(first.cmuxRuntime?.bundleIdentifier == "com.cmux.test")
        #expect(first.identityConflict != true)
    }

    @Test func equalTimeEndedDuplicateCannotBeRevivedByLiveDuplicate() throws {
        let resumeProof = UUID().uuidString
        let live = AgentSessionRunRecord(
            runId: "shared-run", pid: 42, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, cmuxHibernationResumeAttemptId: resumeProof,
            startedAt: 100, updatedAt: 200, endedAt: nil
        )
        let ended = AgentSessionRunRecord(
            runId: "shared-run", pid: 42, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: false, cmuxHibernationResumeAttemptId: resumeProof,
            startedAt: 100, updatedAt: 200, endedAt: 250
        )

        for runs in [[live, ended], [ended, live]] {
            let canonical = try #require(AgentSessionRunCanonicalizer().runs(
                record: ClaudeHookSessionRecord(
                    sessionId: "session", workspaceId: "workspace", surfaceId: "surface",
                    startedAt: 100, updatedAt: 200, runs: runs
                ),
                provider: "codex"
            ).first)
            #expect(canonical.endedAt == 250)
            #expect(canonical.restoreAuthority == false)
            #expect(canonical.cmuxHibernationResumeAttemptId == resumeProof)
        }
    }

    @Test func equalTimeConflictingResumeProofsDemoteAuthorityInEitherOrder() throws {
        let firstProof = UUID().uuidString
        let secondProof = UUID().uuidString
        let first = AgentSessionRunRecord(
            runId: "shared-run", pid: 42, processStartedAt: 100,
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, cmuxHibernationResumeAttemptId: firstProof,
            startedAt: 100, updatedAt: 200, endedAt: nil
        )
        var second = first
        second.cmuxHibernationResumeAttemptId = secondProof

        for runs in [[first, second], [second, first]] {
            let canonical = try #require(AgentSessionRunCanonicalizer().runs(
                record: ClaudeHookSessionRecord(
                    sessionId: "session", workspaceId: "workspace", surfaceId: "surface",
                    startedAt: 100, updatedAt: 200, runs: runs
                ),
                provider: "local-agent"
            ).first)
            #expect(canonical.cmuxHibernationResumeAttemptId == nil)
            #expect(canonical.restoreAuthority == false)
        }
    }

    @Test func equalTimeIdentityConflictsFailClosedWithoutRecordFallback() throws {
        let recordRuntime = AgentCmuxRuntimeIdentity(
            id: "record-runtime", socketPath: "/tmp/record.sock", bundleIdentifier: nil
        )
        let baseline = AgentSessionRunRecord(
            runId: "shared-run", pid: 42, processStartedAt: 100,
            cmuxRuntime: AgentCmuxRuntimeIdentity(
                id: "runtime-a", socketPath: "/tmp/a.sock", bundleIdentifier: nil
            ),
            parentRunId: nil, parentSessionId: nil, relationship: nil,
            restoreAuthority: true, startedAt: 100, updatedAt: 200, endedAt: nil
        )
        var runtimeConflict = baseline
        runtimeConflict.cmuxRuntime = AgentCmuxRuntimeIdentity(
            id: "runtime-b", socketPath: "/tmp/b.sock", bundleIdentifier: nil
        )
        var processConflict = baseline
        processConflict.pid = 84
        processConflict.processStartedAt = 101

        for conflicting in [runtimeConflict, processConflict] {
            for runs in [[baseline, conflicting], [conflicting, baseline]] {
                let canonical = try #require(AgentSessionRunCanonicalizer().runs(
                    record: ClaudeHookSessionRecord(
                        sessionId: "session", workspaceId: "workspace", surfaceId: "surface",
                        startedAt: 100, updatedAt: 200, runs: runs, cmuxRuntime: recordRuntime
                    ),
                    provider: "codex"
                ).first)
                #expect(canonical.identityConflict == true)
                #expect(canonical.restoreAuthority == false)
                #expect(canonical.pid == nil)
                #expect(canonical.processStartedAt == nil)
                #expect(canonical.cmuxRuntime == nil)
                #expect(canonical.cmuxRuntime(fallingBackTo: recordRuntime) == nil)
            }
        }
    }

    @Test func threeWayRuntimeFieldConflictsFailClosedInEveryOrder() throws {
        let first = AgentSessionRunRecord(
            runId: "shared-run",
            pid: 42,
            processStartedAt: 100,
            cmuxRuntime: AgentCmuxRuntimeIdentity(
                id: "shared-runtime",
                socketPath: "/tmp/runtime-a.sock",
                bundleIdentifier: "com.cmux.runtime"
            ),
            parentRunId: nil,
            parentSessionId: nil,
            relationship: nil,
            restoreAuthority: true,
            startedAt: 100,
            updatedAt: 200,
            endedAt: nil
        )
        var conflicting = first
        conflicting.cmuxRuntime = AgentCmuxRuntimeIdentity(
            id: "shared-runtime",
            socketPath: "/tmp/runtime-b.sock",
            bundleIdentifier: "com.cmux.runtime"
        )

        for (index, runs) in [
            [first, conflicting, first],
            [first, first, conflicting],
            [conflicting, first, first],
        ].enumerated() {
            let canonical = try #require(AgentSessionRunCanonicalizer().runs(
                record: ClaudeHookSessionRecord(
                    sessionId: "session",
                    workspaceId: "workspace",
                    surfaceId: "surface",
                    startedAt: 100,
                    updatedAt: 200,
                    runs: runs,
                    cmuxRuntime: first.cmuxRuntime
                ),
                provider: "codex"
            ).first)
            #expect(canonical.identityConflict == true, Comment(rawValue: "order \(index)"))
            #expect(!canonical.restoreAuthority, Comment(rawValue: "order \(index)"))
            #expect(canonical.cmuxRuntime == nil, Comment(rawValue: "order \(index)"))
            #expect(
                canonical.cmuxRuntime(fallingBackTo: first.cmuxRuntime) == nil,
                Comment(rawValue: "order \(index)")
            )
        }
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
            "├── spawned opencode session-00001 IDLE child workspace:workspace-00001 surface:surface-00001",
            "│   └── spawned opencode session-00002 IDLE child workspace:workspace-00002 surface:surface-00002",
            "└── spawned opencode session-00003 IDLE child workspace:workspace-00003 surface:surface-00003",
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
        #expect(iterator.next() == "└── spawned opencode child IDLE restore-owner workspace:workspace-child surface:surface-child")
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

    @Test func registryAndFinalListHeapsRetainTheSameRandomizedUnicodeTies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-list-heap-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        let provider = "heap-parity"
        let limit = 37
        let stringValues: [String?] = [
            nil, "", "alpha", "beta", "é", "e\u{301}", "日本語", "🙂", "Ω",
        ]
        var randomState: UInt64 = 0xC0FFEE_F00D_BAAD
        func nextRandom() -> UInt64 {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return randomState
        }
        func randomString() -> String? {
            stringValues[Int(nextRandom() % UInt64(stringValues.count))]
        }

        var keysBySessionID: [String: CmuxAgentSessionRegistry.HookListOrderKey] = [:]
        var finalAccumulator = SessionListEntryAccumulator(limit: limit)
        var records: [CmuxAgentSessionRegistry.Record] = []
        for index in 0..<512 {
            let storedSessionID = String(format: "stored-%04d", index)
            let sortValues = CmuxAgentSessionRegistry.HookListSortValues(
                sessionID: randomString(),
                agent: randomString(),
                runID: randomString(),
                workspaceID: randomString(),
                surfaceID: randomString(),
                identitySource: randomString(),
                pid: nextRandom().isMultiple(of: 4) ? nil : Int(nextRandom() % 7),
                processStartedAt: nextRandom().isMultiple(of: 4)
                    ? nil : TimeInterval(nextRandom() % 5)
            )
            let key = CmuxAgentSessionRegistry.HookListOrderKey(
                updatedAt: TimeInterval(nextRandom() % 5),
                sortValues: sortValues
            )
            keysBySessionID[storedSessionID] = key
            finalAccumulator.insert(
                updatedAt: key.updatedAt,
                sortValues: key.sortValues,
                payloadFactory: { [storedSessionID] in ["session_id": storedSessionID] }
            )
            let json = try JSONSerialization.data(withJSONObject: [
                "sessionId": storedSessionID,
                "workspaceId": "workspace-\(index)",
                "surfaceId": "surface-\(index)",
                "startedAt": 100.0,
                "updatedAt": 100.0,
            ], options: [.sortedKeys])
            records.append(.init(
                provider: provider,
                sessionID: storedSessionID,
                updatedAt: 100,
                json: json
            ))
        }
        try registry.apply(provider: provider, records: records)

        let snapshots = try registry.globallyBoundedRecentSnapshotsImportingAdmittedLegacy(
            sources: [.init(
                provider: provider,
                url: root.appendingPathComponent("unused-legacy.json")
            )],
            admissions: [],
            maximumRecords: limit,
            projectRecord: { projectedProvider, record in
                guard projectedProvider == provider,
                      let key = keysBySessionID[record.sessionID] else {
                    throw CmuxAgentSessionRegistry.HookListProjectionValidationError(
                        provider: projectedProvider
                    )
                }
                return key
            }
        )
        let registryRows = Set(
            snapshots[provider]?.snapshot.records.map(\.sessionID) ?? []
        )
        let finalRows = Set(finalAccumulator.sortedPayloads.compactMap {
            $0["session_id"] as? String
        })

        #expect(registryRows.count == limit)
        #expect(finalRows.count == limit)
        #expect(registryRows == finalRows)
    }

    @Test func streamedAgentListPayloadsReleaseEachEnrichmentBeforeTheNextRow() throws {
        let lifetime = AgentListPayloadLifetimeCounter()
        var entries = SessionListEntryAccumulator(limit: .max)
        for index in 0..<1_000 {
            entries.insert(
                updatedAt: Double(index),
                payload: ["session_id": "session-\(index)"],
                enrichment: { payload in
                    payload["lifetime_probe"] = AgentListPayloadLifetimeProbe(lifetime)
                }
            )
        }

        var visitedSessionIDs: [String] = []
        try entries.forEachSortedPayload { payload in
            #expect(lifetime.live == 1)
            visitedSessionIDs.append(try #require(payload["session_id"] as? String))
        }

        #expect(lifetime.live == 0)
        #expect(lifetime.peak == 1)
        #expect(visitedSessionIDs.first == "session-999")
        #expect(visitedSessionIDs.last == "session-0")
    }

    @Test func stagedAgentOutputPublishesNothingWhenDocumentConstructionFails() {
        var published = Data()

        #expect(throws: AgentStagedOutputProbeError.self) {
            try AgentStagedOutput(readChunkBytes: 1).publish(
                build: { handle in
                    try handle.write(contentsOf: Data("partial".utf8))
                    throw AgentStagedOutputProbeError.expected
                },
                publishChunk: { published.append($0) }
            )
        }

        #expect(published.isEmpty)
    }

    @Test func unboundedAgentListDefersPayloadConstructionUntilSortedTraversal() throws {
        var payloadConstructionCount = 0
        var entries = SessionListEntryAccumulator(limit: .max)
        entries.insert(
            updatedAt: 100,
            sortValues: SessionListEntryAccumulator.SortValues(
                sessionID: "session-a",
                agent: "opencode",
                runID: "run-a",
                workspaceID: "workspace-a",
                surfaceID: "surface-a",
                identitySource: "hook_session",
                pid: nil,
                processStartedAt: nil
            ),
            payloadFactory: {
                payloadConstructionCount += 1
                return ["session_id": "session-a"]
            }
        )

        #expect(payloadConstructionCount == 0)
        #expect(entries.retainedCount == 1)
        try entries.forEachSortedPayload { payload in
            let sessionID = try #require(payload["session_id"] as? String)
            #expect(sessionID == "session-a")
        }
        #expect(payloadConstructionCount == 1)
    }

    @Test func limitedAgentListBoundsTenThousandSameProcessPayloadEnrichmentsToTopK() {
        var enrichmentCount = 0
        var entries = SessionListEntryAccumulator(limit: 100)
        for index in 0..<10_000 {
            entries.insert(
                updatedAt: Double(index),
                payload: [
                    "session_id": "session-\(index)",
                    "process_key": "runtime-a\u{1F}surface-a\u{1F}42",
                ],
                enrichment: { payload in
                    enrichmentCount += 1
                    payload["enriched"] = true
                }
            )
        }

        #expect(enrichmentCount == 0)
        let payloads = entries.sortedPayloads
        #expect(entries.totalCount == 10_000)
        #expect(entries.retainedCount == 100)
        #expect(payloads.count == 100)
        #expect(enrichmentCount == 100)
        #expect(payloads.allSatisfy { $0["enriched"] as? Bool == true })
    }

    @Test func terminalObservationCandidateRetentionIsBoundedForTenThousandSameProcessSessions() {
        let observation = makeTerminalObservation(state: .working, lifecycleAuthoritative: false)
        let activeSessionID = "session-9999"
        let surfaceKey = AgentTerminalObservationJoiner.surfaceKey(
            provider: observation.sessionProviderID,
            runtimeID: observation.runtimeID,
            surfaceID: observation.surfaceID.uuidString
        )
        var accumulator = AgentTerminalObservationCandidateAccumulator(
            observations: [observation],
            activeSessionBySurface: [surfaceKey: activeSessionID]
        )
        for index in 0..<10_000 {
            accumulator.insert(makeTerminalNodeCandidate(
                sessionID: "session-\(index)",
                observation: observation,
                effectiveState: .idle
            ))
        }

        var activeCandidates = accumulator.retainedCandidates
        #expect(activeCandidates.count == 3)
        #expect(AgentTerminalObservationJoiner().merge(
            nodes: &activeCandidates,
            observations: [observation],
            activeSessionBySurface: [surfaceKey: activeSessionID]
        ))
        #expect(activeCandidates.count == 3)
        #expect(activeCandidates.first {
            $0.sessionId == activeSessionID
        }?.effectiveState == .working)
        #expect(!activeCandidates.contains { $0.identitySource == "terminal_process" })

        var ambiguousAccumulator = AgentTerminalObservationCandidateAccumulator(
            observations: [observation],
            activeSessionBySurface: [:]
        )
        for index in 0..<10_000 {
            ambiguousAccumulator.insert(makeTerminalNodeCandidate(
                sessionID: "session-\(index)",
                observation: observation,
                effectiveState: .idle
            ))
        }
        var ambiguousCandidates = ambiguousAccumulator.retainedCandidates
        #expect(ambiguousCandidates.count == 2)
        #expect(AgentTerminalObservationJoiner().merge(
            nodes: &ambiguousCandidates,
            observations: [observation],
            activeSessionBySurface: [:]
        ))
        #expect(ambiguousCandidates.count == 3)
        #expect(ambiguousCandidates.filter { $0.identitySource == "terminal_process" }.count == 1)
    }

    @Test func processIdentityRejectsPIDReuseBetweenMetadataReads() {
        var executableProbeCount = 0
        var argumentsProbeCount = 0
        var verificationProbeCount = 0
        let identity = AgentStableProcessIdentityValidator().identity(
            for: 42,
            probedKernelStartTime: 100,
            processStartTimeLookup: { _ in
                verificationProbeCount += 1
                return 101
            },
            executablePathLookup: { _ in
                executableProbeCount += 1
                return "/usr/bin/claude"
            },
            argumentsLookup: { _ in
                argumentsProbeCount += 1
                return ["claude", "--resume", "saved"]
            }
        )

        #expect(identity == nil)
        #expect(executableProbeCount == 1)
        #expect(argumentsProbeCount == 1)
        #expect(verificationProbeCount == 1)
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
            "agents", "list", "--agent", "opencode", "--all", "--limit", "2",
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
        #expect(lines[2] == "... 2 more. Raise --limit <n>.")

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

        let unlimitedJSON = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "list", "--agent", "opencode", "--all", "--json",
                "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )
        let unlimitedObject = try #require(
            JSONSerialization.jsonObject(with: Data(unlimitedJSON.stdout.utf8)) as? [String: Any]
        )
        let unlimitedSessions = try #require(unlimitedObject["sessions"] as? [[String: Any]])
        #expect(unlimitedJSON.status == 0, Comment(rawValue: unlimitedJSON.stdout))
        #expect(unlimitedSessions.count == 4)
        for index in sessions.indices {
            #expect(
                NSDictionary(dictionary: sessions[index]).isEqual(to: unlimitedSessions[index]),
                Comment(rawValue: "retained row \(index) diverged from unbounded output")
            )
        }
    }

    @Test func boundedAgentListReadsOnlyRecentCandidatesAtTheInspectionCeiling() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-list-bounded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try seedAuthoritativeAgentSessions(
            count: 20_000,
            provider: "codex",
            registry: registry
        )
        let environment = isolatedAgentTreeEnvironment(home: root)
        let bounded = try AgentHookSessionRegistryBridge.boundedRecentSnapshotsForList(
            specifications: [(provider: "codex", suffix: "codex")],
            stateDirectory: root.path,
            environment: environment,
            fileManager: .default,
            maximumRecordsPerProvider: 100
        )
        let snapshot = try #require(bounded.snapshots["codex"])
        #expect(bounded.totalRecordCounts["codex"] == 20_000)
        #expect(snapshot.records.count == 100)
        #expect(snapshot.records.map(\.sessionID) == (19_900..<20_000).reversed().map {
            String(format: "session-%05d", $0)
        })

        let metricsURL = root.appendingPathComponent("time-metrics.txt")
        let result = runProcess(
            executablePath: "/usr/bin/time",
            arguments: [
                "-l", "-o", metricsURL.path,
                cliPath, "agents", "list", "--agent", "codex", "--all",
                "--limit", "100", "--json", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 30
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(payload["total_matches"] as? Int == 20_000)
        #expect(sessions.count == 100)
        #expect(sessions.compactMap { $0["session_id"] as? String } ==
            (19_900..<20_000).reversed().map { String(format: "session-%05d", $0) })
        let stores = try #require(payload["stores"] as? [[String: Any]])
        let codexStore = try #require(stores.first { $0["agent"] as? String == "codex" })
        #expect(codexStore["exists"] as? Bool == true)
        #expect(codexStore["session_count"] as? Int == 20_000)
        let metrics = try String(contentsOf: metricsURL, encoding: .utf8)
        let maximumResidentBytes = metrics.split(separator: "\n").compactMap { line -> Int64? in
            guard line.contains("maximum resident set size") else { return nil }
            return line.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) }
        }.first
        #expect(try #require(maximumResidentBytes) < 192 * 1_024 * 1_024)

        try seedAuthoritativeAgentSessions(
            count: 1,
            provider: "cursor",
            registry: registry
        )
        let aliasResult = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "list", "--agent", "cursor-agent", "--all",
                "--limit", "1", "--json", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 10
        )
        #expect(aliasResult.status == 0, Comment(rawValue: aliasResult.stdout))
        let aliasPayload = try #require(
            JSONSerialization.jsonObject(with: Data(aliasResult.stdout.utf8)) as? [String: Any]
        )
        let aliasSessions = try #require(aliasPayload["sessions"] as? [[String: Any]])
        #expect(aliasSessions.count == 1)
        #expect(aliasSessions.first?["agent"] as? String == "cursor")

        try seedAuthoritativeAgentSessions(
            range: 20_000..<20_001,
            provider: "codex",
            registry: registry
        )
        let limitStderrURL = root.appendingPathComponent("limit-stderr.txt")
        let command = [
            cliPath, "agents", "list", "--agent", "codex", "--all",
            "--limit", "100", "--json", "--state-dir", root.path,
        ].map(shellQuoteAgentTreeArgument).joined(separator: " ")
        let overLimit = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "\(command) 2>\(shellQuoteAgentTreeArgument(limitStderrURL.path))"],
            environment: environment,
            timeout: 10
        )
        #expect(!overLimit.timedOut, Comment(rawValue: overLimit.stdout))
        #expect(overLimit.status != 0)
        let limitPayload = try #require(
            JSONSerialization.jsonObject(with: Data(overLimit.stdout.utf8)) as? [String: Any]
        )
        #expect((limitPayload["sessions"] as? [Any])?.isEmpty == true)
        let limitError = try #require(limitPayload["error"] as? [String: Any])
        #expect(limitError["code"] as? String == "storage_limit_exceeded")
        #expect(limitError["scope"] as? String == "registry_graph_nodes")
        #expect(limitError["observed_count"] as? Int64 == 20_001)
        #expect(limitError["maximum_count"] as? Int64 == 20_000)
    }

    @Test func changedLegacyProjectionCountsOnlyNewCanonicalGraphIdentities() throws {
        var roots: [URL] = []
        defer {
            for root in roots { try? FileManager.default.removeItem(at: root) }
        }

        func sessionObject(
            sessionID: String,
            runIDs: [String]
        ) -> [String: Any] {
            let primaryRunID = runIDs.first ?? "fallback-\(sessionID)"
            return [
                "sessionId": sessionID,
                "workspaceId": "workspace-\(sessionID)",
                "surfaceId": "surface-\(sessionID)",
                "runId": primaryRunID,
                "activeRunId": primaryRunID,
                "restoreAuthority": false,
                "sessionState": "ended",
                "foregroundState": "completed",
                "startedAt": 100.0,
                "updatedAt": 200.0,
                "completedAt": 200.0,
                "runs": runIDs.map { runID in
                    [
                        "runId": runID,
                        "restoreAuthority": false,
                        "startedAt": 100.0,
                        "updatedAt": 200.0,
                        "endedAt": 200.0,
                    ] as [String: Any]
                },
            ]
        }

        func fixture(
            legacySessions: [String: [String: Any]]
        ) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "cmux-agents-legacy-overlap-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots.append(root)
            let registry = CmuxAgentSessionRegistry(
                url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
            )
            try registry.apply(provider: "codex", records: [
                CmuxAgentSessionRegistry.Record(
                    provider: "codex",
                    sessionID: "session-a",
                    updatedAt: 200,
                    json: try JSONSerialization.data(
                        withJSONObject: sessionObject(sessionID: "session-a", runIDs: ["run-a"]),
                        options: [.sortedKeys]
                    )
                ),
                CmuxAgentSessionRegistry.Record(
                    provider: "codex",
                    sessionID: "session-b",
                    updatedAt: 200,
                    json: try JSONSerialization.data(
                        withJSONObject: sessionObject(sessionID: "session-b", runIDs: ["run-b"]),
                        options: [.sortedKeys]
                    )
                ),
            ])
            try JSONSerialization.data(
                withJSONObject: ["version": 2, "sessions": legacySessions],
                options: [.sortedKeys]
            ).write(
                to: root.appendingPathComponent("codex-hook-sessions.json"),
                options: .atomic
            )
            return root
        }

        let exactSessions = [
            "session-a": sessionObject(sessionID: "session-a", runIDs: ["run-a"]),
            "session-b": sessionObject(sessionID: "session-b", runIDs: ["run-b"]),
        ]
        let treeRoot = try fixture(legacySessions: exactSessions)
        let tree = try AgentHookSessionRegistryBridge.snapshots(
            specifications: [(provider: "codex", suffix: "codex")],
            stateDirectory: treeRoot.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": treeRoot.path],
            fileManager: .default,
            maximumLegacyGraphNodes: 2
        )
        #expect(tree.snapshots["codex"]?.records.count == 2)

        let listRoot = try fixture(legacySessions: exactSessions)
        let list = try AgentHookSessionRegistryBridge.boundedRecentSnapshotsForList(
            specifications: [(provider: "codex", suffix: "codex")],
            stateDirectory: listRoot.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": listRoot.path],
            fileManager: .default,
            maximumRecordsPerProvider: 1,
            maximumLegacyGraphNodes: 2
        )
        #expect(list.totalRecordCounts["codex"] == 2)
        #expect(list.snapshots["codex"]?.records.count == 1)

        let extraRunRoot = try fixture(legacySessions: [
            "session-a": sessionObject(
                sessionID: "session-a",
                runIDs: ["run-a", "run-added-by-legacy"]
            ),
        ])
        var extraRunFailure: AgentHookSessionStoreLoadFailure?
        do {
            _ = try AgentHookSessionRegistryBridge.snapshots(
                specifications: [(provider: "codex", suffix: "codex")],
                stateDirectory: extraRunRoot.path,
                environment: ["CMUX_AGENT_HOOK_STATE_DIR": extraRunRoot.path],
                fileManager: .default,
                maximumLegacyGraphNodes: 2
            )
        } catch let failure as AgentHookSessionStoreLoadFailure {
            extraRunFailure = failure
        }
        #expect(try #require(extraRunFailure).scope == .legacyGraphNodes)

        let disjointRoot = try fixture(legacySessions: [
            "legacy-only": sessionObject(sessionID: "legacy-only", runIDs: ["legacy-run"]),
        ])
        var disjointFailure: AgentHookSessionStoreLoadFailure?
        do {
            _ = try AgentHookSessionRegistryBridge.snapshots(
                specifications: [(provider: "codex", suffix: "codex")],
                stateDirectory: disjointRoot.path,
                environment: ["CMUX_AGENT_HOOK_STATE_DIR": disjointRoot.path],
                fileManager: .default,
                maximumLegacyGraphNodes: 2
            )
        } catch let failure as AgentHookSessionStoreLoadFailure {
            disjointFailure = failure
        }
        #expect(try #require(disjointFailure).scope == .legacyGraphNodes)
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

    @Test func runOnlyGraphParentsRemainAmbiguousWithinTheChildProvider() {
        let first = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "first", runID: "shared-run", updatedAt: 300
        )
        let second = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "second", runID: "shared-run", updatedAt: 200
        )
        let child = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "child", runID: "child-run", updatedAt: 400
        )
        let edge = AgentSessionGraphEdge(
            fromRunId: "shared-run", fromSessionId: nil,
            toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
        )

        #expect(
            AgentSessionGraphEdgeResolver(nodes: [first, second, child]).parentNodeId(for: edge) == nil
        )
    }

    @Test func runOnlyGraphParentsResolveOneForeignProviderAndRejectGlobalAmbiguity() {
        let foreignParent = makeAgentSessionGraphTestNode(
            provider: "claude", sessionID: "foreign", runID: "shared-run", updatedAt: 200
        )
        let ambiguousForeignParent = makeAgentSessionGraphTestNode(
            provider: "pi", sessionID: "other-foreign", runID: "shared-run", updatedAt: 300
        )
        let child = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "child", runID: "child-run", updatedAt: 400
        )
        let edge = AgentSessionGraphEdge(
            fromRunId: "shared-run", fromSessionId: nil,
            toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
        )

        #expect(
            AgentSessionGraphEdgeResolver(nodes: [foreignParent, child]).parentNodeId(for: edge)
                == foreignParent.nodeId
        )
        for nodes in [
            [foreignParent, ambiguousForeignParent, child],
            [ambiguousForeignParent, child, foreignParent],
        ] {
            #expect(AgentSessionGraphEdgeResolver(nodes: nodes).parentNodeId(for: edge) == nil)
        }
    }

    @Test func exactRunAndSessionGraphParentsStayWithinTheChildProvider() {
        let codexParent = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "shared-session", runID: "shared-run", updatedAt: 200
        )
        let claudeParent = makeAgentSessionGraphTestNode(
            provider: "claude", sessionID: "shared-session", runID: "shared-run", updatedAt: 300
        )
        let child = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "child", runID: "child-run", updatedAt: 400
        )
        let edge = AgentSessionGraphEdge(
            fromRunId: "shared-run", fromSessionId: "shared-session",
            toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
        )

        #expect(
            AgentSessionGraphEdgeResolver(nodes: [claudeParent, codexParent, child]).parentNodeId(for: edge)
                == codexParent.nodeId
        )
        #expect(
            AgentSessionGraphEdgeResolver(nodes: [claudeParent, child]).parentNodeId(for: edge)
                == claudeParent.nodeId
        )
        let ambiguousForeignParent = makeAgentSessionGraphTestNode(
            provider: "pi", sessionID: "shared-session", runID: "shared-run", updatedAt: 350
        )
        #expect(AgentSessionGraphEdgeResolver(
            nodes: [claudeParent, ambiguousForeignParent, child]
        ).parentNodeId(for: edge) == nil)
    }

    @Test func graphParentTieOrderingSurvivesSelfExclusion() {
        let first = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "shared-session", runID: "a-run", updatedAt: 200
        )
        let second = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "shared-session", runID: "b-run", updatedAt: 200
        )
        let edge = AgentSessionGraphEdge(
            fromRunId: nil, fromSessionId: "shared-session",
            toNodeId: first.nodeId, toRunId: first.runId, relationship: .resumed
        )

        #expect(
            AgentSessionGraphEdgeResolver(nodes: [second, first]).parentNodeId(for: edge) == second.nodeId
        )
    }

    @Test func graphResolverRejectsEdgesWhoseChildIsOutsideTheVisibleGraph() {
        let codex = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "shared-session", runID: "shared-run", updatedAt: 200
        )
        let claude = makeAgentSessionGraphTestNode(
            provider: "claude", sessionID: "shared-session", runID: "shared-run", updatedAt: 200
        )
        let edge = AgentSessionGraphEdge(
            fromRunId: nil, fromSessionId: "shared-session",
            toNodeId: "missing-child", toRunId: "child-run", relationship: .resumed
        )
        for nodes in [[codex, claude], [claude, codex]] {
            #expect(AgentSessionGraphEdgeResolver(nodes: nodes).parentNodeId(for: edge) == nil)
        }
    }

    @Test func graphSnapshotOrderingIsTotalForSharedProcessGenerations() {
        let nodes = [
            makeAgentSessionGraphTestNode(
                provider: "codex", sessionID: "session-c", runID: "shared-run", updatedAt: 200
            ),
            makeAgentSessionGraphTestNode(
                provider: "claude", sessionID: "session-a", runID: "shared-run", updatedAt: 200
            ),
            makeAgentSessionGraphTestNode(
                provider: "codex", sessionID: "session-b", runID: "shared-run", updatedAt: 200
            ),
        ]
        let expectedNodeIDs = nodes.map(\.nodeId).sorted()
        for permutation in [nodes, [nodes[1], nodes[2], nodes[0]], Array(nodes.reversed())] {
            #expect(
                Array(permutation).sorted(by: AgentSessionGraphOrdering().nodePrecedes).map(\.nodeId)
                    == expectedNodeIDs
            )
        }

        let edges = [
            AgentSessionGraphEdge(
                fromRunId: "parent-b", fromSessionId: nil,
                toNodeId: nodes[0].nodeId, toRunId: "shared-run", relationship: .spawned
            ),
            AgentSessionGraphEdge(
                fromRunId: nil, fromSessionId: "parent-session",
                toNodeId: nodes[0].nodeId, toRunId: "shared-run", relationship: .spawned
            ),
            AgentSessionGraphEdge(
                fromRunId: "parent-a", fromSessionId: "parent-session",
                toNodeId: nodes[0].nodeId, toRunId: "shared-run", relationship: .spawned
            ),
        ]
        let expectedParentRuns: [String?] = [nil, "parent-a", "parent-b"]
        for permutation in [edges, [edges[1], edges[2], edges[0]], Array(edges.reversed())] {
            #expect(
                Array(permutation).sorted(by: AgentSessionGraphOrdering().edgePrecedes).map(\.fromRunId)
                    == expectedParentRuns
            )
        }
    }

    @Test func graphNodeIdentityCannotCollideThroughEmbeddedSeparators() {
        let first = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "session\u{1F}shared", runID: "run", updatedAt: 200
        )
        let second = makeAgentSessionGraphTestNode(
            provider: "codex\u{1F}session", sessionID: "shared", runID: "run", updatedAt: 200
        )

        #expect(first.nodeId != second.nodeId)
        #expect(AgentSessionGraphNodeIndex().indices([first, second]).count == 2)
    }

    @Test func repeatedRunGraphResolutionStaysLinearAtTenThousandEdges() {
        let count = 10_000
        var parents: [AgentSessionGraphNode] = []
        var children: [AgentSessionGraphNode] = []
        var edges: [AgentSessionGraphEdge] = []
        parents.reserveCapacity(count)
        children.reserveCapacity(count)
        edges.reserveCapacity(count)

        for index in 0..<count {
            let parent = makeAgentSessionGraphTestNode(
                provider: index.isMultiple(of: 2) ? "codex" : "claude",
                sessionID: "parent-\(index)",
                runID: "shared-run",
                updatedAt: TimeInterval(count - index)
            )
            let child = makeAgentSessionGraphTestNode(
                provider: "codex",
                sessionID: "child-\(index)",
                runID: "child-run-\(index)",
                updatedAt: TimeInterval(count + index)
            )
            parents.append(parent)
            children.append(child)
            edges.append(AgentSessionGraphEdge(
                fromRunId: parent.runId,
                fromSessionId: parent.sessionId,
                toNodeId: child.nodeId,
                toRunId: child.runId,
                relationship: .spawned
            ))
        }

        let resolver = AgentSessionGraphEdgeResolver(nodes: parents + children)
        var mismatches = 0
        let elapsed = ContinuousClock().measure {
            for index in edges.indices {
                if resolver.parentNodeId(for: edges[index]) != parents[index].nodeId {
                    mismatches += 1
                }
            }
        }
        print("10,000 repeated-run edge resolutions took \(elapsed)")

        #expect(mismatches == 0)
        #expect(
            elapsed < .seconds(1),
            Comment(rawValue: "10,000 repeated-run edge resolutions took \(elapsed)")
        )
    }

    @Test func agentsTreeTextDeduplicatesRepeatedChildEdges() {
        let root = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "root", runID: "root-run", updatedAt: 100
        )
        let child = makeAgentSessionGraphTestNode(
            provider: "codex", sessionID: "child", runID: "child-run", updatedAt: 200
        )
        let edge = AgentSessionGraphEdge(
            fromRunId: root.runId, fromSessionId: root.sessionId,
            toNodeId: child.nodeId, toRunId: child.runId, relationship: .spawned
        )
        let lines = Array(AgentTreeTextLineSequence(
            snapshot: AgentSessionGraphSnapshot(nodes: [root, child], edges: [edge, edge]),
            maximumDepth: 64
        ))

        #expect(lines.count == 2)
        #expect(lines.last?.hasPrefix("└── ") == true, Comment(rawValue: lines.joined(separator: "\n")))
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

        var environment = isolatedAgentTreeEnvironment(home: root)
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

    @Test func agentsTreeNodeBudgetIsGlobalStructuredAndNeverReturnsPartialRows() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAgentTreeStore(
            parentIndices: [nil, nil],
            to: root.appendingPathComponent("codex-hook-sessions.json")
        )
        try writeAgentTreeStore(
            parentIndices: [nil, nil],
            to: root.appendingPathComponent("opencode-hook-sessions.json")
        )
        let environment = isolatedAgentTreeEnvironment(home: root)

        let text = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "tree", "--all", "--max-nodes", "3", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )
        #expect(!text.timedOut, Comment(rawValue: text.stdout))
        #expect(text.status != 0)
        #expect(text.stdout.contains("agent_graph_node_budget_exceeded"))
        #expect(!text.stdout.contains("codex session-"))
        #expect(!text.stdout.contains("opencode session-"))

        let stderrURL = root.appendingPathComponent("tree-budget-stderr.txt")
        let jsonArguments = [
            cliPath, "agents", "tree", "--all", "--json", "--max-nodes", "3",
            "--state-dir", root.path,
        ]
        let jsonCommand = jsonArguments.map(shellQuoteAgentTreeArgument).joined(separator: " ")
        let json = runProcess(
            executablePath: "/bin/sh",
            arguments: [
                "-c", "\(jsonCommand) 2>\(shellQuoteAgentTreeArgument(stderrURL.path))",
            ],
            environment: environment,
            timeout: 5
        )
        #expect(!json.timedOut, Comment(rawValue: json.stdout))
        #expect(json.status != 0)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        )
        let error = try #require(payload["error"] as? [String: Any])
        #expect(payload["schema_version"] as? Int == 2)
        #expect(error["code"] as? String == "agent_graph_node_budget_exceeded")
        #expect(error["limit"] as? Int == 3)
        #expect(error["observed_at_least"] as? Int == 4)
        #expect((payload["nodes"] as? [Any])?.isEmpty == true)
        #expect((payload["edges"] as? [Any])?.isEmpty == true)
        let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
        #expect(stderr.contains("agent_graph_node_budget_exceeded"))

        let filtered = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "tree", "--agent", "opencode", "--session", "session-00001",
                "--all", "--json", "--max-nodes", "1", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )
        #expect(filtered.status == 0, Comment(rawValue: filtered.stdout))
        let filteredPayload = try #require(
            JSONSerialization.jsonObject(with: Data(filtered.stdout.utf8)) as? [String: Any]
        )
        let filteredNodes = try #require(filteredPayload["nodes"] as? [[String: Any]])
        #expect(filteredNodes.count == 1)
        #expect(filteredNodes.first?["session_id"] as? String == "session-00001")
    }

    @Test func agentsTreePreflightCountsSessionProcessCohortsAndCanonicalizesDuplicateRuns() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-cohort-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        let runtime: [String: Any] = ["id": "runtime-a"]
        let cohortRecords = try (0..<4).map { index in
            let sessionID = index == 0 ? "selected-session" : "cohort-\(index)"
            let runID = "run-\(index)"
            let record: [String: Any] = [
                "sessionId": sessionID,
                "workspaceId": "workspace",
                "surfaceId": "surface",
                "runId": runID,
                "activeRunId": runID,
                "cmuxRuntime": runtime,
                "startedAt": 100.0,
                "updatedAt": 200.0,
                "runs": [[
                    "runId": runID,
                    "pid": 42,
                    "processStartedAt": 100.0,
                    "cmuxRuntime": runtime,
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ]],
            ]
            return CmuxAgentSessionRegistry.Record(
                provider: "opencode",
                sessionID: sessionID,
                updatedAt: 200,
                json: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            )
        }
        try registry.apply(provider: "opencode", records: cohortRecords)
        let environment = isolatedAgentTreeEnvironment(home: root)
        let cohort = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "tree", "--agent", "opencode", "--session", "selected-session",
                "--all", "--max-nodes", "3", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 5
        )
        #expect(cohort.status != 0)
        #expect(cohort.stdout.contains("agent_graph_node_budget_exceeded"))

        let duplicateRuns: [[String: Any]] = (0..<5_000).map { index in
            [
                "runId": "one-logical-run",
                "restoreAuthority": index.isMultiple(of: 2),
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]
        }
        let duplicateRecord: [String: Any] = [
            "sessionId": "duplicate-session",
            "workspaceId": "workspace",
            "surfaceId": "surface",
            "runId": "one-logical-run",
            "activeRunId": "one-logical-run",
            "startedAt": 100.0,
            "updatedAt": 200.0,
            "runs": duplicateRuns,
        ]
        try registry.apply(provider: "gemini", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "gemini",
                sessionID: "duplicate-session",
                updatedAt: 200,
                json: try JSONSerialization.data(
                    withJSONObject: duplicateRecord,
                    options: [.sortedKeys]
                )
            ),
        ])
        let duplicate = runProcess(
            executablePath: cliPath,
            arguments: [
                "agents", "tree", "--agent", "gemini", "--session", "duplicate-session",
                "--all", "--json", "--max-nodes", "1", "--state-dir", root.path,
            ],
            environment: environment,
            timeout: 10
        )
        #expect(!duplicate.timedOut, Comment(rawValue: duplicate.stdout))
        #expect(duplicate.status == 0, Comment(rawValue: duplicate.stdout))
        let duplicatePayload = try #require(
            JSONSerialization.jsonObject(with: Data(duplicate.stdout.utf8)) as? [String: Any]
        )
        #expect((duplicatePayload["nodes"] as? [Any])?.count == 1)
    }

    @Test func agentsTreeRejectsInvalidBudgetsExcessiveDepthAndOversizedRawRecords() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = isolatedAgentTreeEnvironment(home: root)

        for value in ["0", "not-a-number", "20001"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["agents", "tree", "--max-nodes", value, "--state-dir", root.path],
                environment: environment,
                timeout: 5
            )
            #expect(result.status != 0)
            #expect(result.stdout.contains("--max-nodes must be an integer from 1 through 20000"))
        }

        let depth = runProcess(
            executablePath: cliPath,
            arguments: ["agents", "tree", "--depth", "4097", "--state-dir", root.path],
            environment: environment,
            timeout: 5
        )
        #expect(depth.status != 0)
        #expect(depth.stdout.contains("--depth must not exceed 4096"))

        let sessionID = "oversized-session"
        var oversizedJSON = Data(
            "{\"sessionId\":\"\(sessionID)\",\"workspaceId\":\"workspace\",\"surfaceId\":\"surface\",\"startedAt\":100,\"updatedAt\":200,\"padding\":\"".utf8
        )
        oversizedJSON.append(Data(repeating: 97, count: (4 * 1_024 * 1_024) + 1))
        oversizedJSON.append(Data("\"}".utf8))
        let registry = CmuxAgentSessionRegistry(
            url: root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        )
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex", sessionID: sessionID, updatedAt: 200, json: oversizedJSON
            ),
        ])
        for subcommand in ["list", "tree"] {
            let oversizedStderrURL = root.appendingPathComponent("oversized-\(subcommand)-stderr.txt")
            let oversizedCommand = [
                cliPath, "agents", subcommand, "--agent", "codex", "--session", sessionID,
                "--all", "--json", "--state-dir", root.path,
            ].map(shellQuoteAgentTreeArgument).joined(separator: " ")
            let oversized = runProcess(
                executablePath: "/bin/sh",
                arguments: [
                    "-c", "\(oversizedCommand) 2>\(shellQuoteAgentTreeArgument(oversizedStderrURL.path))",
                ],
                environment: environment,
                timeout: 15
            )
            #expect(!oversized.timedOut, Comment(rawValue: oversized.stdout))
            #expect(oversized.status != 0)
            let oversizedPayload = try #require(
                JSONSerialization.jsonObject(with: Data(oversized.stdout.utf8)) as? [String: Any]
            )
            #expect(oversizedPayload["schema_version"] as? Int == 2)
            let oversizedError = try #require(oversizedPayload["error"] as? [String: Any])
            #expect(oversizedError["code"] as? String == "storage_limit_exceeded")
            #expect(oversizedError["provider"] as? String == "codex")
            #expect(oversizedError["path"] as? String == registry.url.path)
            #expect(oversizedError["scope"] as? String == "registry_record")
            #expect(oversizedError["session_id"] as? String == sessionID)
            #expect((oversizedError["observed_bytes"] as? Int64) ?? 0 > 4 * 1_024 * 1_024)
            #expect(oversizedError["maximum_bytes"] as? Int64 == 4 * 1_024 * 1_024)
            #expect(oversizedError["recovery_action"] as? String == "narrow_agent_selection")
            #expect((oversizedError["guidance"] as? String)?.contains("--agent codex") == true)
            if subcommand == "tree" {
                #expect((oversizedPayload["nodes"] as? [Any])?.isEmpty == true)
                #expect((oversizedPayload["edges"] as? [Any])?.isEmpty == true)
            } else {
                #expect((oversizedPayload["sessions"] as? [Any])?.isEmpty == true)
            }
            let stderr = try String(contentsOf: oversizedStderrURL, encoding: .utf8)
            #expect(stderr.contains("Retry with --agent codex"))
            #expect(stderr.contains(registry.url.path))
            #expect(stderr.contains(sessionID))
        }
    }

    @Test func legacyStorageLimitGuidancePreservesTheCompatibilityFile() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-legacy-record-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-over-limit"
        let legacyURL = root.appendingPathComponent("codex-hook-sessions.json")
        var legacyData = Data(
            "{\"version\":2,\"sessions\":{\"\(sessionID)\":{\"sessionId\":\"\(sessionID)\",\"workspaceId\":\"workspace\",\"surfaceId\":\"surface\",\"startedAt\":100,\"updatedAt\":200,\"padding\":\"".utf8
        )
        legacyData.append(Data(repeating: 97, count: (4 * 1_024 * 1_024) + 1))
        legacyData.append(Data("\"}}}".utf8))
        try legacyData.write(to: legacyURL, options: .atomic)

        let stderrURL = root.appendingPathComponent("legacy-limit-stderr.txt")
        let command = [
            cliPath, "agents", "tree", "--agent", "codex", "--session", sessionID,
            "--all", "--json", "--state-dir", root.path,
        ].map(shellQuoteAgentTreeArgument).joined(separator: " ")
        let result = runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "\(command) 2>\(shellQuoteAgentTreeArgument(stderrURL.path))"],
            environment: isolatedAgentTreeEnvironment(home: root),
            timeout: 15
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let error = try #require(payload["error"] as? [String: Any])
        #expect(error["code"] as? String == "storage_limit_exceeded")
        #expect(error["scope"] as? String == "legacy_record")
        #expect(error["session_id"] as? String == sessionID)
        #expect(error["path"] as? String == legacyURL.path)
        #expect(error["recovery_action"] as? String == "move_legacy_file_aside")
        let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
        #expect(stderr.contains("Move \(legacyURL.path) aside without deleting it"))
        #expect(stderr.contains(root.appendingPathComponent(CmuxAgentSessionRegistry.filename).path))
        #expect(stderr.contains("If that database has no codex rows"))
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
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
        #expect(result.stdout.contains("unknown agent 'definitely-not-an-agent'"))
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
        #expect(result.stdout.contains("--agent requires a value"))
    }

    @Test func agentsValueOptionsRejectFollowingFlagAsMissingValue() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-missing-option-value-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(subcommand: String, option: String)] = [
            ("list", "--agent"),
            ("list", "--session"),
            ("list", "--workspace"),
            ("list", "--surface"),
            ("list", "--cwd"),
            ("list", "--state-dir"),
            ("list", "--codex-home"),
            ("list", "--limit"),
            ("list", "--state"),
            ("list", "--activity"),
            ("list", "--work-kind"),
            ("tree", "--agent"),
            ("tree", "--session"),
            ("tree", "--workspace"),
            ("tree", "--surface"),
            ("tree", "--state-dir"),
            ("tree", "--relation"),
            ("tree", "--state"),
            ("tree", "--activity"),
            ("tree", "--work-kind"),
            ("tree", "--depth"),
            ("tree", "--max-nodes"),
        ]

        for testCase in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["agents", testCase.subcommand, testCase.option, "--json"],
                environment: isolatedAgentTreeEnvironment(home: root),
                timeout: 15
            )
            let context = "agents \(testCase.subcommand) \(testCase.option): \(result.stdout)"

            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status != 0, Comment(rawValue: context))
            #expect(
                result.stdout.contains("\(testCase.option) requires a value"),
                Comment(rawValue: context)
            )
        }
    }

    @Test func agentAndSessionListErrorsNameTheInvokedCommand() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-list-error-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(command: String, arguments: [String], expectedPrefix: String)] = [
            ("agents", ["list", "--state-dir"], "agents list: --state-dir requires a value"),
            ("agents", ["list", "--limit", "0", "--state-dir", root.path], "agents list: --limit must be a positive integer"),
            ("sessions", ["list", "--state-dir"], "sessions list: --state-dir requires a value"),
            ("sessions", ["list", "--limit", "0", "--state-dir", root.path], "sessions list: --limit must be a positive integer"),
            ("sessions", ["list", "--state", "invalid", "--state-dir", root.path], "sessions list: unknown state 'invalid'"),
            ("sessions", ["list", "--activity", "invalid", "--state-dir", root.path], "sessions list: unknown activity 'invalid'"),
            ("sessions", ["list", "--work-kind", "invalid", "--state-dir", root.path], "sessions list: unknown workload kind 'invalid'"),
        ]

        for testCase in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [testCase.command] + testCase.arguments,
                environment: isolatedAgentTreeEnvironment(home: root),
                timeout: 5
            )
            let context = "\(testCase.command): \(result.stdout)"

            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status != 0, Comment(rawValue: context))
            #expect(result.stdout.contains(testCase.expectedPrefix), Comment(rawValue: context))
        }
    }

    @Test func sessionsTreeErrorsNameTheInvokedCommand() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-tree-error-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(arguments: [String], expectedPrefix: String)] = [
            (["tree", "--state", "invalid", "--state-dir", root.path], "sessions tree: unknown state 'invalid'"),
            (["tree", "--depth", "0", "--state-dir", root.path], "sessions tree: --depth must be a positive integer"),
            (["tree", "--state-dir"], "sessions tree: --state-dir requires a value"),
            (["tree", "unexpected", "--state-dir", root.path], "sessions tree: unexpected argument 'unexpected'"),
        ]

        for testCase in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["sessions"] + testCase.arguments,
                environment: isolatedAgentTreeEnvironment(home: root),
                timeout: 5
            )
            let context = "sessions tree: \(result.stdout)"

            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status != 0, Comment(rawValue: context))
            #expect(result.stdout.contains(testCase.expectedPrefix), Comment(rawValue: context))
        }
    }

    @Test func agentAndSessionJSONParseErrorsUseCompleteStructuredOutput() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-json-parse-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(command: String, subcommand: String)] = [
            ("agents", "list"),
            ("sessions", "list"),
            ("agents", "tree"),
            ("sessions", "tree"),
        ]

        for (index, testCase) in cases.enumerated() {
            let expectedPrefix = "\(testCase.command) \(testCase.subcommand): unknown state 'invalid'"
            let stderrURL = root.appendingPathComponent("parse-error-\(index).stderr")
            let command = ([
                cliPath,
                testCase.command,
                testCase.subcommand,
                "--state",
                "invalid",
                "--json",
                "--state-dir",
                root.path,
            ]).map(shellQuoteAgentTreeArgument).joined(separator: " ")
            let result = runProcess(
                executablePath: "/bin/sh",
                arguments: [
                    "-c", "\(command) 2>\(shellQuoteAgentTreeArgument(stderrURL.path))",
                ],
                environment: isolatedAgentTreeEnvironment(home: root),
                timeout: 5
            )
            let context = "\(testCase.command) \(testCase.subcommand): \(result.stdout)"

            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status != 0, Comment(rawValue: context))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: context)
            )
            let error = try #require(payload["error"] as? [String: Any])
            #expect(payload["schema_version"] as? Int == 2)
            #expect(error["code"] as? String == "invalid_arguments")
            #expect((error["message"] as? String)?.contains(expectedPrefix) == true)
            if testCase.subcommand == "tree" {
                #expect((payload["nodes"] as? [Any])?.isEmpty == true)
                #expect((payload["edges"] as? [Any])?.isEmpty == true)
            } else {
                #expect((payload["sessions"] as? [Any])?.isEmpty == true)
            }
            let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
            #expect(stderr.contains(expectedPrefix), Comment(rawValue: stderr))
        }
    }

    @Test func agentAndSessionJSONStateDirectoryFailuresUseCompleteStructuredOutput() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-json-state-error-\(UUID().uuidString)", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: stateDirectory.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: stateDirectory.path
        )

        let cases: [(command: String, subcommand: String)] = [
            ("agents", "list"),
            ("sessions", "list"),
            ("agents", "tree"),
            ("sessions", "tree"),
        ]

        for (index, testCase) in cases.enumerated() {
            let expectedPrefix = "\(testCase.command) \(testCase.subcommand):"
            let stderrURL = root.appendingPathComponent("state-error-\(index).stderr")
            let command = ([
                cliPath,
                testCase.command,
                testCase.subcommand,
                "--json",
                "--state-dir",
                stateDirectory.path,
            ]).map(shellQuoteAgentTreeArgument).joined(separator: " ")
            let result = runProcess(
                executablePath: "/bin/sh",
                arguments: [
                    "-c", "\(command) 2>\(shellQuoteAgentTreeArgument(stderrURL.path))",
                ],
                environment: isolatedAgentTreeEnvironment(home: root),
                timeout: 5
            )
            let context = "\(testCase.command) \(testCase.subcommand): \(result.stdout)"

            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status != 0, Comment(rawValue: context))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: context)
            )
            let error = try #require(payload["error"] as? [String: Any])
            #expect(payload["schema_version"] as? Int == 2)
            #expect(error["code"] as? String == "agent_state_unavailable")
            #expect((error["message"] as? String)?.hasPrefix(expectedPrefix) == true)
            if testCase.subcommand == "tree" {
                #expect((payload["nodes"] as? [Any])?.isEmpty == true)
                #expect((payload["edges"] as? [Any])?.isEmpty == true)
            } else {
                #expect((payload["sessions"] as? [Any])?.isEmpty == true)
            }
            let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
            #expect(stderr.contains(expectedPrefix), Comment(rawValue: stderr))
        }
    }

    @Test func agentAndSessionJSONExplicitSocketFailuresUseCompleteStructuredOutput() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-json-socket-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("missing.sock").path

        let cases: [(command: String, subcommand: String)] = [
            ("agents", "list"),
            ("sessions", "list"),
            ("agents", "tree"),
            ("sessions", "tree"),
        ]

        for (index, testCase) in cases.enumerated() {
            let expectedPrefix = "\(testCase.command) \(testCase.subcommand):"
            let stderrURL = root.appendingPathComponent("socket-error-\(index).stderr")
            let command = ([
                cliPath,
                "--socket",
                socketPath,
                testCase.command,
                testCase.subcommand,
                "--json",
                "--state-dir",
                root.path,
            ]).map(shellQuoteAgentTreeArgument).joined(separator: " ")
            let result = runProcess(
                executablePath: "/bin/sh",
                arguments: [
                    "-c", "\(command) 2>\(shellQuoteAgentTreeArgument(stderrURL.path))",
                ],
                environment: isolatedAgentTreeEnvironment(home: root),
                timeout: 5
            )
            let context = "\(testCase.command) \(testCase.subcommand): \(result.stdout)"

            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status != 0, Comment(rawValue: context))
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                Comment(rawValue: context)
            )
            let error = try #require(payload["error"] as? [String: Any])
            #expect(payload["schema_version"] as? Int == 2)
            #expect(error["code"] as? String == "agent_runtime_unavailable")
            #expect((error["message"] as? String)?.hasPrefix(expectedPrefix) == true)
            #expect(error["path"] as? String == socketPath)
            if testCase.subcommand == "tree" {
                #expect((payload["nodes"] as? [Any])?.isEmpty == true)
                #expect((payload["edges"] as? [Any])?.isEmpty == true)
            } else {
                #expect((payload["sessions"] as? [Any])?.isEmpty == true)
            }
            let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
            #expect(stderr.contains(expectedPrefix), Comment(rawValue: stderr))
        }
    }

    @Test func agentsEqualsOptionsPreserveDashLeadingValues() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-dash-value-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for subcommand in ["list", "tree"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["agents", subcommand, "--agent=-definitely-not-an-agent", "--json"],
                environment: isolatedAgentTreeEnvironment(home: root),
                timeout: 5
            )
            let context = "agents \(subcommand): \(result.stdout)"

            #expect(!result.timedOut, Comment(rawValue: context))
            #expect(result.status != 0, Comment(rawValue: context))
            #expect(result.stdout.contains("unknown agent '-definitely-not-an-agent'"), Comment(rawValue: context))
            #expect(!result.stdout.contains("--agent requires a value"), Comment(rawValue: context))
        }
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

private func seedAuthoritativeAgentSessions(
    count: Int,
    provider: String,
    registry: CmuxAgentSessionRegistry
) throws {
    try seedAuthoritativeAgentSessions(range: 0..<count, provider: provider, registry: registry)
}

private func seedAuthoritativeAgentSessions(
    range: Range<Int>,
    provider: String,
    registry: CmuxAgentSessionRegistry
) throws {
    let records = range.map { index in
        let sessionID = String(format: "session-%05d", index)
        let json = Data("""
        {"sessionId":"\(sessionID)","workspaceId":"workspace-\(index % 100)","surfaceId":"surface-\(index)","runId":"run-\(index)","restoreAuthority":false,"sessionState":"ended","foregroundState":"idle","startedAt":\(index),"updatedAt":\(index),"completedAt":\(index)}
        """.utf8)
        return CmuxAgentSessionRegistry.Record(
            provider: provider,
            sessionID: sessionID,
            updatedAt: TimeInterval(index),
            json: json
        )
    }
    try registry.apply(provider: provider, records: records)
}

private func seedAuthoritativeAgentProviders(
    _ providers: [String],
    registry: CmuxAgentSessionRegistry
) throws {
    guard !providers.isEmpty else { return }
    // One connection and transaction keep the 256-provider boundary fixture
    // fast while exercising the same insert triggers as production writes.
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        registry.url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        defer { if let database { sqlite3_close(database) } }
        throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        INSERT INTO agent_sessions (
            provider, session_id, updated_at, writer_generation, record_json
        ) VALUES (?1, ?2, ?3, ?4, ?5)
        """,
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
    }
    do {
        for (index, provider) in providers.enumerated() {
            let sessionID = "provider-session-\(index)"
            let json = try JSONSerialization.data(withJSONObject: [
                "sessionId": sessionID,
                "workspaceId": "provider-workspace-\(index)",
                "surfaceId": "provider-surface-\(index)",
                "startedAt": TimeInterval(index),
                "updatedAt": TimeInterval(index),
            ], options: [.sortedKeys])
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard provider.withCString({
                sqlite3_bind_text(statement, 1, $0, -1, transient)
            }) == SQLITE_OK,
            sessionID.withCString({
                sqlite3_bind_text(statement, 2, $0, -1, transient)
            }) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
            sqlite3_bind_double(statement, 3, TimeInterval(index))
            sqlite3_bind_int64(
                statement,
                4,
                sqlite3_int64(CmuxAgentSessionRegistry.currentWriterGeneration)
            )
            let blobStatus = json.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count), transient)
            }
            guard blobStatus == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    } catch {
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        throw error
    }
}

private func agentSessionRegistryRecord(
    provider: String,
    sessionID: String,
    updatedAt: TimeInterval
) throws -> CmuxAgentSessionRegistry.Record {
    CmuxAgentSessionRegistry.Record(
        provider: provider,
        sessionID: sessionID,
        updatedAt: updatedAt,
        json: try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionID,
            "workspaceId": "workspace-\(sessionID)",
            "surfaceId": "surface-\(sessionID)",
            "startedAt": updatedAt,
            "updatedAt": updatedAt,
        ], options: [.sortedKeys])
    )
}

private func executeAgentSessionSQLite(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        defer { if let database { sqlite3_close(database) } }
        throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(database, sql, nil, nil, &message)
    guard status == SQLITE_OK else {
        let description = message.map { String(cString: $0) } ?? "SQLite test setup failed"
        sqlite3_free(message)
        throw NSError(
            domain: "AgentSessionCLIRegressionTests.SQLite",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

private func shellQuoteAgentTreeArgument(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private func makeTerminalObservation(
    state: CmuxAgentObservedState,
    lifecycleAuthoritative: Bool,
    workspaceID: UUID = UUID(),
    surfaceID: UUID = UUID(),
    surfaceGeneration: UInt64 = 9,
    revision: UInt64 = 4,
    publishedAt: TimeInterval = 200,
    sessionProviderID: String? = nil,
    processStartSeconds: Int64 = 100
) -> CmuxAgentTerminalObservation {
    CmuxAgentTerminalObservation(
        runtimeID: "runtime-test",
        workspaceID: workspaceID,
        surfaceID: surfaceID,
        surfaceGeneration: surfaceGeneration,
        revision: revision,
        familyID: "codex",
        sessionProviderID: sessionProviderID ?? (lifecycleAuthoritative ? "claude" : "codex"),
        lifecycleAuthoritative: lifecycleAuthoritative,
        state: state,
        pid: 42,
        processStartSeconds: processStartSeconds,
        processStartMicroseconds: 123,
        cwd: "/tmp/project",
        publishedAt: publishedAt
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

private func makeAgentSessionGraphTestNode(
    provider: String,
    sessionID: String,
    runID: String,
    updatedAt: TimeInterval
) -> AgentSessionGraphNode {
    AgentSessionGraphNode(
        provider: provider,
        sessionId: sessionID,
        runId: runID,
        pid: nil,
        processStartedAt: nil,
        cmuxRuntime: nil,
        workspaceId: "workspace-\(sessionID)",
        surfaceId: "surface-\(sessionID)",
        processState: .unknown,
        sessionState: .active,
        foregroundState: .idle,
        attentionState: .none,
        activity: AgentActivitySnapshot(state: .idle, busy: false, modes: [], counts: .init()),
        effectiveState: .idle,
        workloads: [],
        restoreAuthority: true,
        startedAt: 100,
        updatedAt: updatedAt,
        endedAt: nil
    )
}

private final class AgentListPayloadLifetimeCounter {
    var live = 0
    var peak = 0
}

private final class AgentListPayloadLifetimeProbe {
    private let counter: AgentListPayloadLifetimeCounter

    init(_ counter: AgentListPayloadLifetimeCounter) {
        self.counter = counter
        counter.live += 1
        counter.peak = max(counter.peak, counter.live)
    }

    deinit {
        counter.live -= 1
    }
}

private enum AgentStagedOutputProbeError: Error {
    case expected
}
