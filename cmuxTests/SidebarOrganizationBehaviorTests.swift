import CmuxFoundation
import CmuxExtensionKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarOrganizationBehaviorTests {
    private let workspaceID = UUID(uuidString: "DEAD0001-0000-4000-8000-000000000001")!

    private func input(rejected: [String] = []) -> SidebarOrganizationInput {
        .init(id: UUID(), windowID: UUID(), createdAt: Date(), workspaces: [
            .init(id: workspaceID.uuidString, title: "Inventory", revision: 3, groupId: nil,
                tags: [], aliases: [], summary: nil, rejectedAutomaticTagIDs: [],
                rejectedSourceFingerprints: rejected, sessions: [])
        ])
    }

    @Test func structuredEngineDiagnosticsDoNotDiscardAValidResponse() throws {
        let data = Data(#"{"schemaVersion":1,"proposals":[],"diagnostics":[{"code":"rejected-source-fingerprint","workspaceId":"exact-workspace"}]}"#.utf8)
        let result = try JSONDecoder().decode(SidebarOrganizationOutput.self, from: data)
        #expect(result.diagnostics.first?.code == "rejected-source-fingerprint")
        #expect(result.proposals.isEmpty)
    }

    @Test(arguments: [Int32(1), Int32(7)])
    func aFailedProcessCannotApplyItsOutput(exitStatus: Int32) async throws {
        let commands = EngineCommands(exitStatus: exitStatus)
        let service = SidebarOrganizationService(commands: commands, homeDirectory: URL(fileURLWithPath: "/nonexistent-fixture-home"), pythonCandidates: ["fixture-python"])
        await #expect(throws: SidebarOrganizationService.Failure.self) { _ = try await service.analyze(input(), review: nil) }
        #expect(await commands.engineCalls == 1)
    }

    @Test(arguments: ["timeout", "output-limit", "old-python"])
    func unavailableEngineNeverReturnsAnOldProposal(failure: String) async throws {
        let commands = EngineCommands(timedOut: failure == "timeout", oversized: failure == "output-limit", pythonAvailable: failure != "old-python")
        let service = SidebarOrganizationService(commands: commands, homeDirectory: URL(fileURLWithPath: "/nonexistent-fixture-home"), pythonCandidates: ["fixture-python"])
        await #expect(throws: SidebarOrganizationService.Failure.self) { _ = try await service.analyze(input(), review: nil) }
        #expect(await commands.engineCalls == (failure == "old-python" ? 0 : 1))
    }

    @Test func localClassificationRunsWithoutTheCortexPublisher() async throws {
        let commands = EngineCommands()
        let service = SidebarOrganizationService(commands: commands, homeDirectory: URL(fileURLWithPath: "/nonexistent-fixture-home"), pythonCandidates: ["fixture-python"])
        let result = try await service.analyze(input(), review: nil)
        #expect(result.schemaVersion == 1)
        #expect(result.diagnostics.first?.code == "unchanged-cache")
        #expect(await commands.engineCalls == 1)
    }

    @Test func duplicateNativeInventoryIsRefusedBeforeAnySubprocess() async {
        let commands = EngineCommands()
        let service = SidebarOrganizationService(commands: commands, pythonCandidates: ["fixture-python"])
        var duplicate = input(); duplicate.workspaces += duplicate.workspaces
        await #expect(throws: SidebarOrganizationService.Failure.self) { _ = try await service.analyze(duplicate, review: nil) }
        #expect(await commands.engineCalls == 0)
    }

    @Test func unsupportedProvidersCannotBorrowAnotherTranscript() {
        let reader = SidebarOrganizationContextReader(homeDirectory: URL(fileURLWithPath: "/nonexistent-fixture-home"))
        #expect(reader.read(.init(toolId: "commandcode", sessionId: UUID().uuidString, directory: nil, title: "Same project", context: nil), maximumCharacters: 6_000) == nil)
        #expect(reader.read(.init(toolId: "opencode", sessionId: "ses_exact", directory: nil, title: "Same project", context: nil), maximumCharacters: 6_000) == nil)
    }

    @Test
    func exactTranscriptCannotBorrowSiblingSIDAndContextIsBounded() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-context-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sid = UUID().uuidString
        let other = UUID().uuidString
        let file = home.appendingPathComponent(".codex/sessions/rollout-" + sid + ".jsonl")
        func transcript(_ identity: String) throws -> Data {
            let rows: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": identity]],
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": String(repeating: "x", count: 8_000)]]]]
            ]
            return try rows.reduce(into: Data()) { data, row in data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        }
        let reader = SidebarOrganizationContextReader(homeDirectory: home)
        let session = SidebarOrganizationInput.Session(toolId: "codex", sessionId: sid, directory: nil, title: "Project", context: nil)
        try transcript(other).write(to: file)
        #expect(reader.read(session, maximumCharacters: 100) == nil)
        try transcript(sid).write(to: file)
        #expect(reader.read(session, maximumCharacters: 100)?.recentMessages.first?.text.count == 100)
        let duplicate = home.appendingPathComponent(".codex/sessions/duplicate-" + sid + ".jsonl")
        try transcript(sid).write(to: duplicate)
        #expect(reader.read(session, maximumCharacters: 100) == nil)
    }

    private actor EngineCommands: CommandRunning {
        let exitStatus: Int32
        let timedOut: Bool
        let oversized: Bool
        let pythonAvailable: Bool
        private(set) var engineCalls = 0
        init(exitStatus: Int32 = 0, timedOut: Bool = false, oversized: Bool = false, pythonAvailable: Bool = true) {
            self.exitStatus = exitStatus; self.timedOut = timedOut; self.oversized = oversized; self.pythonAvailable = pythonAvailable
        }
        func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
            if arguments.first == "-c" { return .init(stdout: "", stderr: "", exitStatus: pythonAvailable ? 0 : 1, timedOut: false, executionError: nil) }
            engineCalls += 1
            if let offset = arguments.firstIndex(of: "--output"), arguments.indices.contains(offset + 1) {
                try? Data(#"{"schemaVersion":1,"proposals":[],"diagnostics":[{"code":"unchanged-cache"}]}"#.utf8).write(to: URL(fileURLWithPath: arguments[offset + 1]))
            }
            return .init(stdout: oversized ? String(repeating: "x", count: 65_537) : "", stderr: "", exitStatus: exitStatus, timedOut: timedOut, executionError: nil)
        }
    }
}
