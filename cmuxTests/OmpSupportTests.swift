import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("OMP support")
struct OmpSupportTests {
    @Test func directProcessDetectionUsesExplicitSessionSelectorsBeforeLatestFallback() throws {
        struct Selector {
            let name: String
            let arguments: [String]
        }

        let selectors = [
            Selector(name: "--session value", arguments: ["--session", "explicit-omp-session"]),
            Selector(name: "--session=value", arguments: ["--session=explicit-omp-session"]),
            Selector(name: "--resume value", arguments: ["--resume", "explicit-omp-session"]),
            Selector(name: "--resume=value", arguments: ["--resume=explicit-omp-session"]),
            Selector(name: "-r value", arguments: ["-r", "explicit-omp-session"]),
            Selector(name: "-r=value", arguments: ["-r=explicit-omp-session"]),
        ]

        for selector in selectors {
            let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-explicit-")
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = root.appendingPathComponent("repo", isDirectory: true)
            let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
            let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
            let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let explicit = try Self.writeSessionFile(
                id: "explicit-omp-session",
                in: projectSessions,
                modifiedAt: Date(timeIntervalSince1970: 1_000)
            )
            let latest = try Self.writeSessionFile(
                id: "latest-omp-session",
                in: projectSessions,
                modifiedAt: Date(timeIntervalSince1970: 2_000)
            )
            let partial = try Self.writeSessionFile(
                id: "prefix-explicit-omp-session-suffix",
                in: projectSessions,
                modifiedAt: Date(timeIntervalSince1970: 3_000)
            )

            let selectorComment = Comment(rawValue: selector.name)
            let detected = try #require(Self.detectedOmpSnapshot(
                arguments: ["/Users/example/.bun/bin/omp"] + selector.arguments,
                environment: [
                    "PWD": workspace.path,
                    "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
                ]
            ), selectorComment)

            #expect(detected.kind == RestorableAgentKind.custom("omp"), selectorComment)
            #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(explicit.path), selectorComment)
            #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(latest.path), selectorComment)
            #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(partial.path), selectorComment)
            #expect(detected.workingDirectory == workspace.path, selectorComment)
        }
    }

    @Test func directProcessDetectionFallsBackToPartialSessionFileMatch() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-partial-session-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let partial = try Self.writeSessionFile(
            id: "prefix-partial-omp-session-suffix",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            arguments: ["/Users/example/.bun/bin/omp", "--session", "partial-omp-session"],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(partial.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func directProcessDetectionUsesOmpAgentDirectorySessionsWhenNoSessionDirectoryIsSet() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-agent-dir-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let agentRoot = root.appendingPathComponent("omp-agent", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = agentRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let latest = try Self.writeSessionFile(
            id: "omp-agent-dir-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            arguments: ["/Users/example/.bun/bin/omp"],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_DIR": agentRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(latest.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func directProcessDetectionUsesPiConfigDirectoryAgentSessionsWhenAgentDirectoryIsUnset() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-config-dir-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = home
            .appendingPathComponent(".custom-omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let latest = try Self.writeSessionFile(
            id: "omp-config-dir-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            arguments: ["/Users/example/.bun/bin/omp"],
            environment: [
                "HOME": home.path,
                "PWD": workspace.path,
                "PI_CONFIG_DIR": ".custom-omp",
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(latest.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func directProcessDetectionPreservesCustomSessionDirectoryBeforeOmpEnvironment() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-custom-session-dir-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let customRoot = root.appendingPathComponent("custom-sessions", isDirectory: true)
        let environmentRoot = root.appendingPathComponent("environment-sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let customProjectSessions = customRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        let environmentProjectSessions = environmentRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: customProjectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: environmentProjectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let custom = try Self.writeSessionFile(
            id: "omp-custom-session-dir-session",
            in: customProjectSessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let environment = try Self.writeSessionFile(
            id: "omp-environment-session",
            in: environmentProjectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let registration = CmuxVaultAgentRegistration(
            id: "omp",
            name: "OMP",
            detect: CmuxVaultAgentDetectRule(processName: "omp"),
            sessionIdSource: .piSessionFile,
            resumeCommand: "{{executable}} --session {{sessionId}}",
            sessionDirectory: customRoot.path
        )
        let detected = try #require(Self.detectedOmpSnapshot(
            arguments: ["/Users/example/.bun/bin/omp"],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_DIR": environmentRoot.path,
            ],
            registration: registration
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(custom.path))
        #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(environment.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func vaultDetectsBunInvokedOmpPackage() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-bun-vault-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let latest = try Self.writeSessionFile(
            id: "omp-bun-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            processName: "bun",
            processPath: "/opt/homebrew/bin/bun",
            arguments: [
                "/opt/homebrew/bin/bun",
                "/Users/example/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/src/main.ts",
                "--model",
                "anthropic/claude-sonnet-4-5",
            ],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(latest.path))
        #expect(detected.workingDirectory == workspace.path)
        #expect(detected.launchCommand?.executablePath == "omp")
        #expect(detected.launchCommand?.arguments == [
            "omp",
            "--model",
            "anthropic/claude-sonnet-4-5",
        ])
    }

    @Test func hostedOmpIgnoresRuntimePreloadFlagsBeforeAgentScript() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-hosted-runtime-preload-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let latest = try Self.writeSessionFile(
            id: "omp-hosted-latest-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            processName: "node",
            processPath: "/opt/homebrew/bin/node",
            arguments: [
                "/opt/homebrew/bin/node",
                "-r",
                "/tmp/preload-session-module.js",
                "/Users/example/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/src/main.ts",
            ],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(latest.path))
        #expect(detected.sessionId != "/tmp/preload-session-module.js")
        #expect(detected.workingDirectory == workspace.path)
        #expect(detected.launchCommand?.executablePath == "omp")
        #expect(detected.launchCommand?.arguments == ["omp"])
    }

    @Test func hostedOmpParsesSessionSelectorsAfterAgentScript() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-hosted-runtime-session-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectDirectory = try #require(PiSessionLocator.projectDirectoryName(for: workspace.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let explicit = try Self.writeSessionFile(
            id: "omp-hosted-explicit-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let latest = try Self.writeSessionFile(
            id: "omp-hosted-latest-session",
            in: projectSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            processName: "node",
            processPath: "/opt/homebrew/bin/node",
            arguments: [
                "/opt/homebrew/bin/node",
                "-r",
                "/tmp/preload-session-module.js",
                "/Users/example/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/src/main.ts",
                "--session",
                "omp-hosted-explicit-session",
            ],
            environment: [
                "PWD": workspace.path,
                "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(explicit.path))
        #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(latest.path))
        #expect(detected.workingDirectory == workspace.path)
        #expect(detected.launchCommand?.executablePath == "omp")
        #expect(detected.launchCommand?.arguments == [
            "omp",
            "--session",
            "omp-hosted-explicit-session",
        ])
    }

    @Test func taskManagerClassifiesOmpBeforeLegacyPiPackageNeedles() throws {
        let direct = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "omp",
            processPath: "/Users/example/.bun/bin/omp",
            arguments: ["/Users/example/.bun/bin/omp", "--model", "anthropic/claude-sonnet-4-5"],
            environment: [:]
        ))
        #expect(direct.id == "omp")

        let hostedOmp = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "bun",
            processPath: "/opt/homebrew/bin/bun",
            arguments: [
                "/opt/homebrew/bin/bun",
                "/Users/example/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/src/main.ts",
                "--model",
                "anthropic/claude-sonnet-4-5",
            ],
            environment: [:]
        ))
        #expect(hostedOmp.id == "omp")

        let legacyPi = try #require(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "bun",
            processPath: "/opt/homebrew/bin/bun",
            arguments: [
                "/opt/homebrew/bin/bun",
                "/Users/example/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/src/main.ts",
                "--model",
                "anthropic/claude-sonnet-4-5",
            ],
            environment: [:]
        ))
        #expect(legacyPi.id == "pi")
    }

    private static func detectedOmpSnapshot(
        processName: String = "omp",
        processPath: String? = "/Users/example/.bun/bin/omp",
        arguments: [String],
        environment: [String: String],
        registration: CmuxVaultAgentRegistration = .builtInOmp
    ) -> SessionRestorableAgentSnapshot? {
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let processId = 4242
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
