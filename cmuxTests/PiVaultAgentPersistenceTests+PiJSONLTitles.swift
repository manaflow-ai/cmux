import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Pi JSONL title extraction
extension PiVaultAgentPersistenceTests {
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

}
