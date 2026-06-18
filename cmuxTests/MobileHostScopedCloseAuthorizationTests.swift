import CMUXMobileCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostScopedCloseAuthorizationTests {
    #if DEBUG
    @Test func workspaceCloseRejectsMissingAttachTokenAfterStackAuth() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            MobileHostService.shared.debugConfigureAcceptedStackAuthTokenForTesting(nil)
            MobileHostService.shared.debugResetMobileLifecycleStateForTesting()
        }

        let service = MobileHostService.shared
        service.stop()
        service.debugResetMobileLifecycleStateForTesting()
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")

        let workspace = try #require(manager.selectedWorkspace)
        _ = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let request = MobileHostRPCRequest(
            id: "workspace-close",
            method: "workspace.close",
            params: ["workspace_id": workspace.id.uuidString],
            auth: MobileHostRPCAuth(
                attachToken: nil,
                stackAccessToken: "cmux-dev-token"
            )
        )
        let authResult = await service.debugAuthorizationError(for: request)
        #expect(authResult == nil)

        let response = await TerminalController.shared.mobileHostHandleRPC(request)

        guard case let .failure(error) = response else {
            return #expect(Bool(false), "workspace.close without an attach token should stay scoped even after Stack auth")
        }
        #expect(error.code == "protected")
        #expect(manager.tabs.contains(where: { $0.id == workspace.id }))
    }

    @Test func surfaceCloseRejectsMissingAttachTokenAfterStackAuth() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            MobileHostService.shared.debugConfigureAcceptedStackAuthTokenForTesting(nil)
            MobileHostService.shared.debugResetMobileLifecycleStateForTesting()
        }

        let service = MobileHostService.shared
        service.stop()
        service.debugResetMobileLifecycleStateForTesting()
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")

        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedTerminalPanel)
        let request = MobileHostRPCRequest(
            id: "surface-close",
            method: "surface.close",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": terminal.id.uuidString,
            ],
            auth: MobileHostRPCAuth(
                attachToken: nil,
                stackAccessToken: "cmux-dev-token"
            )
        )
        let authResult = await service.debugAuthorizationError(for: request)
        #expect(authResult == nil)

        let response = await TerminalController.shared.mobileHostHandleRPC(request)

        guard case let .failure(error) = response else {
            return #expect(Bool(false), "surface.close without an attach token should stay scoped even after Stack auth")
        }
        #expect(error.code == "protected")
        #expect(workspace.terminalPanel(for: terminal.id) != nil)
    }
    #endif
}
