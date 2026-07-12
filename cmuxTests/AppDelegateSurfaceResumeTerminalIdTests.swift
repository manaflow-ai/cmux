import AppKit
import Bonsplit
import CmuxTerminal
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateSurfaceResumeTerminalIdTests: XCTestCase {
    func testSurfaceResumeUsesTerminalIdAliasForTargetSurface() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        registerMainWindow(app: app, window: window, windowId: windowId, manager: manager)
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: focusedPanel.id,
            orientation: .horizontal,
            focus: false
        ))

        let setResult = try v2Result(method: "surface.resume.set", params: [
            "window_id": windowId.uuidString,
            "terminal_id": splitPanel.id.uuidString,
            "command": "codex resume terminal-target",
            "checkpoint_id": "terminal-target",
        ])
        XCTAssertEqual(setResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: focusedPanel.id))
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: splitPanel.id)?.command, "codex resume terminal-target")

        let getResult = try v2Result(method: "surface.resume.get", params: [
            "window_id": windowId.uuidString,
            "terminal_id": splitPanel.id.uuidString,
        ])
        XCTAssertEqual(getResult["surface_id"] as? String, splitPanel.id.uuidString)
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        XCTAssertEqual(getBinding["checkpoint_id"] as? String, "terminal-target")

        let clearResult = try v2Result(method: "surface.resume.clear", params: [
            "window_id": windowId.uuidString,
            "terminal_id": splitPanel.id.uuidString,
            "checkpoint_id": "terminal-target",
        ])
        XCTAssertEqual(clearResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertEqual(clearResult["cleared"] as? Bool, true)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: splitPanel.id))
    }

    func testSurfaceResumeSetAcceptsStableSurfaceIdForRestoredAgentBinding() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        registerMainWindow(app: app, window: window, windowId: windowId, manager: manager)
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let splitPanel = try XCTUnwrap(workspace.newTerminalSplit(
            from: focusedPanel.id,
            orientation: .horizontal,
            focus: false
        ))
        XCTAssertNotEqual(splitPanel.stableSurfaceId, splitPanel.id)

        let setResult = try v2Result(method: "surface.resume.set", params: [
            "window_id": windowId.uuidString,
            "workspace_id": workspace.id.uuidString,
            "surface_id": splitPanel.stableSurfaceId.uuidString,
            "kind": "codex",
            "source": "agent-hook",
            "auto_resume": true,
            "command": "codex resume stable-target",
            "checkpoint_id": "stable-target",
        ])

        XCTAssertEqual(setResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: focusedPanel.id))
        XCTAssertEqual(workspace.surfaceResumeBinding(panelId: splitPanel.id)?.command, "codex resume stable-target")

        let getResult = try v2Result(method: "surface.resume.get", params: [
            "window_id": windowId.uuidString,
            "workspace_id": workspace.id.uuidString,
            "surface_id": splitPanel.stableSurfaceId.uuidString,
        ])
        XCTAssertEqual(getResult["surface_id"] as? String, splitPanel.id.uuidString)
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        XCTAssertEqual(getBinding["checkpoint_id"] as? String, "stable-target")

        let clearResult = try v2Result(method: "surface.resume.clear", params: [
            "window_id": windowId.uuidString,
            "workspace_id": workspace.id.uuidString,
            "surface_id": splitPanel.stableSurfaceId.uuidString,
            "checkpoint_id": "stable-target",
        ])
        XCTAssertEqual(clearResult["surface_id"] as? String, splitPanel.id.uuidString)
        XCTAssertEqual(clearResult["cleared"] as? Bool, true)
        XCTAssertNil(workspace.surfaceResumeBinding(panelId: splitPanel.id))
    }

    func testSurfaceResumeGloballyLocatesStableSurfaceIdAcrossWindows() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let activeWindowId = UUID()
        let targetWindowId = UUID()
        let activeWindow = makeMainWindow(id: activeWindowId)
        let targetWindow = makeMainWindow(id: targetWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            app.unregisterMainWindowContextForTesting(windowId: activeWindowId)
            app.unregisterMainWindowContextForTesting(windowId: targetWindowId)
            activeWindow.orderOut(nil)
            targetWindow.orderOut(nil)
        }

        let activeManager = TabManager(autoWelcomeIfNeeded: false)
        let targetManager = TabManager(autoWelcomeIfNeeded: false)
        registerMainWindow(app: app, window: activeWindow, windowId: activeWindowId, manager: activeManager)
        registerMainWindow(app: app, window: targetWindow, windowId: targetWindowId, manager: targetManager)
        TerminalController.shared.setActiveTabManager(activeManager)

        let activeWorkspace = try XCTUnwrap(activeManager.selectedWorkspace)
        let activePanelId = try XCTUnwrap(activeWorkspace.focusedPanelId)
        let targetWorkspace = try XCTUnwrap(targetManager.selectedWorkspace)
        let targetPanel = try XCTUnwrap(targetWorkspace.focusedTerminalPanel)
        XCTAssertNotEqual(targetPanel.stableSurfaceId, targetPanel.id)

        let setResult = try v2Result(method: "surface.resume.set", params: [
            "surface_id": targetPanel.stableSurfaceId.uuidString,
            "kind": "codex",
            "source": "agent-hook",
            "auto_resume": true,
            "command": "codex resume cross-window-stable-target",
            "checkpoint_id": "cross-window-stable-target",
        ])

        XCTAssertEqual(setResult["surface_id"] as? String, targetPanel.id.uuidString)
        XCTAssertNil(activeWorkspace.surfaceResumeBinding(panelId: activePanelId))
        XCTAssertEqual(
            targetWorkspace.surfaceResumeBinding(panelId: targetPanel.id)?.command,
            "codex resume cross-window-stable-target"
        )

        let getResult = try v2Result(method: "surface.resume.get", params: [
            "surface_id": targetPanel.stableSurfaceId.uuidString,
        ])
        XCTAssertEqual(getResult["surface_id"] as? String, targetPanel.id.uuidString)
        let getBinding = try XCTUnwrap(getResult["resume_binding"] as? [String: Any])
        XCTAssertEqual(getBinding["checkpoint_id"] as? String, "cross-window-stable-target")

        let clearResult = try v2Result(method: "surface.resume.clear", params: [
            "surface_id": targetPanel.stableSurfaceId.uuidString,
            "checkpoint_id": "cross-window-stable-target",
        ])
        XCTAssertEqual(clearResult["surface_id"] as? String, targetPanel.id.uuidString)
        XCTAssertEqual(clearResult["cleared"] as? Bool, true)
        XCTAssertNil(targetWorkspace.surfaceResumeBinding(panelId: targetPanel.id))
    }

    func testSurfaceResumeRejectsAmbiguousStableSurfaceIdAcrossWindows() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let activeWindowId = UUID()
        let otherWindowId = UUID()
        let activeWindow = makeMainWindow(id: activeWindowId)
        let otherWindow = makeMainWindow(id: otherWindowId)
        defer {
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            app.unregisterMainWindowContextForTesting(windowId: activeWindowId)
            app.unregisterMainWindowContextForTesting(windowId: otherWindowId)
            activeWindow.orderOut(nil)
            otherWindow.orderOut(nil)
        }

        let activeManager = TabManager(autoWelcomeIfNeeded: false)
        let otherManager = TabManager(autoWelcomeIfNeeded: false)
        registerMainWindow(app: app, window: activeWindow, windowId: activeWindowId, manager: activeManager)
        registerMainWindow(app: app, window: otherWindow, windowId: otherWindowId, manager: otherManager)
        TerminalController.shared.setActiveTabManager(activeManager)

        let activeWorkspace = try XCTUnwrap(activeManager.selectedWorkspace)
        let activePanel = try XCTUnwrap(activeWorkspace.focusedTerminalPanel)
        let otherWorkspace = try XCTUnwrap(otherManager.selectedWorkspace)
        let otherPanel = try XCTUnwrap(otherWorkspace.focusedTerminalPanel)
        let duplicateStableId = UUID()
        activePanel.adoptStableSurfaceId(duplicateStableId)
        otherPanel.adoptStableSurfaceId(duplicateStableId)

        let (raw, envelope) = try v2Envelope(method: "surface.resume.set", params: [
            "surface_id": duplicateStableId.uuidString,
            "kind": "codex",
            "source": "agent-hook",
            "auto_resume": true,
            "command": "codex resume ambiguous-stable-target",
            "checkpoint_id": "ambiguous-stable-target",
        ])

        XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
        XCTAssertNil(activeWorkspace.surfaceResumeBinding(panelId: activePanel.id))
        XCTAssertNil(otherWorkspace.surfaceResumeBinding(panelId: otherPanel.id))
    }

    func testSurfaceResumeRejectsAnyAmbiguousStableSurfaceIdWithinExplicitWindow() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        registerMainWindow(app: app, window: window, windowId: windowId, manager: manager)
        TerminalController.shared.setActiveTabManager(manager)

        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let firstPanel = try XCTUnwrap(firstWorkspace.focusedTerminalPanel)
        let firstSplit = try XCTUnwrap(firstWorkspace.newTerminalSplit(
            from: firstPanel.id,
            orientation: .horizontal,
            focus: false
        ))
        let secondWorkspace = manager.addWorkspace(select: false)
        let secondPanel = try XCTUnwrap(secondWorkspace.focusedTerminalPanel)
        let duplicateStableId = UUID()
        firstPanel.adoptStableSurfaceId(duplicateStableId)
        firstSplit.adoptStableSurfaceId(duplicateStableId)
        secondPanel.adoptStableSurfaceId(duplicateStableId)

        let (raw, envelope) = try v2Envelope(method: "surface.resume.set", params: [
            "window_id": windowId.uuidString,
            "surface_id": duplicateStableId.uuidString,
            "kind": "codex",
            "source": "agent-hook",
            "auto_resume": true,
            "command": "codex resume ambiguous-window-target",
            "checkpoint_id": "ambiguous-window-target",
        ])

        XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
        XCTAssertNil(firstWorkspace.surfaceResumeBinding(panelId: firstPanel.id))
        XCTAssertNil(firstWorkspace.surfaceResumeBinding(panelId: firstSplit.id))
        XCTAssertNil(secondWorkspace.surfaceResumeBinding(panelId: secondPanel.id))
    }

    func testSurfaceResumeRejectsDuplicateInUnregisteredFallbackManager() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        AppDelegate.shared = app
        let registeredManager = TabManager(autoWelcomeIfNeeded: false)
        let fallbackManager = TabManager(autoWelcomeIfNeeded: false)
        let registeredWindowId = app.registerMainWindowContextForTesting(tabManager: registeredManager)
        defer {
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            app.unregisterMainWindowContextForTesting(windowId: registeredWindowId)
            AppDelegate.shared = previousAppDelegate
        }

        let registeredWorkspace = try XCTUnwrap(registeredManager.selectedWorkspace)
        let registeredPanel = try XCTUnwrap(registeredWorkspace.focusedTerminalPanel)
        let fallbackWorkspace = try XCTUnwrap(fallbackManager.selectedWorkspace)
        let fallbackPanel = try XCTUnwrap(fallbackWorkspace.focusedTerminalPanel)
        let duplicateStableId = UUID()
        registeredPanel.adoptStableSurfaceId(duplicateStableId)
        fallbackPanel.adoptStableSurfaceId(duplicateStableId)
        TerminalController.shared.setActiveTabManager(fallbackManager)

        let (raw, envelope) = try v2Envelope(method: "surface.resume.set", params: [
            "surface_id": duplicateStableId.uuidString,
            "command": "codex resume ambiguous-fallback-target",
        ])

        XCTAssertEqual(envelope["ok"] as? Bool, false, raw)
        XCTAssertNil(registeredWorkspace.surfaceResumeBinding(panelId: registeredPanel.id))
        XCTAssertNil(fallbackWorkspace.surfaceResumeBinding(panelId: fallbackPanel.id))
    }

    func testSystemResolveTerminalRefreshesWhenPrepopulatedManagerRegisters() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        let firstManager = TabManager(autoWelcomeIfNeeded: false)
        let secondManager = TabManager(autoWelcomeIfNeeded: false)
        let firstWorkspace = try XCTUnwrap(firstManager.selectedWorkspace)
        let secondWorkspace = try XCTUnwrap(secondManager.selectedWorkspace)
        let firstSurface = try XCTUnwrap(firstWorkspace.focusedPanelId)
        let secondSurface = try XCTUnwrap(secondWorkspace.focusedPanelId)
        let ttyName = "cmux-cache-refresh-\(UUID().uuidString)"
        firstWorkspace.surfaceTTYNames[firstSurface] = ttyName
        secondWorkspace.surfaceTTYNames[secondSurface] = ttyName
        let firstWindowId = app.registerMainWindowContextForTesting(tabManager: firstManager)
        var secondWindowId: UUID?
        defer {
            app.unregisterMainWindowContextForTesting(windowId: firstWindowId)
            if let secondWindowId { app.unregisterMainWindowContextForTesting(windowId: secondWindowId) }
            TerminalController.invalidateTerminalResolverBindingCaches()
            AppDelegate.shared = previousAppDelegate
        }

        let firstPayload = try terminalResolverPayload(["tty_name": ttyName])
        XCTAssertEqual((firstPayload["tty_bindings"] as? [[String: Any]])?.count, 1)

        secondWindowId = app.registerMainWindowContextForTesting(tabManager: secondManager)
        let refreshedPayload = try terminalResolverPayload(["tty_name": ttyName])
        XCTAssertEqual((refreshedPayload["tty_bindings"] as? [[String: Any]])?.count, 2)
    }

    func testSystemResolveTerminalRejectsInheritedScopeWithoutUniqueLiveTTY() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let manager = TabManager()
        AppDelegate.shared = appDelegate

        let workspace = manager.addWorkspace(select: true)
        let surfaceID = try XCTUnwrap(workspace.focusedPanelId)
        workspace.surfaceTTYNames[surfaceID] = "cmux-missing-tty-\(UUID().uuidString)"
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        TerminalController.invalidateTerminalResolverBindingCaches()
        defer {
            TerminalController.invalidateTerminalResolverBindingCaches()
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            AppDelegate.shared = previousAppDelegate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_WORKSPACE_ID"] = workspace.id.uuidString
        environment["CMUX_SURFACE_ID"] = surfaceID.uuidString
        process.environment = environment
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let processContext = try XCTUnwrap(
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(
                for: Int(process.processIdentifier)
            )
        )
        XCTAssertEqual(processContext.environment["CMUX_WORKSPACE_ID"], workspace.id.uuidString)
        XCTAssertEqual(processContext.environment["CMUX_SURFACE_ID"], surfaceID.uuidString)

        let response = TerminalController.shared.v2SystemResolveTerminal(params: [
            "pid": Int(process.processIdentifier),
        ])
        guard case .ok(let rawPayload) = response else {
            XCTFail("Expected terminal resolver success")
            return
        }
        let payload = try XCTUnwrap(rawPayload as? [String: Any])

        XCTAssertTrue(
            payload["pid_binding"] is NSNull,
            "Inherited CMUX scope must not become an authoritative PID binding: \(payload)"
        )
    }

    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    private func registerMainWindow(
        app: AppDelegate,
        window: NSWindow,
        windowId: UUID,
        manager: TabManager
    ) {
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
    }

    private func terminalResolverPayload(_ params: [String: Any]) throws -> [String: Any] {
        guard case .ok(let rawPayload) = TerminalController.shared.v2SystemResolveTerminal(params: params) else {
            XCTFail("Expected terminal resolver success")
            return [:]
        }
        return try XCTUnwrap(rawPayload as? [String: Any])
    }

    private func v2Result(method: String, params: [String: Any]) throws -> [String: Any] {
        let (raw, envelope) = try v2Envelope(method: method, params: params)
        XCTAssertEqual(envelope["ok"] as? Bool, true, raw)
        return try XCTUnwrap(envelope["result"] as? [String: Any], raw)
    }

    private func v2Envelope(method: String, params: [String: Any]) throws -> (raw: String, envelope: [String: Any]) {
        let request = ["id": method, "method": method, "params": params] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try XCTUnwrap(String(data: data, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try XCTUnwrap(raw.data(using: .utf8))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        return (raw, envelope)
    }
}
