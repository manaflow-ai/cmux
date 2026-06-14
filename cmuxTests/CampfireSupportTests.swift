import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Campfire support")
struct CampfireSupportTests {
    @Test func directProcessDetectionUsesExplicitSessionSelectorsBeforeLatestFallback() throws {
        struct Selector {
            let name: String
            let arguments: [String]
        }

        let selectors = [
            Selector(name: "--session value", arguments: ["--session", "explicit-campfire-session"]),
            Selector(name: "--session=value", arguments: ["--session=explicit-campfire-session"]),
        ]

        for selector in selectors {
            let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-explicit-")
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = root.appendingPathComponent("repo", isDirectory: true)
            let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
            let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
            let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let explicit = try Self.writeSessionFile(
                id: "explicit-campfire-session",
                in: projectSessions,
                modifiedAt: Date(timeIntervalSince1970: 1_000)
            )
            let latest = try Self.writeSessionFile(
                id: "latest-campfire-session",
                in: projectSessions,
                modifiedAt: Date(timeIntervalSince1970: 2_000)
            )

            let selectorComment = Comment(rawValue: selector.name)
            let detected = try #require(Self.detectedCampfireSnapshot(
                arguments: ["/Users/example/.local/bin/campfire"] + selector.arguments,
                environment: [
                    "PWD": workspace.path,
                    "CAMPFIRE_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
                ]
            ), selectorComment)

            #expect(detected.kind == RestorableAgentKind.custom("campfire"), selectorComment)
            #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(explicit.path), selectorComment)
            #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(latest.path), selectorComment)
            #expect(detected.workingDirectory == workspace.path, selectorComment)
        }
    }

    @Test func directProcessDetectionUsesCampfireAgentDirectorySessionsWhenNoSessionDirectoryIsSet() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-agent-dir-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let agentRoot = root.appendingPathComponent("campfire-agent", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = agentRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let latest = try Self.writeSessionFile(
            id: "campfire-agent-dir-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedCampfireSnapshot(
            arguments: ["/Users/example/.local/bin/campfire"],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_DIR": agentRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("campfire"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(latest.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func directProcessDetectionIgnoresPiSessionDirForCampfire() throws {
        // Campfire embeds Pi, so a Campfire process can inherit
        // PI_CODING_AGENT_SESSION_DIR from the user's Pi configuration. Session
        // detection must still resolve Campfire sessions against the
        // Campfire-specific directory, not the Pi one.
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-pi-precedence-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let piSessionsRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        let piProjectSessions = piSessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: piProjectSessions, withIntermediateDirectories: true)
        let piSession = try Self.writeSessionFile(
            id: "pi-session",
            in: piProjectSessions,
            modifiedAt: Date(timeIntervalSince1970: 5_000)
        )

        let campfireSessionsRoot = root.appendingPathComponent("campfire-sessions", isDirectory: true)
        let campfireProjectSessions = campfireSessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: campfireProjectSessions, withIntermediateDirectories: true)
        let campfireSession = try Self.writeSessionFile(
            id: "campfire-session",
            in: campfireProjectSessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        let detected = try #require(Self.detectedCampfireSnapshot(
            arguments: ["/Users/example/.local/bin/campfire"],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_SESSION_DIR": piSessionsRoot.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": campfireSessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("campfire"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(campfireSession.path))
        #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(piSession.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func taskManagerClassifiesCampfireCompiledBinaryAndDevInvocation() throws {
        let compiled = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "campfire",
            processPath: "/Users/example/.local/bin/campfire",
            arguments: ["/Users/example/.local/bin/campfire", "--relay", "wss://relay.example/ws"],
            environment: [:]
        ))
        #expect(compiled.id == "campfire")

        let dev = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "bun",
            processPath: "/opt/homebrew/bin/bun",
            arguments: [
                "/opt/homebrew/bin/bun",
                "/Users/example/campfire/packages/session/bin/campfire.ts",
            ],
            environment: [:]
        ))
        #expect(dev.id == "campfire")
    }

    @Test func builtInCampfireRegistrationResumesWithBareSessionId() throws {
        let registration = CmuxVaultAgentRegistration.builtInCampfire
        #expect(registration.id == "campfire")
        #expect(registration.resumeCommand == "{{executable}} --session {{sessionId}}")
        #expect(registration.sessionDirectory == "~/.campfire/agent/sessions")
    }

    private static func detectedCampfireSnapshot(
        processName: String = "campfire",
        processPath: String? = "/Users/example/.local/bin/campfire",
        arguments: [String],
        environment: [String: String],
        registration: CmuxVaultAgentRegistration = .builtInCampfire
    ) -> SessionRestorableAgentSnapshot? {
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let processId = 4243
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: processName,
                    path: processPath,
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: [registration]),
            fileManager: FileManager.default,
            processSnapshot: processSnapshot,
            capturedAt: 42,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(arguments: arguments, environment: environment)
            }
        )[panelKey]?.snapshot
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeSessionFile(id: String, in directory: URL, modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent("\(id).jsonl", isDirectory: false)
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }
}
