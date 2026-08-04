import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Tab color actions", .serialized)
struct TabColorActionTests {
    @Test("tab.action sets and clears one surface color without changing focus")
    func setAndClearColor() throws {
        let controller = TerminalController.shared
        let previousManager = controller.activeTabManagerForCallerNotification()
        let manager = TabManager()
        let targetWorkspace = try #require(manager.selectedWorkspace)
        let targetSurfaceID = try #require(targetWorkspace.focusedPanelId)
        let selectedWorkspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        controller.setActiveTabManager(manager)

        defer {
            manager.tabs.forEach { $0.teardownAllPanels() }
            controller.setActiveTabManager(previousManager)
        }

        let coordinator = ControlCommandCoordinator(context: controller)
        let routingParams: [String: JSONValue] = [
            "workspace_id": .string(targetWorkspace.id.uuidString),
            "surface_id": .string(targetSurfaceID.uuidString),
        ]

        let setResult = coordinator.handle(ControlRequest(
            id: .string("set-color"),
            method: "tab.action",
            params: routingParams.merging([
                "action": .string("set-color"),
                "color": .string("#7A4FD8"),
            ]) { _, new in new }
        ))

        guard case .ok(.object(let setPayload)) = setResult else {
            Issue.record("Expected tab.action set-color to succeed, got \(setResult)")
            return
        }
        #expect(setPayload["color"] == .string("#7A4FD8"))
        #expect(manager.selectedTabId == selectedWorkspace.id)
        #expect(try surfaceColor(coordinator: coordinator, params: routingParams) == .string("#7A4FD8"))
        #expect(
            targetWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first(where: { $0.id == targetSurfaceID })?.customColor == "#7A4FD8"
        )

        let clearResult = coordinator.handle(ControlRequest(
            id: .string("clear-color"),
            method: "tab.action",
            params: routingParams.merging([
                "action": .string("clear-color"),
            ]) { _, new in new }
        ))

        guard case .ok(.object(let clearPayload)) = clearResult else {
            Issue.record("Expected tab.action clear-color to succeed, got \(clearResult)")
            return
        }
        #expect(clearPayload["color"] == .null)
        #expect(manager.selectedTabId == selectedWorkspace.id)
        #expect(try surfaceColor(coordinator: coordinator, params: routingParams) == .null)
        #expect(
            targetWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first(where: { $0.id == targetSurfaceID })?.customColor == nil
        )
    }

    private func surfaceColor(
        coordinator: ControlCommandCoordinator,
        params: [String: JSONValue]
    ) throws -> JSONValue {
        let result = coordinator.handle(ControlRequest(
            id: .string("surface-list"),
            method: "surface.list",
            params: ["workspace_id": params["workspace_id"] ?? .null]
        ))
        guard case .ok(.object(let payload)) = result,
              case .array(let surfaces)? = payload["surfaces"],
              case .object(let surface)? = surfaces.first(where: { row in
                  guard case .object(let fields) = row else { return false }
                  return fields["id"] == params["surface_id"]
              }),
              let color = surface["custom_color"] else {
            throw TabColorTestError.missingSurfaceColor(result)
        }
        return color
    }
}

private enum TabColorTestError: Error {
    case missingSurfaceColor(ControlCallResult?)
}
