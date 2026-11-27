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

            _ = try Self.writeSessionFile(
                id: "explicit-campfire-session",
                in: projectSessions,
                modifiedAt: Date(timeIntervalSince1970: 1_000)
            )
            _ = try Self.writeSessionFile(
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
            #expect(detected.sessionId == "explicit-campfire-session", selectorComment)
            #expect(detected.workingDirectory == workspace.path, selectorComment)
        }
    }

    @Test func directProcessDetectionIgnoresCampfireAgentDirectoryWithoutSessionSelector() throws {
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

        _ = try Self.writeSessionFile(
            id: "campfire-agent-dir-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = Self.detectedCampfireSnapshot(
            arguments: ["/Users/example/.local/bin/campfire"],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_DIR": agentRoot.path,
            ]
        )

        #expect(detected == nil)
    }

    @Test func directProcessDetectionIgnoresSessionDirectoriesForExplicitCampfireId() throws {
        // Campfire embeds Pi, so a Campfire process can inherit
        // PI_CODING_AGENT_SESSION_DIR from the user's Pi configuration. Session
        // detection must not bind either directory by latest-file heuristic.
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
            arguments: ["/Users/example/.local/bin/campfire", "--session", "campfire-session"],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_SESSION_DIR": piSessionsRoot.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": campfireSessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("campfire"))
        #expect(detected.sessionId == "campfire-session")
        #expect(detected.sessionId != campfireSession.path)
        #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(piSession.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func directProcessDetectionClassifiesCampfireDevInvocation() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-dev-invocation-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        _ = try Self.writeSessionFile(
            id: "campfire-dev-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedCampfireSnapshot(
            processName: "bun",
            processPath: "/opt/homebrew/bin/bun",
            arguments: [
                "/opt/homebrew/bin/bun",
                "/Users/example/campfire/packages/session/bin/campfire.ts",
                "--session",
                "campfire-dev-session",
            ],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("campfire"))
        #expect(detected.sessionId == "campfire-dev-session")
        #expect(detected.workingDirectory == workspace.path)
        #expect(detected.launchCommand?.executablePath == "campfire")
        #expect(detected.resumeCommand?.contains("'campfire' '--session'") == true)
        #expect(detected.resumeCommand?.contains("/opt/homebrew/bin/bun") == false)
    }

    @Test func directProcessDetectionDropsCampfireBunfsEntrypointAndPreservesFlags() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-bunfs-invocation-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        _ = try Self.writeSessionFile(
            id: "campfire-bunfs-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedCampfireSnapshot(
            processName: "campfire",
            processPath: "/Users/example/.local/bin/campfire",
            arguments: [
                "/Users/example/.local/bin/campfire",
                "/$bunfs/root/campfire",
                "--session",
                "campfire-bunfs-session",
                "--relay",
                "wss://relay.example/ws",
            ],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("campfire"))
        #expect(detected.sessionId == "campfire-bunfs-session")
        #expect(detected.launchCommand?.arguments == [
            "/Users/example/.local/bin/campfire",
            "--session",
            "campfire-bunfs-session",
            "--relay",
            "wss://relay.example/ws",
        ])
        #expect(detected.resumeCommand?.contains("$bunfs") == false)
        #expect(detected.resumeCommand?.contains("'--relay' 'wss://relay.example/ws'") == true)
    }

    @Test func directProcessDetectionDropsCampfireRuntimePrefixAndPreservesFlags() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-runtime-prefix-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        _ = try Self.writeSessionFile(
            id: "campfire-runtime-prefix-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedCampfireSnapshot(
            processName: "node",
            processPath: "/opt/homebrew/bin/node",
            arguments: [
                "/opt/homebrew/bin/node",
                "--import",
                "./loader.mjs",
                "/Users/example/campfire/packages/session/bin/campfire.ts",
                "--session",
                "campfire-runtime-prefix-session",
                "--relay",
                "wss://relay.example/ws",
            ],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.sessionId == "campfire-runtime-prefix-session")
        #expect(detected.launchCommand?.arguments == [
            "campfire",
            "--session",
            "campfire-runtime-prefix-session",
            "--relay",
            "wss://relay.example/ws",
        ])
        #expect(detected.resumeCommand?.contains("'--import'") == false)
        #expect(detected.resumeCommand?.contains("'./loader.mjs'") == false)
        #expect(detected.resumeCommand?.contains("'--relay' 'wss://relay.example/ws'") == true)
    }

    @Test func campfireRegistrationOverrideKeepsConfiguredResumeCommand() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-override-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        _ = try Self.writeSessionFile(
            id: "campfire-override-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )
        var registration = CmuxVaultAgentRegistration.builtInCampfire
        registration.resumeCommand = "custom-campfire restore {{sessionId}}"

        let detected = try #require(Self.detectedCampfireSnapshot(
            arguments: [
                "/Users/example/.local/bin/campfire",
                "/$bunfs/root/campfire",
                "--session",
                "campfire-override-session",
                "--relay",
                "wss://relay.example/ws",
            ],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ],
            registration: registration
        ))

        #expect(detected.sessionId == "campfire-override-session")
        #expect(detected.resumeCommand?.contains("'custom-campfire' 'restore'") == true)
        #expect(detected.resumeCommand?.contains("'campfire' '--session'") == false)
    }

    @Test func campfireRegistrationOverrideStillNormalizesRuntimeLaunchArguments() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-override-runtime-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        _ = try Self.writeSessionFile(
            id: "campfire-override-runtime-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )
        var registration = CmuxVaultAgentRegistration.builtInCampfire
        registration.resumeCommand = "custom-campfire restore {{sessionId}}"

        let detected = try #require(Self.detectedCampfireSnapshot(
            processName: "node",
            processPath: "/opt/homebrew/bin/node",
            arguments: [
                "/opt/homebrew/bin/node",
                "/Users/example/campfire/packages/session/bin/campfire.ts",
                "--session",
                "campfire-override-runtime-session",
                "--relay",
                "wss://relay.example/ws",
            ],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ],
            registration: registration
        ))

        #expect(detected.sessionId == "campfire-override-runtime-session")
        #expect(detected.launchCommand?.arguments == [
            "campfire",
            "--session",
            "campfire-override-runtime-session",
            "--relay",
            "wss://relay.example/ws",
        ])
        #expect(detected.resumeCommand?.contains("/opt/homebrew/bin/node") == false)
        #expect(detected.resumeCommand?.contains("packages/session/bin/campfire.ts") == false)
    }

    @Test func directProcessDetectionClassifiesCampfireDistInvocation() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-campfire-dist-invocation-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        _ = try Self.writeSessionFile(
            id: "campfire-dist-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedCampfireSnapshot(
            processName: "bun",
            processPath: "/opt/homebrew/bin/bun",
            arguments: [
                "/opt/homebrew/bin/bun",
                "/Users/example/campfire/packages/session/dist/campfire",
                "--session",
                "campfire-dist-session",
            ],
            environment: [
                "PWD": workspace.path,
                "CAMPFIRE_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("campfire"))
        #expect(detected.sessionId == "campfire-dist-session")
        #expect(detected.workingDirectory == workspace.path)
    }

}
