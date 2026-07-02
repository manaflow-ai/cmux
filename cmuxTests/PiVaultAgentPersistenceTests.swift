import CMUXAgentLaunch
import CmuxWorkspaces
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PiVaultAgentPersistenceTests: XCTestCase {
    func testRegisteredSessionAgentCodablePreservesPresentation() throws {
        let encoded = try JSONEncoder().encode(
            SessionAgent.registered(RegisteredSessionAgent(
                id: "acme-agent",
                name: "Acme Agent",
                iconAssetName: "AgentIcons/Acme"
            ))
        )

        let decoded = try JSONDecoder().decode(SessionAgent.self, from: encoded)

        guard case .registered(let agent) = decoded else {
            return XCTFail("Expected registered agent")
        }
        XCTAssertEqual(agent.id, "acme-agent")
        XCTAssertEqual(agent.name, "Acme Agent")
        XCTAssertEqual(agent.iconAssetName, "AgentIcons/Acme")
    }

    func testBuiltInIDWithRegisteredMetadataDecodesAsRegisteredAgent() throws {
        let encoded = Data(#"{"id":"grok","name":"Custom Grok","iconAssetName":"AgentIcons/CustomGrok"}"#.utf8)

        let decoded = try JSONDecoder().decode(SessionAgent.self, from: encoded)

        guard case .registered(let agent) = decoded else {
            return XCTFail("Expected legacy registered Grok metadata to be preserved")
        }
        XCTAssertEqual(agent.id, "grok")
        XCTAssertEqual(agent.name, "Custom Grok")
        XCTAssertEqual(agent.iconAssetName, "AgentIcons/CustomGrok")
    }

    func testBuiltInIDWithoutRegisteredMetadataDecodesAsBuiltInAgent() throws {
        let encoded = Data(#"{"id":"grok"}"#.utf8)

        let decoded = try JSONDecoder().decode(SessionAgent.self, from: encoded)

        XCTAssertEqual(decoded, .grok)
    }

    func testRegisteredSessionAgentEqualityIncludesPresentation() {
        XCTAssertNotEqual(
            SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", name: "Acme Agent")),
            SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", name: "Renamed Agent"))
        )
        XCTAssertEqual(
            Set([
                SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", iconAssetName: "AgentIcons/Acme")),
                SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", iconAssetName: "AgentIcons/Renamed")),
            ]).count,
            2
        )
    }

    func testBuiltInPiRegistrationUsesBrandedIconAsset() {
        let agent = RegisteredSessionAgent(registration: CmuxVaultAgentRegistration.builtInPi)

        XCTAssertEqual(agent.iconAssetName, "AgentIcons/Pi")
        XCTAssertEqual(SessionAgent.registered(agent).assetName, "AgentIcons/Pi")
    }


    func testBuiltInAntigravityRegistrationUsesBrandedIconAsset() {
        let agent = RegisteredSessionAgent(registration: CmuxVaultAgentRegistration.builtInAntigravity)

        XCTAssertEqual(agent.iconAssetName, "AgentIcons/Antigravity")
        XCTAssertEqual(SessionAgent.registered(agent).assetName, "AgentIcons/Antigravity")
        XCTAssertEqual(CmuxVaultAgentRegistration.builtInAntigravity.detect.processNames, ["agy", "antigravity"])
    }

    func testBuiltInAntigravityRegistrationLoadsHistoryDisplayAndWorkspace() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-vault-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try """
        {"conversationId":"antigravity-conversation-123","display":"Implement Antigravity notifications","timestamp":1779231774516,"workspace":"/tmp/antigravity repo"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInAntigravity
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.agent, .registered(RegisteredSessionAgent(registration: registration)))
        XCTAssertEqual(entry.sessionId, "antigravity-conversation-123")
        XCTAssertEqual(entry.title, "Implement Antigravity notifications")
        XCTAssertEqual(entry.cwd, "/tmp/antigravity repo")
        XCTAssertEqual(
            entry.resumeCommand,
            "cd -- '/tmp/antigravity repo' 2>/dev/null || [ ! -d '/tmp/antigravity repo' ] && 'agy' '--conversation' 'antigravity-conversation-123'"
        )
    }

    func testBuiltInAntigravityRegistrationIndexesEachHistoryConversation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-antigravity-vault-conversations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let historyURL = tempDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try """
        {"display":"first prompt","timestamp":1779262970000,"workspace":"/tmp/antigravity repo","conversationId":"conversation-a"}
        {"display":"newer prompt","timestamp":1779262980000,"workspace":"/tmp/antigravity repo","conversationId":"conversation-b"}
        {"display":"unresumable prompt","timestamp":1779262990000,"workspace":"/tmp/antigravity repo"}
        {"display":"latest prompt","timestamp":1779263000000,"workspace":"/tmp/antigravity repo","conversationId":"conversation-a"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInAntigravity
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.sessionId), ["conversation-a", "conversation-b"])
        XCTAssertEqual(entries.map(\.title), ["latest prompt", "newer prompt"])
        XCTAssertEqual(entries.map(\.cwd), ["/tmp/antigravity repo", "/tmp/antigravity repo"])

        let filtered = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "newer",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(filtered.map(\.sessionId), ["conversation-b"])
        XCTAssertEqual(
            filtered.first?.resumeCommand,
            "cd -- '/tmp/antigravity repo' 2>/dev/null || [ ! -d '/tmp/antigravity repo' ] && 'agy' '--conversation' 'conversation-b'"
        )
    }

    func testRegisteredAgentJSONLWorkspaceKeyIsSharedCWDMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-workspace-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("metadata.jsonl")
        try """
        {"sessionId":"native-session-123","workspace":"/tmp/acme-workspace","title":"Resume Acme"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: tempDir.path
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, "native-session-123")
        XCTAssertEqual(entry.title, "Resume Acme")
        XCTAssertEqual(entry.cwd, "/tmp/acme-workspace")
    }

    func testRegisteredAgentJSONLDisplayFieldIsNotSharedTitleMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-display-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("metadata.jsonl")
        try """
        {"sessionId":"native-session-123","cwd":"/tmp/acme","display":"Antigravity-only prompt"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: tempDir.path
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, "native-session-123")
        XCTAssertEqual(entry.title, "")
        XCTAssertEqual(
            entry.displayTitle,
            String(localized: "sessionIndex.untitled", defaultValue: "Untitled chat")
        )
    }

    func testRegisteredAgentJSONLSessionIDDoesNotUseAntigravityConversationID() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-session-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("metadata.jsonl")
        try """
        {"conversationId":"foreign-conversation","sessionId":"native-session-123","cwd":"/tmp/acme","title":"Resume Acme"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: tempDir.path
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, "native-session-123")
        XCTAssertEqual(entry.resumeCommand, "cd -- '/tmp/acme' 2>/dev/null || [ ! -d '/tmp/acme' ] && 'acme-agent' '--session' 'native-session-123'")
    }

    func testBuiltInGrokRegistrationUsesNativeSessionDirectory() {
        let registration = CmuxVaultAgentRegistration.builtInGrok

        XCTAssertEqual(registration.id, "grok")
        XCTAssertEqual(registration.sessionIdSource, .grokSessionDirectory)
        XCTAssertEqual(registration.sessionDirectory, "~/.grok/sessions")
        XCTAssertEqual(registration.detect.processNames, ["grok", "grok-macos-aarch64", "grok-macos-aarch"])
        XCTAssertTrue(registration.detect.argvContains.isEmpty)
        XCTAssertEqual(SessionAgent.grok.assetName, "AgentIcons/Grok")
    }

    func testRegisteredAgentTemplateFailsClosedWhenPlaceholderIsUnavailable() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder().resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: nil,
            registrationOverride: registration
        )

        XCTAssertNil(command)
    }

    func testRegisteredAgentTemplateUsesExplicitWorkingDirectoryForCWDPlaceholder() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder().resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--cwd' '/tmp/acme' '--session' 'session-123'")
    }

    func testRegisteredAgentTemplatePreservesCWDArgumentWithWorkingDirectoryPrefix() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder().resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration
        )

        XCTAssertEqual(
            command,
            "cd -- '/tmp/acme' 2>/dev/null || [ ! -d '/tmp/acme' ] && 'acme-agent' '--cwd' '/tmp/acme' '--session' 'session-123'"
        )
    }

    func testRegisteredAgentTemplateDoesNotExpandPlaceholdersInsideReplacementValues() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}} --cwd {{cwd}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder().resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-{{cwd}}",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--session' 'session-{{cwd}}' '--cwd' '/tmp/acme'")
    }

    func testRegisteredAgentCWDIgnoreSuppressesResumeWorkingDirectory() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .ignore
        )
        let entry = SessionEntry(
            id: "acme-agent:session-123",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "session-123",
            title: "Acme",
            cwd: "/tmp/acme",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1),
            fileURL: nil,
            specifics: .registered(registration)
        )

        XCTAssertNil(entry.resumeWorkingDirectory)
        XCTAssertEqual(entry.resumeCommand, "'acme-agent' '--session' 'session-123'")
    }

    func testRegisteredAgentJSONLNativeSessionIDOverridesPathFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-native-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("metadata.jsonl")
        try """
        {"sessionId":"native-session-123","cwd":"/tmp/acme","title":"Resume Acme"}
        {"gitBranch":"issue-3575-vault-pi-agent-support"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: tempDir.path
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "acme-agent:native-session-123")
        XCTAssertEqual(entry.sessionId, "native-session-123")
        XCTAssertEqual(entry.title, "Resume Acme")
        XCTAssertEqual(entry.gitBranch, "issue-3575-vault-pi-agent-support")
    }

    func testRegisteredAgentCWDFilterUsesJSONLMetadataNotFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-cwd-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("metadata.jsonl")
        try """
        {"sessionId":"native-session-123","cwd":"/tmp/other","title":"Resume Acme"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: tempDir.path
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: "/tmp/acme",
            offset: 0,
            limit: 10
        )

        XCTAssertTrue(entries.isEmpty)
    }

    func testRegisteredAgentMetadataKeepsScanningForBranchWhenFallbackCWDSet() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/pi repo"
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd))
        let sessionDir = tempDir.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("018f2b35-7c75-7e1a-a6ff-cc1d5f9f0000.jsonl")
        try """
        {"message":{"content":"Implement Pi restore"}}
        {"git":{"branch":"issue-3575-vault-pi-agent-support"}}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: cwd,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "Implement Pi restore")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(entry.gitBranch, "issue-3575-vault-pi-agent-support")
    }

    func testPiJSONLTypedContentBlocksUseFirstUserTextAsTitle() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-title-blocks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/pi typed blocks"
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd))
        let sessionDir = tempDir.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("019e1c86-def0-72c9-90d4-8543db20f981.jsonl")
        try """
        {"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"assistant preface"}]}}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"ping"}]}}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: cwd,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "ping")
        XCTAssertEqual(entry.cwd, cwd)
    }

    func testPiJSONLTopLevelAssistantTypedContentDoesNotBecomeTitle() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-top-level-role-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/pi top level role"
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd))
        let sessionDir = tempDir.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("019e1c86-def0-72c9-90d4-8543db20f982.jsonl")
        try """
        {"role":"assistant","content":[{"type":"text","text":"assistant preface"}]}
        {"role":"user","content":[{"type":"text","text":"implement the vault view"}]}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: cwd,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "implement the vault view")
        XCTAssertEqual(entry.cwd, cwd)
    }

    func testPiJSONLMessagesArrayUsesNilRoleTextAsTitle() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-messages-nil-role-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/pi nil role"
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd))
        let sessionDir = tempDir.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("019e1c86-def0-72c9-90d4-8543db20f983.jsonl")
        try """
        {"messages":[{"content":[{"type":"text","text":"restore without role"}]},{"role":"assistant","content":[{"type":"text","text":"assistant reply"}]}]}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: cwd,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "restore without role")
        XCTAssertEqual(entry.cwd, cwd)
    }

    func testPiJSONLTypedContentBlocksRequireTextType() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-typed-content-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/pi typed content"
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd))
        let sessionDir = tempDir.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("019e1c86-def0-72c9-90d4-8543db20f984.jsonl")
        try """
        {"message":{"role":"user","content":[{"text":"untyped object"},{"type":"image","text":"image fallback"},{"type":"text","text":"typed text title"}]}}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: cwd,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "typed text title")
        XCTAssertEqual(entry.cwd, cwd)
    }

    func testGrokVaultLoadsNativeChatHistoryFromEncodedDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/grok repo"
        let sessionId = "grok-session-123"
        let grokHome = tempDir.appendingPathComponent("grok-home", isDirectory: true)
        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"assistant","content":"assistant preface"}
        {"type":"user","content":"Implement Grok Vault","model":"grok-4","permissionMode":"auto","sandboxMode":"danger-full-access","git":{"branch":"issue-4394-grok-vault-resume"}}
        {"type":"assistant","content":"done"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.agent, .grok)
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Implement Grok Vault")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(entry.gitBranch, "issue-4394-grok-vault-resume")
        XCTAssertEqual(entry.fileURL?.resolvingSymlinksInPath(), historyURL.resolvingSymlinksInPath())
        XCTAssertEqual(
            entry.resumeCommand,
            "cd -- '/tmp/grok repo' 2>/dev/null || [ ! -d '/tmp/grok repo' ] && 'env' 'GROK_HOME=\(grokHome.path)' 'grok' '-r' 'grok-session-123' '-m' 'grok-4' '--permission-mode' 'auto' '--sandbox' 'danger-full-access'"
        )
    }

    func testGrokVaultTitlePrefersUserQueryOverInjectedMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-metadata-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/grok metadata repo"
        let sessionId = "grok-metadata-session"
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let userContent = """
        <user_info>
        OS Version: macos 26.4
        </user_info>
        <git_status>
        Current branch: issue-4394-grok-vault-resume
        </git_status>
        <user_query>
        Implement native Vault metadata
        </user_query>
        """
        let records: [[String: Any]] = [
            ["type": "system", "content": "You are Grok"],
            ["type": "user", "content": userContent, "model": "grok-4"],
        ]
        let jsonLines = try records.map { record in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
        try (jsonLines + "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "Implement native Vault metadata")
    }

    func testGrokVaultFindsBranchAfterStableMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-late-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/grok late branch"
        let sessionId = "grok-late-branch-session"
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Find late branch","model":"grok-4","permissionMode":"auto","sandboxMode":"danger-full-access"}
        {"type":"assistant","content":"Working","git":{"branch":"late-branch"}}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.gitBranch, "late-branch")
    }

    func testGrokVaultLoadsHookObservedShellGrokHome() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-observed-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let homeDirectory = tempDir.appendingPathComponent("home", isDirectory: true)
        let hookStore = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        try FileManager.default.createDirectory(at: hookStore.deletingLastPathComponent(), withIntermediateDirectories: true)

        let cwd = "/tmp/grok observed home"
        let sessionId = "grok-observed-home-session"
        let grokHome = tempDir.appendingPathComponent("shell-grok-home", isDirectory: true)
        let historyURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Find sessions under shell GROK_HOME","model":"grok-4","permissionMode":"auto","sandboxMode":"danger-full-access"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        try """
        {
          "version": 1,
          "sessions": {
            "\(sessionId)": {
              "launchCommand": {
                "environment": {
                  "GROK_HOME": "\(grokHome.path)"
                }
              }
            }
          }
        }
        """.write(to: hookStore, atomically: true, encoding: .utf8)

        let entries = await SessionIndexStore.loadGrokEntries(
            registration: .builtInGrok,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            environment: [:],
            homeDirectory: homeDirectory.path
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Find sessions under shell GROK_HOME")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(
            entry.resumeCommand,
            "cd -- '/tmp/grok observed home' 2>/dev/null || [ ! -d '/tmp/grok observed home' ] && 'env' 'GROK_HOME=\(grokHome.path)' 'grok' '-r' '\(sessionId)' '-m' 'grok-4' '--permission-mode' 'auto' '--sandbox' 'danger-full-access'"
        )
    }

    func testGrokVaultLoadsHookObservedShellGrokHomeFromCustomStateDir() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-custom-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let homeDirectory = tempDir.appendingPathComponent("home", isDirectory: true)
        let hookStateDir = tempDir.appendingPathComponent("hook-state", isDirectory: true)
        let hookStore = hookStateDir.appendingPathComponent("grok-hook-sessions.json", isDirectory: false)
        try FileManager.default.createDirectory(at: hookStateDir, withIntermediateDirectories: true)

        let cwd = "/tmp/grok custom state"
        let sessionId = "grok-custom-state-session"
        let grokHome = tempDir.appendingPathComponent("custom-state-grok-home", isDirectory: true)
        let historyURL = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Find sessions under custom hook state","model":"grok-4"}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        try """
        {
          "version": 1,
          "sessions": {
            "\(sessionId)": {
              "launchCommand": {
                "environment": {
                  "GROK_HOME": "\(grokHome.path)"
                }
              }
            }
          }
        }
        """.write(to: hookStore, atomically: true, encoding: .utf8)

        let entries = await SessionIndexStore.loadGrokEntries(
            registration: .builtInGrok,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDir.path],
            homeDirectory: homeDirectory.path
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Find sessions under custom hook state")
        XCTAssertEqual(
            entry.resumeCommand,
            "cd -- '/tmp/grok custom state' 2>/dev/null || [ ! -d '/tmp/grok custom state' ] && 'env' 'GROK_HOME=\(grokHome.path)' 'grok' '-r' '\(sessionId)' '-m' 'grok-4'"
        )
    }

    func testRegisteredGrokSessionDirectoryUsesNativeDirectoryLayout() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-grok-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/custom grok repo"
        let sessionId = "custom-grok-session-123"
        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = sessionsRoot
            .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("chat_history.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","content":"Resume a custom Grok-compatible agent","git":{"branch":"issue-4394-grok-vault-resume"}}
        """.write(to: historyURL, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "custom-grok",
            name: "Custom Grok",
            detect: CmuxVaultAgentDetectRule(processName: "custom-grok"),
            sessionIdSource: .grokSessionDirectory,
            resumeCommand: "custom-grok -r {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: sessionsRoot.path
        )
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "custom-grok:\(sessionId)")
        XCTAssertEqual(entry.agent, .registered(RegisteredSessionAgent(registration: registration)))
        XCTAssertEqual(entry.sessionId, sessionId)
        XCTAssertEqual(entry.title, "Resume a custom Grok-compatible agent")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(entry.gitBranch, "issue-4394-grok-vault-resume")
        XCTAssertEqual(
            entry.resumeCommand,
            "cd -- '/tmp/custom grok repo' 2>/dev/null || [ ! -d '/tmp/custom grok repo' ] && 'env' 'GROK_HOME=\(tempDir.path)' 'custom-grok' '-r' '\(sessionId)'"
        )
    }

    func testGrokVaultCWDFilterUsesEncodedProjectDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-vault-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionsRoot = tempDir.appendingPathComponent("sessions", isDirectory: true)
        func writeHistory(cwd: String, sessionId: String, prompt: String) throws {
            let historyURL = sessionsRoot
                .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent("chat_history.jsonl", isDirectory: false)
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try #"{"type":"user","content":"\#(prompt)"}"#
                .write(to: historyURL, atomically: true, encoding: .utf8)
        }

        try writeHistory(cwd: "/tmp/current grok repo", sessionId: "current-session", prompt: "current")
        try writeHistory(cwd: "/tmp/current grok repo/../current grok repo", sessionId: "current-session", prompt: "duplicate")
        try writeHistory(cwd: "/tmp/other grok repo", sessionId: "other-session", prompt: "other")

        var registration = CmuxVaultAgentRegistration.builtInGrok
        registration.sessionDirectory = sessionsRoot.path
        let entries = await SessionIndexStore.loadGrokEntries(
            registration: registration,
            needle: "",
            cwdFilter: "/tmp/current grok repo/../current grok repo",
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(entries.map(\.sessionId), ["current-session"])
        XCTAssertEqual(entries.first?.cwd, "/tmp/current grok repo")
    }

    @MainActor
    func testGrokAgentSearchScopeUsesCurrentDirectoryCWDFilter() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-grok-agent-scope-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let previousGrokHome = getenv("GROK_HOME").map { String(cString: $0) }
        let grokHome = tempDir.appendingPathComponent("grok-home", isDirectory: true)
        setenv("GROK_HOME", grokHome.path, 1)
        defer {
            if let previousGrokHome {
                setenv("GROK_HOME", previousGrokHome, 1)
            } else {
                unsetenv("GROK_HOME")
            }
        }

        let sessionsRoot = grokHome.appendingPathComponent("sessions", isDirectory: true)
        func writeHistory(cwd: String, sessionId: String, prompt: String) throws {
            let historyURL = sessionsRoot
                .appendingPathComponent(GrokSessionLocator.encodedSessionCWD(cwd), isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent("chat_history.jsonl", isDirectory: false)
            try FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try #"{"type":"user","content":"\#(prompt)","model":"grok-4"}"#
                .write(to: historyURL, atomically: true, encoding: .utf8)
        }

        try writeHistory(cwd: "/tmp/current grok search", sessionId: "current-session", prompt: "current")
        try writeHistory(cwd: "/tmp/other grok search", sessionId: "other-session", prompt: "other")

        let store = SessionIndexStore()
        store.setCurrentDirectoryIfChanged("/tmp/current grok search")
        let outcome = await store.searchSessions(
            query: "",
            scope: .agent(.grok),
            offset: 0,
            limit: 10
        )

        XCTAssertEqual(outcome.entries.map(\.sessionId), ["current-session"])
        XCTAssertEqual(outcome.entries.first?.cwd, "/tmp/current grok search")
    }

    func testPiVaultAgentSnapshotRoundTripBuildsTargetedSessionCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionPath = tempDir
            .appendingPathComponent("--tmp-pi repo--", isDirectory: true)
            .appendingPathComponent("2026-05-05T12-00-00-000Z_018f2b35-7c75-7e1a-a6ff-cc1d5f9f0000.jsonl")
            .path
        let panelId = UUID(uuidString: "3D4D5F4B-CA09-4E5C-A65E-8423D7F4BEA0")!
        let piKind = try XCTUnwrap(RestorableAgentKind(rawValue: "pi"))

        var snapshot = makeSnapshot()
        snapshot.windows[0].tabManager.workspaces[0].focusedPanelId = panelId
        snapshot.windows[0].tabManager.workspaces[0].layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)
        )
        snapshot.windows[0].tabManager.workspaces[0].panels = [
            SessionPanelSnapshot(
                id: panelId,
                type: .terminal,
                title: "Pi",
                customTitle: nil,
                directory: "/tmp/pi repo",
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: "ttys001",
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: "/tmp/pi repo",
                    scrollback: nil,
                    agent: SessionRestorableAgentSnapshot(
                        kind: piKind,
                        sessionId: sessionPath,
                        workingDirectory: "/tmp/pi repo",
                        launchCommand: AgentLaunchCommandSnapshot(
                            launcher: "pi",
                            executablePath: "/opt/homebrew/bin/pi",
                            arguments: ["/opt/homebrew/bin/pi", "--session-dir", tempDir.path, "--session", "old-session", "--continue"],
                            workingDirectory: "/tmp/pi repo",
                            environment: ["PI_CODING_AGENT_SESSION_DIR": tempDir.path],
                            capturedAt: 1_777_777_777,
                            source: "process"
                        ),
                        registration: CmuxVaultAgentRegistration.builtInPi
                    ),
                    tmuxStartCommand: nil
                ),
                browser: nil,
                markdown: nil,
                filePreview: nil,
                rightSidebarTool: nil
            )
        ]

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let store = SessionSnapshotRepository<AppSessionSnapshot>(
            schemaVersion: AppSessionSnapshot.currentSchemaVersion,
            bundleIdentifier: "com.cmuxterm.tests"
        )
        XCTAssertTrue(store.save(snapshot, fileURL: snapshotURL))
        let loadedAgent = try XCTUnwrap(
            store.load(fileURL: snapshotURL)?.windows.first?
                .tabManager.workspaces.first?.panels.first?.terminal?.agent
        )

        XCTAssertEqual(loadedAgent.kind.rawValue, "pi")
        XCTAssertEqual(loadedAgent.sessionId, sessionPath)
        XCTAssertEqual(
            loadedAgent.resumeCommand,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "'env' 'PI_CODING_AGENT_SESSION_DIR=\(tempDir.path)' '/opt/homebrew/bin/pi' '--session' '\(sessionPath)' '--session-dir' '\(tempDir.path)'",
                workingDirectory: "/tmp/pi repo"
            )
        )
    }

    private func makeSnapshot() -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        return AppSessionSnapshot(
            version: AppSessionSnapshot.currentSchemaVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
                )
            ]
        )
    }
}
