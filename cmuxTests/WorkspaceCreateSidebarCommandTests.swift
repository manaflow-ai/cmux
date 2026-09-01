import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateSidebarCommandTests {
    @Test func workspaceCreateCommandUsesNameAndSelectedCwdAndReportsInput() throws {
        let manager = TabManager()
        let selected = try #require(manager.selectedWorkspace)
        selected.currentDirectory = "/tmp"
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))

        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        let result = TerminalController.shared.v2WorkspaceCreate(
            params: [
                "name": "Sidebar Task",
                "cwd": ".",
                "command": "echo hello",
            ],
            tabManager: manager
        )

        let createdID = try #require(Self.workspaceID(from: result))
        let created = try #require(manager.tabs.first { $0.id == createdID })
        #expect(created.title == "Sidebar Task")
        #expect(created.currentDirectory == "/tmp")

        let inputEvents = CmuxEventBus.shared.retainedSnapshot().filter {
            $0["name"] as? String == "surface.input_sent"
        }
        #expect(inputEvents.count == 1)
        let payload = try #require(inputEvents.first?["payload"] as? [String: Any])
        #expect(payload["workspace_id"] as? String == createdID.uuidString)
        #expect(payload["text_length"] as? Int == "echo hello\r".count)

        #expect(Set(manager.tabs.map(\.id)).subtracting(initialWorkspaceIDs) == [createdID])
    }

    @Test func unsupportedWorkspaceCreateParameterFailsBeforeMutation() {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))

        let result = TerminalController.shared.v2WorkspaceCreate(
            params: ["unsupported_parameter": "value"],
            tabManager: manager
        )

        guard case let .err(code, message, data) = result else {
            Issue.record("workspace.create accepted an unsupported parameter")
            return
        }
        #expect(code == "unsupported_param")
        #expect(message.contains("unsupported_parameter"))
        #expect((data as? [String: Any])?["unsupported_param"] as? String == "unsupported_parameter")
        #expect(Set(manager.tabs.map(\.id)) == initialWorkspaceIDs)
    }

    private static func workspaceID(from result: TerminalController.V2CallResult) -> UUID? {
        guard case let .ok(payload) = result,
              let object = payload as? [String: Any],
              let rawID = object["workspace_id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }
}
