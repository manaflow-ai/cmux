import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Mobile host RPC scoping and attach tickets
extension TerminalOffscreenStartupTests {
    func testMobileTerminalInputReportsRejectedClosedSurface() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        panel.surface.releaseSurfaceForTesting()
        panel.surface.beginPortalCloseLifecycle(reason: "test.mobile.closed")

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "input",
                method: "terminal.input",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": panel.id.uuidString,
                    "text": "echo dropped\r",
                ],
                auth: nil
            )
        )

        guard case let .failure(error) = response else {
            XCTFail("Expected closed mobile terminal input to fail")
            return
        }
        XCTAssertEqual(error.code, "surface_unavailable")
    }

    func testMobileHostNetworkStatusDoesNotExposePrivateMetadata() async throws {
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "status",
                method: "mobile.host.status",
                params: [:],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any] else {
            XCTFail("Expected mobile host status to succeed without auth")
            return
        }
        XCTAssertNotNil(payload["routes"])
        XCTAssertNil(payload["mac_device_id"])
        XCTAssertNil(payload["mac_display_name"])
        XCTAssertNil(payload["host_service"])
        XCTAssertNil(payload["workspace_count"])
    }

    func testMobileRPCRejectsMalformedWorkspaceIDBeforeImplicitFallback() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminal = try XCTUnwrap(workspace.focusedTerminalPanel)
        let badWorkspaceID = "workspace:not-a-uuid"
        let requests: [(method: String, params: [String: Any])] = [
            (
                method: "mobile.attach_ticket.create",
                params: ["workspace_id": badWorkspaceID]
            ),
            (
                method: "terminal.create",
                params: ["workspace_id": badWorkspaceID]
            ),
            (
                method: "terminal.input",
                params: [
                    "workspace_id": badWorkspaceID,
                    "terminal_id": terminal.id.uuidString,
                    "text": "echo should-not-send\n",
                ]
            ),
        ]

        for request in requests {
            let response = await TerminalController.shared.mobileHostHandleRPC(
                MobileHostRPCRequest(
                    id: request.method,
                    method: request.method,
                    params: request.params,
                    auth: nil
                )
            )

            guard case let .failure(error) = response else {
                XCTFail("\(request.method) should reject malformed workspace_id")
                continue
            }
            XCTAssertEqual(error.code, "invalid_params", request.method)
        }
    }

    func testMobileWorkspaceListRejectsMissingScopedTargets() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let missingWorkspaceID = UUID()
        let missingTerminalID = UUID()

        let missingWorkspaceResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "workspace-list-missing-workspace",
                method: "workspace.list",
                params: ["workspace_id": missingWorkspaceID.uuidString],
                auth: nil
            )
        )
        guard case let .failure(missingWorkspaceError) = missingWorkspaceResponse else {
            XCTFail("Expected stale mobile workspace scope to fail")
            return
        }
        XCTAssertEqual(missingWorkspaceError.code, "not_found")

        let missingTerminalResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "workspace-list-missing-terminal",
                method: "workspace.list",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": missingTerminalID.uuidString,
                ],
                auth: nil
            )
        )
        guard case let .failure(missingTerminalError) = missingTerminalResponse else {
            XCTFail("Expected stale mobile terminal scope to fail")
            return
        }
        XCTAssertEqual(missingTerminalError.code, "not_found")
    }

    func testMobileAttachTicketCreateWithoutTerminalStaysWorkspaceScoped() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        MobileHostService.shared.start()
        defer {
            MobileHostService.shared.stop()
        }
        guard await waitForMobileHostRoutesForTesting() else {
            XCTFail("Expected mobile host to publish routes before creating attach ticket")
            return
        }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "attach-ticket",
                method: "mobile.attach_ticket.create",
                params: ["workspace_id": workspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let ticket = payload["ticket"] as? [String: Any] else {
            XCTFail("Expected workspace-scoped attach ticket payload")
            return
        }
        XCTAssertNil(ticket["terminalID"])
    }

    func testMobileAttachTicketCreateResolvesTerminalIDAcrossWorkspaces() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        MobileHostService.shared.start()
        defer {
            MobileHostService.shared.stop()
        }
        guard await waitForMobileHostRoutesForTesting() else {
            XCTFail("Expected mobile host to publish routes before creating attach ticket")
            return
        }

        let selectedWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let backgroundWorkspace = manager.addWorkspace(
            title: "Mobile Background",
            select: false,
            eagerLoadTerminal: false
        )
        let backgroundTerminal = try XCTUnwrap(backgroundWorkspace.focusedTerminalPanel)
        XCTAssertEqual(manager.selectedWorkspace?.id, selectedWorkspace.id)
        XCTAssertNotEqual(selectedWorkspace.id, backgroundWorkspace.id)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "attach-ticket",
                method: "mobile.attach_ticket.create",
                params: ["terminal_id": backgroundTerminal.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let ticket = payload["ticket"] as? [String: Any] else {
            XCTFail("Expected terminal-scoped attach ticket payload")
            return
        }
        XCTAssertEqual(ticket["workspaceID"] as? String, backgroundWorkspace.id.uuidString)
        XCTAssertEqual(ticket["terminalID"] as? String, backgroundTerminal.id.uuidString)
    }

    func testMobileAttachTicketCreateCanFilterRoutesForQRPairing() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        MobileHostService.shared.start()
        defer {
            MobileHostService.shared.stop()
        }
        guard await waitForMobileHostRoutesForTesting() else {
            XCTFail("Expected mobile host to publish routes before creating attach ticket")
            return
        }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "attach-ticket",
                method: "mobile.attach_ticket.create",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "route_id": "debug_loopback",
                ],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let ticket = payload["ticket"] as? [String: Any],
              let routes = ticket["routes"] as? [[String: Any]] else {
            XCTFail("Expected route-filtered attach ticket payload")
            return
        }
        XCTAssertFalse(routes.isEmpty)
        XCTAssertTrue(routes.allSatisfy { $0["id"] as? String == "debug_loopback" })
        let topLevelRoutes = try XCTUnwrap(payload["routes"] as? [[String: Any]])
        XCTAssertEqual(topLevelRoutes.count, routes.count)
        XCTAssertTrue(topLevelRoutes.allSatisfy { $0["id"] as? String == "debug_loopback" })
    }

    func testMobileTerminalCreateReturnsBeforeStartingGhostty() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "terminal-create",
                method: "terminal.create",
                params: ["workspace_id": workspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let terminalID = payload["created_terminal_id"] as? String,
              let terminalUUID = UUID(uuidString: terminalID),
              let terminalPanel = workspace.terminalPanel(for: terminalUUID) else {
            XCTFail("Expected created terminal in mobile workspace list payload")
            return
        }
        defer {
            terminalPanel.surface.teardownSurface()
        }

        XCTAssertFalse(
            terminalPanel.surface.debugBackgroundSurfaceStartQueuedForTesting(),
            "Mobile terminal creation must return the new terminal ID without waiting on hidden Ghostty startup."
        )
        XCTAssertEqual(
            terminalPanel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "The first mobile snapshot request owns lazy startup so terminal.create remains a fast metadata-only operation."
        )
    }

#if DEBUG
    func testMobileWorkspaceCreateSkipsHiddenMacSideWorkAndReturnsCreatedScopeOnly() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = RecordingMobileTabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let selectedWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        manager.clearScheduledMetadataRefreshesForTesting()

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "workspace-create",
                method: "workspace.create",
                params: ["title": "Created From iOS"],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let createdWorkspaceID = payload["created_workspace_id"] as? String,
              let createdUUID = UUID(uuidString: createdWorkspaceID),
              let workspaces = payload["workspaces"] as? [[String: Any]] else {
            XCTFail("Expected mobile workspace.create to return the created workspace payload")
            return
        }

        XCTAssertEqual(manager.selectedWorkspace?.id, selectedWorkspace.id)
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?["id"] as? String, createdWorkspaceID)
        XCTAssertTrue(manager.tabs.contains { $0.id == createdUUID })
        XCTAssertTrue(
            manager.scheduledMetadataRefreshes.isEmpty,
            "Mobile background workspace creation should not schedule sidebar metadata probes on the macOS main path."
        )
    }

    func testMobileTerminalCreateSkipsHiddenMacSideWorkAndKeepsMacSelection() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = RecordingMobileTabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let selectedWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let mobileWorkspace = manager.addWorkspace(
            title: "Mobile Hidden Workspace",
            select: false,
            eagerLoadTerminal: false,
            autoRefreshMetadata: false
        )
        manager.clearScheduledMetadataRefreshesForTesting()

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "terminal-create",
                method: "terminal.create",
                params: ["workspace_id": mobileWorkspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let createdTerminalID = payload["created_terminal_id"] as? String,
              let createdTerminalUUID = UUID(uuidString: createdTerminalID),
              let workspaces = payload["workspaces"] as? [[String: Any]] else {
            XCTFail("Expected mobile terminal.create to return the created terminal payload")
            return
        }

        XCTAssertEqual(manager.selectedWorkspace?.id, selectedWorkspace.id)
        XCTAssertNotNil(mobileWorkspace.terminalPanel(for: createdTerminalUUID))
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?["id"] as? String, mobileWorkspace.id.uuidString)
        XCTAssertTrue(
            manager.scheduledMetadataRefreshes.isEmpty,
            "Mobile background terminal creation should not schedule sidebar metadata probes on the macOS main path."
        )
    }
#endif

}
