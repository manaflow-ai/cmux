import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("OMP support")
struct OmpSupportTests {
    @Test func ompIsAllowedForAgentHibernationLifecycle() {
        #expect(AgentHibernationLifecycleStatusKeys.isAllowed("omp"))
    }

    @Test func textBoxDetectsOmpAsPiAlias() {
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "agentPIDKey:omp"))
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "agentPIDKey:omp.session-123"))
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "restoredAgent:omp"))
        #expect(TextBoxAgentDetection.boundedLaunchCommandContext(from: "omp --model anthropic/claude-sonnet-4-5") == "pi")
    }

    @Test func textBoxDetectsOmpLaunchCommands() {
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "initialCommand:omp --model anthropic/claude-sonnet-4-5"))
        #expect(TextBoxAgentDetection.supportsAgentPrefixes(context: "tmuxStartCommand:omp"))
        #expect(!TextBoxAgentDetection.supportsAgentPrefixes(context: "initialCommand:vim notes.txt"))
    }

    @Test func sleepyAgentCensusBucketsOmpWithPi() {
        #expect(SleepyAgentCensus.bucket(forStatusKey: "omp") == .pi)
        #expect(SleepyAgentCensus.bucket(forStatusKey: "pi") == .pi)
        #expect(SleepyAgentCensus.bucket(forStatusKey: "claude") == .claude)
        #expect(SleepyAgentCensus.bucket(forStatusKey: "unknown-agent") == .other)
    }

    @Test func sleepyAgentCensusBucketsDottedLivePIDKeys() {
        // The agent-hook path stores PID keys as "<statusKey>.<sessionId>".
        #expect(SleepyAgentCensus.bucket(forStatusKey: "omp.session-abc") == .pi)
        #expect(SleepyAgentCensus.bucket(forStatusKey: "pi.session-abc") == .pi)
        #expect(SleepyAgentCensus.bucket(forStatusKey: "unknown-agent.session-abc") == .other)
    }

    @Test func ompRegistriesUsePiIconAsset() throws {
        let taskManagerDefinition = try #require(
            CmuxTaskManagerCodingAgentDefinition.builtIns.first { $0.id == "omp" }
        )
        #expect(taskManagerDefinition.assetName == "AgentIcons/Pi")
        #expect(CmuxVaultAgentRegistration.builtInOmp.iconAssetName == "AgentIcons/Pi")
    }

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
                    "PI_CODING_AGENT_DIR": root.path,
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
                "PI_CODING_AGENT_DIR": root.path,
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
                "PI_CODING_AGENT_DIR": root.path,
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
                "PI_CODING_AGENT_DIR": root.path,
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
                "PI_CODING_AGENT_DIR": root.path,
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

    @Test func liveVaultUsesCliProfileDirectoryAndCurrentHomeRelativeBucket() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-profile-vault-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("project", isDirectory: true)
        let profileSessions = home
            .appendingPathComponent(".omp/profiles/work/agent/sessions", isDirectory: true)
            .appendingPathComponent("-project", isDirectory: true)
        let ambientAgent = root.appendingPathComponent("ambient-agent", isDirectory: true)
        let ambientSessions = ambientAgent
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(Self.legacyProjectDirectoryName(for: workspace.path), isDirectory: true)
        try FileManager.default.createDirectory(at: profileSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ambientSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let expected = try Self.writeSessionFile(
            id: "omp-work-profile-session",
            in: profileSessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let ambient = try Self.writeSessionFile(
            id: "omp-ambient-agent-session",
            in: ambientSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            arguments: ["/Users/example/.bun/bin/omp", "--profile", "work"],
            environment: [
                "HOME": home.path,
                "PWD": workspace.path,
                "OMP_PROFILE": "personal",
                "PI_PROFILE": "legacy",
                "PI_CODING_AGENT_DIR": ambientAgent.path,
            ]
        ))

        #expect(detected.kind == RestorableAgentKind.custom("omp"))
        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(expected.path))
        #expect(Self.normalizedPath(detected.sessionId) != Self.normalizedPath(ambient.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func liveVaultFallsBackToLegacyOmpCwdBucket() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-legacy-bucket-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("project", isDirectory: true)
        let legacySessions = home
            .appendingPathComponent(".omp/agent/sessions", isDirectory: true)
            .appendingPathComponent(Self.legacyProjectDirectoryName(for: workspace.path), isDirectory: true)
        try FileManager.default.createDirectory(at: legacySessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let legacy = try Self.writeSessionFile(
            id: "omp-legacy-bucket-session",
            in: legacySessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            arguments: ["/Users/example/.bun/bin/omp"],
            environment: [
                "HOME": home.path,
                "PWD": workspace.path,
            ]
        ))

        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(legacy.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func liveVaultUsesCurrentOmpHomeTempAndAbsoluteCwdBuckets() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-current-buckets-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let nestedWorkspace = home.appendingPathComponent("project/sub", isDirectory: true)
        let tempWorkspace = root.appendingPathComponent("scratch", isDirectory: true)
        let outsideWorkspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: nestedWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        let fixtures = [
            (workspace: home, bucket: "-", sessionID: "omp-home-bucket-session"),
            (workspace: nestedWorkspace, bucket: "-project-sub", sessionID: "omp-home-relative-bucket-session"),
            (
                workspace: tempWorkspace,
                bucket: "-tmp-\(root.lastPathComponent)-scratch",
                sessionID: "omp-temp-bucket-session"
            ),
            (
                workspace: outsideWorkspace,
                bucket: Self.legacyProjectDirectoryName(for: outsideWorkspace.path),
                sessionID: "omp-absolute-bucket-session"
            ),
        ]

        for fixture in fixtures {
            let projectSessions = home
                .appendingPathComponent(".omp/agent/sessions", isDirectory: true)
                .appendingPathComponent(fixture.bucket, isDirectory: true)
            try FileManager.default.createDirectory(at: projectSessions, withIntermediateDirectories: true)
            let expected = try Self.writeSessionFile(
                id: fixture.sessionID,
                in: projectSessions,
                modifiedAt: Date(timeIntervalSince1970: 1_000)
            )

            let arguments = fixture.workspace == home
                ? ["/Users/example/.bun/bin/omp", "--allow-home"]
                : ["/Users/example/.bun/bin/omp"]
            let detected = try #require(Self.detectedOmpSnapshot(
                arguments: arguments,
                environment: [
                    "HOME": home.path,
                    "PWD": fixture.workspace.path,
                ]
            ), Comment(rawValue: fixture.bucket))

            #expect(
                Self.normalizedPath(detected.sessionId) == Self.normalizedPath(expected.path),
                Comment(rawValue: fixture.bucket)
            )
            #expect(detected.workingDirectory == fixture.workspace.path, Comment(rawValue: fixture.bucket))
        }
    }

    @Test func liveVaultUsesExplicitOmpSessionDirectoryWithoutAppendingCwdBucket() throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-explicit-session-dir-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("project", isDirectory: true)
        let explicitSessions = root.appendingPathComponent("explicit-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: explicitSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let explicit = try Self.writeSessionFile(
            id: "omp-explicit-session-dir-session",
            in: explicitSessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        let detected = try #require(Self.detectedOmpSnapshot(
            arguments: [
                "/Users/example/.bun/bin/omp",
                "--profile",
                "work",
                "--session-dir",
                explicitSessions.path,
            ],
            environment: [
                "HOME": home.path,
                "PWD": workspace.path,
                "OMP_PROFILE": "personal",
            ]
        ))

        #expect(Self.normalizedPath(detected.sessionId) == Self.normalizedPath(explicit.path))
        #expect(detected.workingDirectory == workspace.path)
    }

    @Test func historicalVaultIndexesValidOmpProfilesWithProfileSpecificCommands() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-omp-profile-history-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("project", isDirectory: true)
        let xdgDataHome = root.appendingPathComponent("xdg-data", isDirectory: true)
        let workSessions = home
            .appendingPathComponent(".omp/profiles/work/agent/sessions/-project", isDirectory: true)
        let invalidSessions = home
            .appendingPathComponent(".omp/profiles/INVALID PROFILE/agent/sessions/-project", isDirectory: true)
        let xdgProfileSessions = xdgDataHome
            .appendingPathComponent("omp/profiles/data/sessions/-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let workFile = try Self.writeOmpTranscript(
            id: "omp-work-history",
            title: "Resume the work profile",
            cwd: workspace.path,
            in: workSessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let invalidFile = try Self.writeOmpTranscript(
            id: "omp-invalid-history",
            title: "Do not index an invalid profile",
            cwd: workspace.path,
            in: invalidSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )
        let xdgFile = try Self.writeOmpTranscript(
            id: "omp-xdg-history",
            title: "Resume the XDG profile",
            cwd: workspace.path,
            in: xdgProfileSessions,
            modifiedAt: Date(timeIntervalSince1970: 3_000)
        )
        let mirroredXdgProfile = xdgDataHome
            .appendingPathComponent("omp/profiles/work", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: mirroredXdgProfile,
            withDestinationURL: workSessions
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: .builtInOmp,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            environment: [
                "HOME": home.path,
                "XDG_DATA_HOME": xdgDataHome.path,
            ],
            homeDirectory: home.path,
            fileManager: .default
        )

        let workEntry = try #require(entries.first {
            $0.fileURL?.resolvingSymlinksInPath() == workFile.resolvingSymlinksInPath()
        })
        #expect(entries.filter {
            $0.fileURL?.resolvingSymlinksInPath() == workFile.resolvingSymlinksInPath()
        }.count == 1)
        let xdgEntry = try #require(entries.first {
            $0.fileURL?.resolvingSymlinksInPath() == xdgFile.resolvingSymlinksInPath()
        })
        #expect(!entries.contains {
            $0.fileURL?.resolvingSymlinksInPath() == invalidFile.resolvingSymlinksInPath()
        })

        guard case .registered(let workRegistration) = workEntry.specifics,
              case .registered(let xdgRegistration) = xdgEntry.specifics else {
            Issue.record("Expected OMP profile history to retain registered-agent specifics")
            return
        }
        let builtIn = CmuxVaultAgentRegistration.builtInOmp
        let builtInForkCommand = try #require(builtIn.forkCommand)
        #expect(workRegistration.resumeCommand == "env OMP_PROFILE='work' \(builtIn.resumeCommand)")
        #expect(workRegistration.forkCommand == "env OMP_PROFILE='work' \(builtInForkCommand)")
        #expect(xdgRegistration.resumeCommand == "env OMP_PROFILE='data' \(builtIn.resumeCommand)")
        #expect(xdgRegistration.forkCommand == "env OMP_PROFILE='data' \(builtInForkCommand)")
    }

    @Test func historicalVaultKeepsCustomOmpRegistrationRootAndTemplates() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-custom-omp-history-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("project", isDirectory: true)
        let customSessions = root.appendingPathComponent("custom-sessions/-project", isDirectory: true)
        let builtInProfileSessions = home
            .appendingPathComponent(".omp/profiles/work/agent/sessions/-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let customFile = try Self.writeOmpTranscript(
            id: "custom-omp-history",
            title: "Resume custom OMP",
            cwd: workspace.path,
            in: customSessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        let builtInProfileFile = try Self.writeOmpTranscript(
            id: "built-in-profile-history",
            title: "Ignore built-in profile roots",
            cwd: workspace.path,
            in: builtInProfileSessions,
            modifiedAt: Date(timeIntervalSince1970: 2_000)
        )

        var registration = CmuxVaultAgentRegistration.builtInOmp
        registration.name = "Project OMP"
        registration.sessionDirectory = customSessions.deletingLastPathComponent().path
        registration.resumeCommand = "project-omp --resume {{sessionId}}"
        registration.forkCommand = "project-omp --fork {{sessionId}}"
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            environment: ["HOME": home.path],
            homeDirectory: home.path,
            fileManager: .default
        )

        let entry = try #require(entries.first {
            $0.fileURL?.resolvingSymlinksInPath() == customFile.resolvingSymlinksInPath()
        })
        #expect(!entries.contains {
            $0.fileURL?.resolvingSymlinksInPath() == builtInProfileFile.resolvingSymlinksInPath()
        })
        guard case .registered(let retainedRegistration) = entry.specifics else {
            Issue.record("Expected custom OMP history to retain registered-agent specifics")
            return
        }
        #expect(retainedRegistration == registration)
    }

    @Test func historicalVaultResolvesRelativeOmpAgentRootFromFilteredWorkspace() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "cmux-relative-omp-history-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("project", isDirectory: true)
        let sessions = workspace
            .appendingPathComponent("agents/omp/sessions/-project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let transcript = try Self.writeOmpTranscript(
            id: "relative-omp-history",
            title: "Resume relative OMP",
            cwd: workspace.path,
            in: sessions,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: .builtInOmp,
            needle: "",
            cwdFilter: workspace.path,
            offset: 0,
            limit: 10,
            environment: [
                "HOME": home.path,
                "PWD": home.appendingPathComponent("unrelated").path,
                "PI_CODING_AGENT_DIR": "agents/omp",
            ],
            homeDirectory: home.path,
            fileManager: .default
        )

        #expect(entries.contains {
            $0.fileURL?.resolvingSymlinksInPath() == transcript.resolvingSymlinksInPath()
        })
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

    private static func legacyProjectDirectoryName(for workingDirectory: String) -> String {
        let resolved = (workingDirectory as NSString).standardizingPath
        let withoutLeadingSlash = resolved.hasPrefix("/") ? String(resolved.dropFirst()) : resolved
        let encoded = withoutLeadingSlash
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "--\(encoded)--"
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

    private static func writeOmpTranscript(
        id: String,
        title: String,
        cwd: String,
        in directory: URL,
        modifiedAt: Date
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).jsonl", isDirectory: false)
        try """
        {"id":"\(id)","cwd":"\(cwd)"}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"\(title)"}]}}
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private static func writeSessionFile(id: String, in directory: URL, modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent("\(id).jsonl", isDirectory: false)
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }
}
