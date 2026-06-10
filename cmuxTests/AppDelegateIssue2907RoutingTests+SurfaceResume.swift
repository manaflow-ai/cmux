import XCTest
import AppKit
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Surface Resume
extension AppDelegateIssue2907RoutingTests {
    func testSurfaceResumeSetRejectsSurfaceOutsideExplicitWindow() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let firstWindowId = UUID()
        let secondWindowId = UUID()
        let firstWindow = makeMainWindow(id: firstWindowId)
        let secondWindow = makeMainWindow(id: secondWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            app.unregisterMainWindowContextForTesting(windowId: secondWindowId)
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            firstWindow,
            windowId: firstWindowId,
            tabManager: firstManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            secondWindow,
            windowId: secondWindowId,
            tabManager: secondManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(firstManager)

        let secondWorkspace = try XCTUnwrap(secondManager.selectedWorkspace)
        let secondPanelId = try XCTUnwrap(secondWorkspace.focusedPanelId)
        let (raw, envelope) = try v2Envelope(
            method: "surface.resume.set",
            params: [
                "window_id": firstWindowId.uuidString,
                "surface_id": secondPanelId.uuidString,
                "command": "echo wrong-window"
            ]
        )

        XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
        XCTAssertNil(secondWorkspace.surfaceResumeBinding(panelId: secondPanelId))
    }

    func testSurfaceResumeRejectsMalformedSurfaceOrTabIdWithoutFocusedFallback() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(command: "echo keep", source: "test"),
            panelId: panelId
        ))

        for key in ["surface_id", "tab_id"] {
            for method in ["surface.resume.set", "surface.resume.get", "surface.resume.clear"] {
                var params: [String: Any] = [
                    "window_id": windowId.uuidString,
                    key: "not-a-surface"
                ]
                if method == "surface.resume.set" {
                    params["command"] = "echo bad"
                }

                let (raw, envelope) = try v2Envelope(method: method, params: params)

                XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
                let error = try XCTUnwrap(envelope["error"] as? [String: Any], raw)
                XCTAssertEqual(error["code"] as? String, "invalid_params", raw)
                XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.command, "echo keep")
            }
        }
    }

    func testSurfaceResumeUsesTabIdAliasForTargetSurface() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let focusedPanel = try XCTUnwrap(workspace.terminalPanel(for: focusedPanelId))
        let splitPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: focusedPanel.id,
            orientation: .horizontal,
            focus: false
        ))

        let setResult = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "tab_id": splitPanel.id.uuidString,
                "command": "tmux attach -t alias-target",
                "checkpoint_id": "alias-target",
            ]
        )
        XCTAssertEqual(setResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: focusedPanel.id))
        XCTAssertEqual(
            workspace.surfaceResumeBinding(panelId: splitPanel.id)?.command,
            "tmux attach -t alias-target"
        )

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "tab_id": splitPanel.id.uuidString,
            ]
        )
        XCTAssertEqual(getResult["surface_id"] as? String, splitPanel.id.uuidString)
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        XCTAssertEqual(getBinding["checkpoint_id"] as? String, "alias-target")

        let clearResult = try v2Result(
            method: "surface.resume.clear",
            params: [
                "window_id": windowId.uuidString,
                "tab_id": splitPanel.id.uuidString,
                "checkpoint_id": "alias-target",
            ]
        )
        XCTAssertEqual(clearResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertEqual(clearResult["cleared"] as? Bool, true)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: splitPanel.id))
    }

    func testSurfaceResumePayloadIncludesEnvironment() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let environment = [
            "EMPTY": "",
            "SPACED": "  keep exact  ",
            "ANTHROPIC_API_KEY": "should-not-persist",
        ]
        let setResult = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "command": "tmux attach -t dogfood",
                "environment": environment,
            ]
        )
        let setBinding = try XCTUnwrap(setResult["resume_binding"] as? [String: Any])
        let setEnvironment = try XCTUnwrap(setBinding["environment"] as? [String: Any])
        XCTAssertEqual(setEnvironment["EMPTY"] as? String, "")
        XCTAssertEqual(setEnvironment["SPACED"] as? String, "  keep exact  ")
        XCTAssertNil(setEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(setBinding["auto_resume"] as? Bool, false)

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        let getEnvironment = try XCTUnwrap(getBinding["environment"] as? [String: Any])
        XCTAssertEqual(getEnvironment["EMPTY"] as? String, "")
        XCTAssertEqual(getEnvironment["SPACED"] as? String, "  keep exact  ")
        XCTAssertNil(getEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(getBinding["auto_resume"] as? Bool, false)
    }

    func testSurfaceResumeSetCannotEnableAutoResumeFromSocket() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let result = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "command": "tmux attach -t sticky",
                "source": "process-detected",
                "auto_resume": true,
            ]
        )

        let binding = try XCTUnwrap(result["resume_binding"] as? [String: Any])
        XCTAssertEqual(binding["auto_resume"] as? Bool, false)
        XCTAssertEqual(binding["source"] as? String, "manual")
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume, false)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.source, "manual")
    }

    func testSurfaceResumeSetAllowsAgentHookAutoResume() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let result = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "command": "codex resume session",
                "source": "agent-hook",
                "auto_resume": true,
            ]
        )

        let binding = try XCTUnwrap(result["resume_binding"] as? [String: Any])
        XCTAssertEqual(binding["auto_resume"] as? Bool, true)
        XCTAssertEqual(binding["source"] as? String, "agent-hook")
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.allowsAutomaticResume, true)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.source, "agent-hook")
    }

    func testSurfaceResumeClearCheckpointGuardKeepsDifferentBinding() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        _ = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "surface_id": panelId.uuidString,
                "command": "codex resume new-session",
                "checkpoint_id": "new-session",
                "source": "agent-hook",
            ]
        )

        let clearResult = try v2Result(
            method: "surface.resume.clear",
            params: [
                "window_id": windowId.uuidString,
                "surface_id": panelId.uuidString,
                "checkpoint_id": "old-session",
                "source": "agent-hook",
            ]
        )

        XCTAssertEqual(clearResult["cleared"] as? Bool, false)
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: panelId)?.checkpointId, "new-session")
    }

    func testSurfaceResumeSetUsesLiveSurfaceWhenWorkspaceIdIsOmittedAfterMove() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanel = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(sourceWorkspace.newTerminalSplit(
            from: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ))
        let moved = try v2Result(
            method: "pane.break",
            params: [
                "surface_id": splitPanel.id.uuidString,
                "focus": false,
            ]
        )
        let destinationWorkspaceId = try XCTUnwrap(moved["workspace_id"] as? String)
        let destinationWorkspace = try XCTUnwrap(
            manager.tabs.first { $0.id.uuidString == destinationWorkspaceId }
        )

        _ = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "surface_id": splitPanel.id.uuidString,
                "command": "tmux attach -t moved",
                "source": "agent-hook",
            ]
        )

        XCTAssertNil(sourceWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
        XCTAssertEqual(
            destinationWorkspace.surfaceResumeBinding(panelId: splitPanel.id)?.command,
            "tmux attach -t moved"
        )
    }

    func testSurfaceResumeSetRejectsMismatchedWorkspaceScopeAfterMove() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let sourceWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanel = try XCTUnwrap(sourceWorkspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(sourceWorkspace.newTerminalSplit(
            from: sourcePanel.id,
            orientation: .horizontal,
            focus: false
        ))
        let moved = try v2Result(
            method: "pane.break",
            params: [
                "surface_id": splitPanel.id.uuidString,
                "focus": false,
            ]
        )
        let destinationWorkspaceId = try XCTUnwrap(moved["workspace_id"] as? String)
        let destinationWorkspace = try XCTUnwrap(
            manager.tabs.first { $0.id.uuidString == destinationWorkspaceId }
        )

        let (raw, envelope) = try v2Envelope(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": sourceWorkspace.id.uuidString,
                "surface_id": splitPanel.id.uuidString,
                "command": "tmux attach -t moved",
                "source": "agent-hook",
            ]
        )

        XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
        XCTAssertNil(sourceWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
        XCTAssertNil(destinationWorkspace.surfaceResumeBinding(panelId: splitPanel.id))
    }
}
