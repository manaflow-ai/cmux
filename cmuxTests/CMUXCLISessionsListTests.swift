import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func agentsDoNotFocusWindowBeforeReadOnlyInspection() throws {
        let cliPath = try bundledCLIPath()
        let responder = try agentsInstanceResponder(workspaces: [:])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", responder.path,
                "--window", "window-local",
                "agents", "--json",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let methods = responder.receivedRequests.compactMap { request -> String? in
            guard let data = request.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return payload["method"] as? String
        }
        #expect(methods.contains("system.tree"))
        #expect(!methods.contains("window.focus"))
    }

    @Test func agentsTreeEnforcesNodeLimitDuringCandidateConstruction() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-candidate-limit-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "selected": [
                    "sessionId": "selected",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-selected",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 100.0,
                ],
                "unselected": [
                    "sessionId": "unselected",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-unselected",
                    "restoreAuthority": true,
                    "startedAt": 200.0,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-selected", "surface-unselected"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", responder.path,
                "agents", "tree", "--agent", "codex",
                "--session", "selected", "--max-nodes", "1", "--json",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(result.status != 0)
        #expect(result.stderr.contains("more than 1 node matched"))
    }

    @Test func agentsIncludeWorkspaceOwnedSessionsWhenSavedSurfaceIsStale() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-stale-surface-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "stale-surface-session": [
                    "sessionId": "stale-surface-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-closed",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-current"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let listResult = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(listResult.status == 0, Comment(rawValue: listResult.stdout))
        let listPayload = try #require(
            JSONSerialization.jsonObject(with: Data(listResult.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(listPayload["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["session_id"] as? String } == ["stale-surface-session"])

        let treeResult = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "tree", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(treeResult.status == 0, Comment(rawValue: treeResult.stdout))
        let treePayload = try #require(
            JSONSerialization.jsonObject(with: Data(treeResult.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(treePayload["nodes"] as? [[String: Any]])
        #expect(nodes.map { $0["session_id"] as? String } == ["stale-surface-session"])
    }

    @Test func agentsListIncludesRestoreAuthorityRecordsByDefault() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-restore-authority-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "restorable-session": [
                    "sessionId": "restorable-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-root",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-root"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "list", "--agent", "codex", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["session_id"] as? String } == ["restorable-session"])
    }

    @Test func agentsTreeResolvesClaudeWorkflowSessionBeforeFiltering() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-claude-workflow-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let claudeConfig = root.appendingPathComponent("claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workflowSessionID = "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa"
        let secondWorkflowSessionID = "cccccccc-3333-3333-3333-cccccccccccc"
        let transcriptSessionID = "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb"
        let projectDirectoryName = repository.path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let projectDirectory = claudeConfig
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDirectoryName, isDirectory: true)
        let workflowContainer = projectDirectory
            .appendingPathComponent(workflowSessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: workflowContainer, withIntermediateDirectories: true)
        let secondWorkflowContainer = projectDirectory
            .appendingPathComponent(secondWorkflowSessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: secondWorkflowContainer, withIntermediateDirectories: true)
        try "{}\n".write(
            to: projectDirectory.appendingPathComponent("\(transcriptSessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                workflowSessionID: [
                    "sessionId": workflowSessionID,
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-root",
                    "cwd": repository.path,
                    "transcriptPath": workflowContainer.path,
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/usr/local/bin/claude",
                        "arguments": ["/usr/local/bin/claude"],
                        "workingDirectory": repository.path,
                        "environment": ["CLAUDE_CONFIG_DIR": claudeConfig.path],
                        "source": "environment",
                    ],
                ],
                secondWorkflowSessionID: [
                    "sessionId": secondWorkflowSessionID,
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-root",
                    "cwd": repository.path,
                    "transcriptPath": secondWorkflowContainer.path,
                    "restoreAuthority": true,
                    "startedAt": 110.0,
                    "updatedAt": 210.0,
                    "launchCommand": [
                        "launcher": "claude",
                        "executablePath": "/usr/local/bin/claude",
                        "arguments": ["/usr/local/bin/claude"],
                        "workingDirectory": repository.path,
                        "environment": ["CLAUDE_CONFIG_DIR": claudeConfig.path],
                        "source": "environment",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-root"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", responder.path,
                "agents", "tree", "--agent", "claude", "--session", transcriptSessionID, "--json",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(payload["nodes"] as? [[String: Any]])
        #expect(nodes.count == 2)
        #expect(nodes.allSatisfy { $0["session_id"] as? String == transcriptSessionID })
        #expect(Set(nodes.compactMap { $0["hook_session_id"] as? String }) == [
            workflowSessionID,
            secondWorkflowSessionID,
        ])
        #expect(Set(nodes.compactMap { $0["node_id"] as? String }).count == 2)

        let textResult = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", responder.path,
                "agents", "tree", "--agent", "claude", "--session", transcriptSessionID,
            ],
            environment: environment,
            timeout: 5
        )
        #expect(textResult.status == 0, Comment(rawValue: textResult.stdout))
    }

    @Test func agentsTreePreservesHiddenAncestorsAndRejectsConflictingParents() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-parent-integrity-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "hidden-parent": [
                    "sessionId": "hidden-parent",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-parent",
                    "runId": "hidden-parent-run",
                    "restoreAuthority": false,
                    "startedAt": 100.0,
                    "updatedAt": 100.0,
                ],
                "visible-child": [
                    "sessionId": "visible-child",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-child",
                    "runId": "visible-child-run",
                    "parentRunId": "hidden-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 110.0,
                    "updatedAt": 110.0,
                ],
                "visible-grandchild": [
                    "sessionId": "visible-grandchild",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-grandchild",
                    "runId": "visible-grandchild-run",
                    "parentRunId": "visible-child-run",
                    "restoreAuthority": true,
                    "startedAt": 115.0,
                    "updatedAt": 115.0,
                ],
                "other-parent": [
                    "sessionId": "other-parent",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-other",
                    "runId": "other-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 120.0,
                    "updatedAt": 120.0,
                ],
                "conflicting-child": [
                    "sessionId": "conflicting-child",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-conflict",
                    "runId": "conflicting-child-run",
                    "parentSessionId": "hidden-parent",
                    "parentRunId": "other-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 130.0,
                    "updatedAt": 130.0,
                ],
                "shared-session-a": [
                    "sessionId": "shared-parent-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-shared-session-a",
                    "runId": "shared-session-run-a",
                    "restoreAuthority": true,
                    "startedAt": 140.0,
                    "updatedAt": 140.0,
                ],
                "shared-session-b": [
                    "sessionId": "shared-parent-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-shared-session-b",
                    "runId": "shared-session-run-b",
                    "restoreAuthority": true,
                    "startedAt": 150.0,
                    "updatedAt": 150.0,
                ],
                "ambiguous-session-child": [
                    "sessionId": "ambiguous-session-child",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-ambiguous-session-child",
                    "runId": "ambiguous-session-child-run",
                    "parentSessionId": "shared-parent-session",
                    "parentRunId": "other-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 160.0,
                    "updatedAt": 160.0,
                ],
                "shared-run-a": [
                    "sessionId": "shared-run-parent-a",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-shared-run-a",
                    "runId": "shared-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 170.0,
                    "updatedAt": 170.0,
                ],
                "shared-run-b": [
                    "sessionId": "shared-run-parent-b",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-shared-run-b",
                    "runId": "shared-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 180.0,
                    "updatedAt": 180.0,
                ],
                "ambiguous-run-child": [
                    "sessionId": "ambiguous-run-child",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-ambiguous-run-child",
                    "runId": "ambiguous-run-child-run",
                    "parentSessionId": "other-parent",
                    "parentRunId": "shared-parent-run",
                    "restoreAuthority": true,
                    "startedAt": 190.0,
                    "updatedAt": 190.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": [
                "surface-parent",
                "surface-child",
                "surface-grandchild",
                "surface-other",
                "surface-conflict",
                "surface-shared-session-a",
                "surface-shared-session-b",
                "surface-ambiguous-session-child",
                "surface-shared-run-a",
                "surface-shared-run-b",
                "surface-ambiguous-run-child",
            ],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "tree", "--agent", "codex", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(payload["nodes"] as? [[String: Any]])
        let edges = try #require(payload["edges"] as? [[String: Any]])
        #expect(nodes.contains { $0["session_id"] as? String == "hidden-parent" })
        #expect(edges.contains {
            $0["from_session_id"] as? String == "hidden-parent"
                && $0["to_session_id"] as? String == "visible-child"
        })
        #expect(!edges.contains { $0["to_session_id"] as? String == "conflicting-child" })
        #expect(!edges.contains { $0["to_session_id"] as? String == "ambiguous-session-child" })
        #expect(!edges.contains { $0["to_session_id"] as? String == "ambiguous-run-child" })

        let depthResult = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "tree", "--agent", "codex", "--depth", "1"],
            environment: environment,
            timeout: 5
        )
        #expect(depthResult.status == 0, Comment(rawValue: depthResult.stdout))
        #expect(depthResult.stdout.contains("hidden-parent"))
        #expect(depthResult.stdout.contains("visible-child"))
        #expect(!depthResult.stdout.contains("visible-grandchild"))
    }

    @Test func agentsTreeRejectsBlankAgentValues() throws {
        let cliPath = try bundledCLIPath()
        let responder = try agentsInstanceResponder(workspaces: [:])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "tree", "--agent=  ", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status != 0)
        #expect(result.stdout.contains("--agent requires a value"), Comment(rawValue: result.stdout))
    }

    @Test func agentsListExcludesSessionsOwnedByAnotherCmuxInstance() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-instance-scope-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "activeSessionsByWorkspace": [
                "workspace-foreign": [
                    "sessionId": "foreign-session",
                    "updatedAt": 200.0,
                ],
            ],
            "activeSessionsBySurface": [
                "surface-foreign": [
                    "sessionId": "foreign-session",
                    "updatedAt": 200.0,
                ],
            ],
            "sessions": [
                "foreign-session": [
                    "sessionId": "foreign-session",
                    "workspaceId": "workspace-foreign",
                    "surfaceId": "surface-foreign",
                    "runtimeStatus": "running",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        let socketPath = "/tmp/cmux-agents-scope-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"windows":[{"id":"window-local","workspaces":[{"id":"workspace-local","panes":[{"id":"pane-local","surfaces":[{"id":"surface-local","type":"terminal"}]}]}]}]}}"#
        )
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "agents", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(sessions.isEmpty)
        let stores = try #require(payload["stores"] as? [[String: Any]])
        #expect(stores.first?["session_count"] as? Int == 0)

        let treeResult = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "agents", "tree", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        #expect(treeResult.status == 0, Comment(rawValue: treeResult.stdout))
        let treePayload = try #require(
            JSONSerialization.jsonObject(with: Data(treeResult.stdout.utf8)) as? [String: Any]
        )
        let nodes = try #require(treePayload["nodes"] as? [[String: Any]])
        #expect(nodes.isEmpty)
        #expect(responder.receivedRequests.filter { $0.contains("system.tree") }.count == 2)
    }

    @Test func agentsListProvidesVersionedInstanceScopedSessionInspection() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-list-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "activeSessionsByWorkspace": [
                "workspace-root": [
                    "sessionId": "root-session",
                    "updatedAt": 200.0,
                ],
            ],
            "activeSessionsBySurface": [
                "surface-root": [
                    "sessionId": "root-session",
                    "updatedAt": 200.0,
                ],
            ],
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-root",
                    "cwd": "/tmp/cmux/root",
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-root"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "list", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(payload["schema_version"] as? Int == 2)
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions.first?["agent"] as? String == "codex")
        #expect(sessions.first?["session_id"] as? String == "root-session")
    }

    @Test func agentsOptionsDefaultToListAndNormalizeBlankRunID() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-options-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-root",
                    "runId": "  ",
                    "parentRunId": "  ",
                    "parentSessionId": "  ",
                    "relationship": "  ",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-root"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(sessions.first?["run_id"] as? String == "root-session")
        #expect(sessions.first?["parent_run_id"] is NSNull)
        #expect(sessions.first?["parent_session_id"] is NSNull)
        #expect(sessions.first?["relationship"] is NSNull)
    }

    @Test func agentsTreeBuildsRelationshipsFromSavedSessionMetadata() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-root",
                    "runId": "root-run",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
                "child-session": [
                    "sessionId": "child-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-child",
                    "runId": "child-run",
                    "parentRunId": "root-run",
                    "parentSessionId": "root-session",
                    "relationship": "spawned",
                    "restoreAuthority": false,
                    "startedAt": 120.0,
                    "updatedAt": 180.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-root", "surface-child"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "tree", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(payload["schema_version"] as? Int == 2)
        let nodes = try #require(payload["nodes"] as? [[String: Any]])
        let edges = try #require(payload["edges"] as? [[String: Any]])
        #expect(Set(nodes.compactMap { $0["run_id"] as? String }) == ["root-run", "child-run"])
        #expect(edges.count == 1)
        #expect(edges.first?["from_run_id"] as? String == "root-run")
        #expect(edges.first?["to_run_id"] as? String == "child-run")
        #expect(edges.first?["relationship"] as? String == "spawned")
    }

    @Test func agentsTreeTextUsesEdgeRelationshipWhenRecordOmitsIt() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-text-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "root-session": [
                    "sessionId": "root-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-root",
                    "runId": "root-run",
                    "restoreAuthority": true,
                    "startedAt": 100.0,
                    "updatedAt": 200.0,
                ],
                "child-session": [
                    "sessionId": "child-session",
                    "workspaceId": "workspace-root",
                    "surfaceId": "surface-child",
                    "runId": "child-run",
                    "parentRunId": "root-run",
                    "restoreAuthority": false,
                    "startedAt": 120.0,
                    "updatedAt": 180.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": ["surface-root", "surface-child"],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "tree", "--agent", "codex", "--all"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("root codex root-session"))
        #expect(result.stdout.contains("spawned codex child-session"))
        #expect(!result.stdout.contains("root codex child-session"))
    }

    @Test func agentsTreeRejectsAmbiguousRunParentsAndNormalizesBlankRelationships() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-tree-ambiguous-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func record(
            sessionID: String,
            runID: String,
            parentRunID: String? = nil,
            relationship: String? = nil,
            startedAt: Double
        ) -> [String: Any] {
            var value: [String: Any] = [
                "sessionId": sessionID,
                "workspaceId": "workspace-root",
                "surfaceId": "surface-\(sessionID)",
                "runId": runID,
                "restoreAuthority": true,
                "startedAt": startedAt,
                "updatedAt": startedAt,
            ]
            if let parentRunID { value["parentRunId"] = parentRunID }
            if let relationship { value["relationship"] = relationship }
            return value
        }

        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                "parent-a": record(sessionID: "parent-a", runID: "duplicate-run", startedAt: 100),
                "parent-b": record(sessionID: "parent-b", runID: "duplicate-run", startedAt: 110),
                "ambiguous-child": record(
                    sessionID: "ambiguous-child",
                    runID: "ambiguous-child-run",
                    parentRunID: "duplicate-run",
                    startedAt: 120
                ),
                "unique-parent": record(sessionID: "unique-parent", runID: "unique-run", startedAt: 130),
                "unique-child": record(
                    sessionID: "unique-child",
                    runID: "unique-child-run",
                    parentRunID: "unique-run",
                    relationship: "  ",
                    startedAt: 140
                ),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
        let responder = try agentsInstanceResponder(workspaces: [
            "workspace-root": [
                "surface-parent-a",
                "surface-parent-b",
                "surface-ambiguous-child",
                "surface-unique-parent",
                "surface-unique-child",
            ],
        ])
        defer { responder.stop() }

        var environment = agentsTestEnvironment()
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", responder.path, "agents", "tree", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let edges = try #require(payload["edges"] as? [[String: Any]])
        #expect(!edges.contains { $0["to_session_id"] as? String == "ambiguous-child" })
        let uniqueEdge = try #require(edges.first { $0["to_session_id"] as? String == "unique-child" })
        #expect(uniqueEdge["relationship"] as? String == "spawned")
    }

    @Test func testSessionsListDefaultOmitsStaleCodexRowsWithoutTranscript() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let activeSessionId = "019ef6ac-e358-7dd2-902d-8492fa0ba2bb"
        let staleSessionId = "019ef5c3-e0a1-7473-a6bf-48bbcf234de0"
        let launchBackedSessionId = "019ef7b0-9c49-700b-9a8c-e831d7d1af3a"
        let savedTranscriptSessionId = "019ef8ac-840d-75bc-ae10-f2e992d05fab"
        let savedTranscript = root.appendingPathComponent("saved-codex-transcript.jsonl", isDirectory: false)
        try #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
            .write(to: savedTranscript, atomically: true, encoding: .utf8)
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsByWorkspace": [
                "workspace-active": [
                    "sessionId": activeSessionId,
                    "updatedAt": 1_782_255_000.0
                ]
            ],
            "activeSessionsBySurface": [
                "surface-active": [
                    "sessionId": activeSessionId,
                    "updatedAt": 1_782_255_000.0
                ]
            ],
            "sessions": [
                activeSessionId: [
                    "sessionId": activeSessionId,
                    "workspaceId": "workspace-active",
                    "surfaceId": "surface-active",
                    "cwd": "/tmp/cmux/active",
                    "startedAt": 1_782_254_900.0,
                    "updatedAt": 1_782_255_000.0
                ],
                staleSessionId: [
                    "sessionId": staleSessionId,
                    "workspaceId": "workspace-stale",
                    "surfaceId": "surface-stale",
                    "cwd": "/tmp/cmux/stale",
                    "startedAt": 1_782_254_950.0,
                    "updatedAt": 1_782_255_010.0
                ],
                launchBackedSessionId: [
                    "sessionId": launchBackedSessionId,
                    "workspaceId": "workspace-launch-backed",
                    "surfaceId": "surface-launch-backed",
                    "cwd": "/tmp/cmux/launch-backed",
                    "startedAt": 1_782_254_960.0,
                    "updatedAt": 1_782_255_020.0,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--yolo"],
                        "workingDirectory": "/tmp/cmux/launch-backed",
                        "capturedAt": 1_782_254_960.0,
                        "source": "process",
                    ],
                ],
                savedTranscriptSessionId: [
                    "sessionId": savedTranscriptSessionId,
                    "workspaceId": "workspace-saved-transcript",
                    "surfaceId": "surface-saved-transcript",
                    "cwd": "/tmp/cmux/saved-transcript",
                    "transcriptPath": savedTranscript.path,
                    "startedAt": 1_782_254_970.0,
                    "updatedAt": 1_782_255_030.0
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = agentsTestEnvironment()
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let defaultResult = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(defaultResult.timedOut, defaultResult.stdout)
        XCTAssertEqual(defaultResult.status, 0, defaultResult.stdout)
        let defaultOutputData = try XCTUnwrap(defaultResult.stdout.data(using: .utf8))
        let defaultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: defaultOutputData) as? [String: Any])
        XCTAssertEqual(defaultObject["total_matches"] as? Int, 3)
        let defaultSessions = try XCTUnwrap(defaultObject["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(defaultSessions.compactMap { $0["session_id"] as? String }), [activeSessionId, launchBackedSessionId, savedTranscriptSessionId])
        XCTAssertEqual(defaultSessions.first { $0["session_id"] as? String == launchBackedSessionId }?["launch_backed"] as? Bool, true)
        XCTAssertEqual(defaultSessions.first { $0["session_id"] as? String == savedTranscriptSessionId }?["transcript_backed"] as? Bool, true)

        let cwdResult = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--cwd", "/tmp/cmux", "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(cwdResult.timedOut, cwdResult.stdout)
        XCTAssertEqual(cwdResult.status, 0, cwdResult.stdout)
        let cwdOutputData = try XCTUnwrap(cwdResult.stdout.data(using: .utf8))
        let cwdObject = try XCTUnwrap(JSONSerialization.jsonObject(with: cwdOutputData) as? [String: Any])
        XCTAssertEqual(cwdObject["total_matches"] as? Int, 4)
        let cwdSessions = try XCTUnwrap(cwdObject["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(cwdSessions.compactMap { $0["session_id"] as? String }), [activeSessionId, staleSessionId, launchBackedSessionId, savedTranscriptSessionId])

        let allResult = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--all", "--json"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(allResult.timedOut, allResult.stdout)
        XCTAssertEqual(allResult.status, 0, allResult.stdout)
        let allOutputData = try XCTUnwrap(allResult.stdout.data(using: .utf8))
        let allObject = try XCTUnwrap(JSONSerialization.jsonObject(with: allOutputData) as? [String: Any])
        XCTAssertEqual(allObject["total_matches"] as? Int, 4)
        let allSessions = try XCTUnwrap(allObject["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(allSessions.compactMap { $0["session_id"] as? String }), [activeSessionId, staleSessionId, launchBackedSessionId, savedTranscriptSessionId])
    }

    @Test func testSessionsListReportsCodexIdsMissingFromCodexStore() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sessions-list-\(UUID().uuidString)", isDirectory: true)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019ee74a-3c84-7de3-84f1-ece32f4ecfbb"
        let workspaceId = "workspace-debug"
        let surfaceId = "surface-debug"
        let store: [String: Any] = [
            "version": 1,
            "activeSessionsByWorkspace": [
                workspaceId: [
                    "sessionId": sessionId,
                    "updatedAt": 1_781_996_867.0
                ]
            ],
            "activeSessionsBySurface": [
                surfaceId: [
                    "sessionId": sessionId,
                    "updatedAt": 1_781_996_867.0
                ]
            ],
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId,
                    "surfaceId": surfaceId,
                    "cwd": "/tmp/cmux/debug",
                    "startedAt": 1_781_996_800.0,
                    "updatedAt": 1_781_996_867.0
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)

        var environment = agentsTestEnvironment()
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = stateDir.path
        environment["CODEX_HOME"] = codexHome.path

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["sessions", "list", "--agent", "codex", "--session", sessionId, "--json"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        let outputData = try #require(result.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: outputData) as? [String: Any])
        #expect(object["total_matches"] as? Int == 1)
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["session_id"] as? String == sessionId)
        #expect(session["workspace_id"] as? String == workspaceId)
        #expect(session["surface_id"] as? String == surfaceId)
        #expect(session["active_for_workspace"] as? Bool == true)
        #expect(session["active_for_surface"] as? Bool == true)
        #expect(session["codex_indexed"] as? Bool == false)
        #expect(session["codex_transcript_found"] as? Bool == false)
        #expect(session["session_home"] as? String == codexHome.path)
    }

    private func agentsTestEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func agentsInstanceResponder(
        workspaces: [String: [String]]
    ) throws -> UnixSocketResponder {
        let workspacePayloads = workspaces.keys.sorted().map { workspaceID in
            [
                "id": workspaceID,
                "panes": [[
                    "id": "pane-\(workspaceID)",
                    "surfaces": (workspaces[workspaceID] ?? []).sorted().map { surfaceID in
                        ["id": surfaceID, "type": "terminal"]
                    },
                ]],
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "ok": true,
            "result": [
                "windows": [[
                    "id": "window-local",
                    "workspaces": workspacePayloads,
                ]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = String(decoding: data, as: UTF8.self)
        return try UnixSocketResponder(
            path: "/tmp/cmux-agents-scope-\(UUID().uuidString.prefix(8)).sock",
            response: response
        )
    }

}
