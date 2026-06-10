import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Built-in agent registrations
extension PiVaultAgentPersistenceTests {
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
            "{ cd -- '/tmp/antigravity repo' 2>/dev/null || [ ! -d '/tmp/antigravity repo' ]; } && 'agy' '--conversation' 'antigravity-conversation-123'"
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
            "{ cd -- '/tmp/antigravity repo' 2>/dev/null || [ ! -d '/tmp/antigravity repo' ]; } && 'agy' '--conversation' 'conversation-b'"
        )
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

}
