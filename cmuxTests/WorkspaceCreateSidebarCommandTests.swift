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
        let event = try #require(inputEvents.first)
        #expect(event["workspace_id"] as? String == createdID.uuidString)
        let payload = try #require(event["payload"] as? [String: Any])
        let params = try #require(payload["params"] as? [String: Any])
        #expect(params["workspace_id"] as? String == createdID.uuidString)
        #expect(params["text_length"] as? Int == "echo hello\r".count)
        let deliveryResult = try #require(payload["result"] as? [String: Any])
        #expect(deliveryResult["workspace_ref"] as? String != nil)
        #expect(deliveryResult["surface_ref"] as? String != nil)

        let resultObject = try #require(Self.resultObject(from: result))
        let commandDelivery = try #require(resultObject["command_delivery"] as? [String: Any])
        #expect(commandDelivery["accepted"] as? Bool == true)

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

    @Test func emptyWorkingDirectoryAliasFallsBackToCwd() throws {
        let manager = TabManager()
        let result = TerminalController.shared.v2WorkspaceCreate(
            params: ["working_directory": "", "cwd": "/tmp"],
            tabManager: manager
        )

        let createdID = try #require(Self.workspaceID(from: result))
        let created = try #require(manager.tabs.first { $0.id == createdID })
        #expect(created.currentDirectory == "/tmp")
    }

    @Test func mobileValidationReceivesRawRelativeCwdBeforeCanonicalization() async throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let recorder = RelativeCwdValidationRecorder()

        let result = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["cwd": "."],
            workingDirectoryValidator: { rawValue, isProvided in
                await recorder.record(rawValue: rawValue, isProvided: isProvided)
                return .invalid
            },
            tabManager: manager
        )

        let recordedRawValue = await recorder.rawValue
        let recordedIsProvided = await recorder.isProvided
        #expect(recordedRawValue == ".")
        #expect(recordedIsProvided)
        guard case let .err(code, _, _) = result else {
            Issue.record("relative cwd reached workspace creation")
            return
        }
        #expect(code == "invalid_working_directory")
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

    private static func resultObject(from result: TerminalController.V2CallResult) -> [String: Any]? {
        guard case let .ok(payload) = result else { return nil }
        return payload as? [String: Any]
    }
}

private actor RelativeCwdValidationRecorder {
    private(set) var rawValue: String?
    private(set) var isProvided = false

    func record(rawValue: String?, isProvided: Bool) {
        self.rawValue = rawValue
        self.isProvided = isProvided
    }
}
