import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Registered agent JSONL metadata
extension PiVaultAgentPersistenceTests {
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
        XCTAssertEqual(entry.resumeCommand, "{ cd -- '/tmp/acme' 2>/dev/null || [ ! -d '/tmp/acme' ]; } && 'acme-agent' '--session' 'native-session-123'")
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

}
