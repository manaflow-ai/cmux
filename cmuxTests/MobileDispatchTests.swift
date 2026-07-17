import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileDispatchTests {
    @Test func commandBuilderPreservesPromptAsOneArgument() throws {
        let prompt = "it's a \"test\" $HOME `pwd`\nsecond line"
        let command = try DispatchAgentCommandBuilder().command(agent: .claude, prompt: prompt)
        #expect(command.hasSuffix("\n"))

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "claude() { printf '%s\\0' \"$@\"; }\n" + command]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        var expected = Data(prompt.utf8)
        expected.append(0)
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile() == expected)
    }

    @Test func commandBuilderEnforcesUTF8ByteBudget() throws {
        let accepted = String(repeating: "a", count: DispatchAgentCommandBuilder.promptByteBudget)
        let command = try DispatchAgentCommandBuilder().command(agent: .codex, prompt: accepted)
        #expect(command.hasSuffix("\n"))

        let rejected = String(repeating: "é", count: 451)
        do {
            _ = try DispatchAgentCommandBuilder().command(agent: .codex, prompt: rejected)
            Issue.record("Expected a prompt larger than 900 UTF-8 bytes to be rejected")
        } catch let error as DispatchAgentCommandBuilder.CommandError {
            #expect(error == .promptTooLong)
        }
    }

    @Test func workspaceScopedTicketAllowsDispatchMethods() throws {
        let ticket = try scopedAttachTicket()
        for method in ["mobile.dispatch.catalog", "mobile.dispatch.fs", "mobile.dispatch.launch"] {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: [:],
                auth: MobileHostRPCAuth(attachToken: ticket.authToken, stackAccessToken: nil)
            )
            #expect(MobileHostService.ticketAuthorizationError(ticket: ticket, request: request) == nil)
        }
    }

    @Test func filesystemListReturnsOnlySortedVisibleDirectories() async throws {
        let root = try temporaryDirectory(named: "list")
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("Alpha", isDirectory: true)
        let zeta = root.appendingPathComponent("zeta", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zeta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: root.appendingPathComponent("note.txt"))

        let response = await TerminalController.shared.mobileHostHandleRPC(MobileHostRPCRequest(
            id: "list",
            method: "mobile.dispatch.fs",
            params: ["op": "list", "path": root.path, "include_hidden": false],
            auth: nil
        ))
        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let entries = payload["entries"] as? [[String: Any]] else {
            return Issue.record("Expected directory list response")
        }
        #expect(entries.compactMap { $0["name"] as? String } == ["Alpha", "zeta"])
        #expect(entries.first?["path"] as? String == alpha.path)
        #expect(entries.first?["git"] as? Bool == true)
        #expect(payload["truncated"] as? Bool == false)

        let missing = await TerminalController.shared.mobileHostHandleRPC(MobileHostRPCRequest(
            id: "missing",
            method: "mobile.dispatch.fs",
            params: ["op": "list", "path": root.appendingPathComponent("absent").path],
            auth: nil
        ))
        #expect(errorCode(missing) == "not_found")
    }

    @Test func launchValidationReturnsStableErrorsWithoutSpawning() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let root = try temporaryDirectory(named: "launch")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = await dispatchLaunch(directory: root.appendingPathComponent("absent").path, prompt: "Fix it")
        #expect(errorCode(missing) == "directory_not_found")

        let empty = await dispatchLaunch(directory: root.path, prompt: "  \n ")
        #expect(errorCode(empty) == "invalid_params")

        let oversized = await dispatchLaunch(directory: root.path, prompt: String(repeating: "é", count: 451))
        #expect(errorCode(oversized) == "prompt_too_long")
    }

    @Test func directoryIndexRanksAndSkipsExpectedDirectories() async throws {
        let root = try temporaryDirectory(named: "index")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cmux"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/cmux"), withIntermediateDirectories: true)
        let gitProject = root.appendingPathComponent("git-parent/project", isDirectory: true)
        try FileManager.default.createDirectory(at: gitProject.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plain-parent/project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/secret-cmux"), withIntermediateDirectories: true)

        let index = DispatchDirectoryIndex(homeDirectory: root)
        await index.rebuild()

        let exact = await index.search(query: "cmux", limit: 10)
        #expect(exact.entries.first?.path == root.appendingPathComponent("cmux").path)
        let boosted = await index.search(query: "project", limit: 10)
        #expect(boosted.entries.first?.path == gitProject.path)
        let skipped = await index.search(query: "secret-cmux", limit: 10)
        #expect(skipped.entries.isEmpty)
    }

    private func dispatchLaunch(directory: String, prompt: String) async -> MobileHostRPCResult {
        await TerminalController.shared.mobileHostHandleRPC(MobileHostRPCRequest(
            id: "launch",
            method: "mobile.dispatch.launch",
            params: ["directory": directory, "agent_id": "claude", "prompt": prompt],
            auth: nil
        ))
    }

    private func errorCode(_ result: MobileHostRPCResult) -> String? {
        guard case let .failure(error) = result else { return nil }
        return error.code
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mobile-dispatch-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scopedAttachTicket() throws -> CmxAttachTicket {
        let route = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 58465)
        )
        return try CmxAttachTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: "ticket-secret"
        )
    }
}
