import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryObservationReviewRegressionTests {
    @Test func mobileChatObserverPrefersRealClaudeChildForSameSession() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 101,
                    parentPID: 10,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
                topProcess(
                    pid: 202,
                    parentPID: 101,
                    name: "claude",
                    path: "/Users/example/.claude/local/claude",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 101),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                switch pid {
                case 101:
                    CmuxTopProcessArguments(
                        arguments: [
                            "node",
                            "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                        ],
                        environment: [
                            "CMUX_AGENT_LAUNCH_KIND": "claude",
                            "CLAUDE_CODE_SESSION_ID": sessionID,
                            "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project",
                        ]
                    )
                case 202:
                    CmuxTopProcessArguments(
                        arguments: ["claude"],
                        environment: [
                            "CLAUDE_CODE_SESSION_ID": sessionID,
                            "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project",
                        ]
                    )
                default:
                    nil
                }
            },
            codexRolloutPaths: { _ in [] }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.pid == 202)
    }

    @Test func mobileChatObserverIgnoresInheritedLaunchKindOnChildTool() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 101,
                    parentPID: 10,
                    name: "claude",
                    path: "/opt/homebrew/bin/claude",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 101,
                    terminalProcessGroupID: 101
                ),
                topProcess(
                    pid: 202,
                    parentPID: 101,
                    name: "git",
                    path: "/usr/bin/git",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 101,
                    terminalProcessGroupID: 101
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 102),
            includesProcessDetails: true
        )

        let details: (Int) -> CmuxTopProcessArguments? = { pid in
            switch pid {
            case 101:
                CmuxTopProcessArguments(
                    arguments: ["claude"],
                    environment: ["CLAUDE_CODE_SESSION_ID": sessionID]
                )
            case 202:
                CmuxTopProcessArguments(
                    arguments: ["git", "status"],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                    ]
                )
            default:
                nil
            }
        }

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: details,
            codexRolloutPaths: { _ in [] }
        )
        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [sessionID],
            processArgumentsAndEnvironment: details
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.pid == 101)
        #expect(livePID == 101)
    }

    @Test func mobileChatObserverDetectsHostedClaudeUnderScopedShellRoot() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 101,
                    parentPID: 10,
                    name: "zsh",
                    path: "/bin/zsh",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 101,
                    terminalProcessGroupID: 202
                ),
                topProcess(
                    pid: 202,
                    parentPID: 101,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 202,
                    terminalProcessGroupID: 202
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 124),
            includesProcessDetails: true
        )
        let details: (Int) -> CmuxTopProcessArguments? = { pid in
            switch pid {
            case 101:
                CmuxTopProcessArguments(arguments: ["-zsh"], environment: [:])
            case 202:
                CmuxTopProcessArguments(
                    arguments: [
                        "node",
                        "/Users/example/.cmux-agent-wrapper/subrouter.js",
                    ],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                    ]
                )
            default:
                nil
            }
        }

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: details,
            codexRolloutPaths: { _ in [] }
        )
        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [sessionID],
            processArgumentsAndEnvironment: details
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.pid == 202)
        #expect(livePID == 202)
    }

    @Test func mobileChatObserverIgnoresInheritedLaunchKindOnUnrelatedForegroundChild() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 101,
                    parentPID: 10,
                    name: "zsh",
                    path: "/bin/zsh",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 101,
                    terminalProcessGroupID: 202
                ),
                topProcess(
                    pid: 202,
                    parentPID: 101,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    processGroupID: 202,
                    terminalProcessGroupID: 202
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 125),
            includesProcessDetails: true
        )
        let details: (Int) -> CmuxTopProcessArguments? = { pid in
            switch pid {
            case 101:
                CmuxTopProcessArguments(arguments: ["-zsh"], environment: [:])
            case 202:
                CmuxTopProcessArguments(
                    arguments: ["node", "server.js"],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                    ]
                )
            default:
                nil
            }
        }

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: details,
            codexRolloutPaths: { _ in [] }
        )
        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [sessionID],
            processArgumentsAndEnvironment: details
        )

        #expect(observed.isEmpty)
        #expect(livePID == nil)
    }

    @Test func mobileChatObserverUsesPendingAliasForClaudeForkResumeParent() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let parentSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let pendingSessionID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID.uuidString)
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(pid: 303, parentPID: 101, name: "claude", path: "/opt/homebrew/bin/claude", workspaceID: workspaceID, surfaceID: surfaceID),
            ],
            sampledAt: Date(timeIntervalSince1970: 303),
            includesProcessDetails: true
        )
        let details: (Int) -> CmuxTopProcessArguments? = { pid in
            guard pid == 303 else { return nil }
            return CmuxTopProcessArguments(
                arguments: ["claude", "--resume", parentSessionID, "--fork-session=true"],
                environment: ["CLAUDE_CODE_SESSION_ID": parentSessionID, "CMUX_AGENT_LAUNCH_CWD": "/Users/example/project"]
            )
        }

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(in: snapshot, processArgumentsAndEnvironment: details, codexRolloutPaths: { _ in [] })
        let liveParentPID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [parentSessionID],
            processArgumentsAndEnvironment: details
        )
        let livePendingPID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [pendingSessionID],
            allowUnidentifiedFallback: true,
            processArgumentsAndEnvironment: details
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == pendingSessionID)
        #expect(session.agentKind == .claude)
        #expect(session.pid == 303)
        #expect(liveParentPID == nil)
        #expect(livePendingPID == 303)
    }

    @Test func mobileChatObserverDetectsClaudeExeRuntimeProcess() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "1258bb73-b1b8-469e-910a-61266f4dfc44"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 96441,
                    parentPID: 93888,
                    name: "claude.exe",
                    path: "/Users/example/.local/share/claude/versions/2.1.199/claude.exe",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 1258),
            includesProcessDetails: true
        )
        let details: (Int) -> CmuxTopProcessArguments? = { pid in
            guard pid == 96441 else { return nil }
            return CmuxTopProcessArguments(
                arguments: ["claude.exe"],
                environment: [
                    "CLAUDE_CODE_SESSION_ID": sessionID,
                    "PWD": "/Users/example/project",
                ]
            )
        }

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: details,
            codexRolloutPaths: { _ in [] }
        )
        let livePID = AgentChatSessionRegistry.liveAgentPID(
            in: snapshot,
            surfaceID: surfaceID.uuidString,
            kind: .claude,
            matchingSessionIDs: [sessionID],
            processArgumentsAndEnvironment: details
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.agentKind == .claude)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 96441)
        #expect(session.workingDirectory == "/Users/example/project")
        #expect(livePID == 96441)
    }

    @Test func mobileChatObserverCreatesPendingClaudeExeWhenSessionIdentityIsUnavailable() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 54045,
                    parentPID: 51297,
                    name: "claude.exe",
                    path: "/Users/example/.local/share/claude/versions/2.1.199/claude.exe",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 540),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { _ in nil },
            codexRolloutPaths: { _ in [] }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID.uuidString))
        #expect(session.agentKind == .claude)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 54045)
        #expect(session.workingDirectory == nil)
    }

    @Test func canceledObservationScanReturnsBeforeProcessDetailReads() async {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let detailReads = LockedCounter()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 7001,
                    parentPID: 7000,
                    name: "claude.exe",
                    path: "/Users/example/.local/share/claude/versions/2.1.199/claude.exe",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 7001),
            includesProcessDetails: true
        )

        let scan = Task.detached {
            try? await Task.sleep(for: .milliseconds(10))
            return AgentChatSessionRegistry.scanObservedAgentSessions(
                in: snapshot,
                processArgumentsAndEnvironment: { _ in
                    detailReads.increment()
                    return CmuxTopProcessArguments(arguments: ["claude.exe"], environment: [:])
                },
                codexRolloutPaths: { _ in [] }
            )
        }
        scan.cancel()

        let observed = await scan.value
        #expect(observed.isEmpty)
        #expect(detailReads.value == 0)
    }

    @Test func reviewPatchHeadersCannotCrossTheSelectedFile() {
        let root = "/tmp/cmux-review"
        let declared = URL(fileURLWithPath: root).appendingPathComponent("Sources/Retry.swift")
        let matching = """
        diff --git a/Sources/Retry.swift b/Sources/Retry.swift
        --- a/Sources/Retry.swift
        +++ b/Sources/Retry.swift
        @@ -1 +1 @@
        -old
        +new
        """
        let crossFile = matching.replacingOccurrences(
            of: "b/Sources/Retry.swift",
            with: "b/Sources/Other.swift"
        )

        #expect(TerminalController.chatReviewPatchMatchesPath(
            matching,
            declaredPath: declared,
            workingDirectory: root
        ))
        #expect(!TerminalController.chatReviewPatchMatchesPath(
            crossFile,
            declaredPath: declared,
            workingDirectory: root
        ))
    }

    @Test func reviewPathRejectsSymlinkThatEscapesWorkspace() throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-review-\(UUID().uuidString)")
        let outsideURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-review-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        let outsideFile = outsideURL.appendingPathComponent("secret.swift")
        try Data("secret".utf8).write(to: outsideFile)
        let link = rootURL.appendingPathComponent("Sources")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideURL)

        let escaped = rootURL.appendingPathComponent("Sources/secret.swift")
        let patch = """
        diff --git a/Sources/secret.swift b/Sources/secret.swift
        --- a/Sources/secret.swift
        +++ b/Sources/secret.swift
        @@ -1 +1 @@
        -secret
        +changed
        """
        #expect(!TerminalController.chatReviewPatchMatchesPath(
            patch,
            declaredPath: escaped,
            workingDirectory: rootURL.path
        ))
    }

    private func topProcess(
        pid: Int,
        parentPID: Int,
        name: String,
        path: String?,
        workspaceID: UUID,
        surfaceID: UUID,
        processGroupID: Int? = nil,
        terminalProcessGroupID: Int? = nil
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: surfaceID,
            cmuxAttributionReason: "test",
            processGroupID: processGroupID ?? pid,
            terminalProcessGroupID: terminalProcessGroupID ?? pid,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
