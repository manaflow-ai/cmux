import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CommandPaletteControlRegistrationTests {
    @Test func registrationDoesNotPublishSocketControlBeforeItsHandlerExists() {
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
        }

        let didPublishControl = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        #expect(!didPublishControl)
        #expect(appDelegate.mainWindowContext(for: tabManager)?.commandPaletteControlHandler == nil)
    }

    @Test func registeredWindowPublishesItsHandlerWithItsRoutingContext() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let item = CommandPaletteControlRequestItem(
            id: "palette.fixture",
            title: "Fixture",
            subtitle: "Tests",
            shortcutHint: nil,
            keywords: ["fixture"],
            dismissOnRun: true,
            arguments: []
        )
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                request.complete(.listed([item]))
            }
        )
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let resolution = TerminalController.shared.controlCommandPaletteList(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: windowID,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            )
        )

        #expect(resolution == .listed(
            windowID: windowID,
            commands: [
                ControlCommandPaletteItem(
                    id: "palette.fixture",
                    title: "Fixture",
                    subtitle: "Tests",
                    shortcutHint: nil,
                    keywords: ["fixture"],
                    dismissOnRun: true
                ),
            ]
        ))
    }

    @Test func staleSelectorsDoNotFallBackToTheCallerWindow() {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        var handlerCalls = 0
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                handlerCalls += 1
                request.complete(.listed([]))
            }
        )
        AppDelegate.shared = appDelegate
        TerminalController.shared.setActiveTabManager(tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let staleSelectors = [
            routing(groupID: UUID()),
            routing(workspaceID: UUID()),
            routing(surfaceID: UUID()),
            routing(paneID: UUID()),
        ]
        for selector in staleSelectors {
            let resolution = TerminalController.shared.controlCommandPaletteList(routing: selector)
            #expect(resolution == .windowNotFound)
            let inlineResolution = TerminalController.shared.controlInlineVSCodeOpen(
                routing: selector,
                directoryPath: FileManager.default.temporaryDirectory.path
            )
            #expect(inlineResolution == .workspaceNotFound)
        }

        let unresolvedSelectors = [
            routing(hasGroupIDParam: true),
            routing(hasWorkspaceIDParam: true),
            routing(hasSurfaceIDParam: true),
            routing(hasPaneIDParam: true),
        ]
        for selector in unresolvedSelectors {
            let resolution = TerminalController.shared.controlCommandPaletteList(routing: selector)
            #expect(resolution == .windowNotFound)
            let inlineResolution = TerminalController.shared.controlInlineVSCodeOpen(
                routing: selector,
                directoryPath: FileManager.default.temporaryDirectory.path
            )
            #expect(inlineResolution == .workspaceNotFound)
        }
        #expect(handlerCalls == 0)
    }

    @Test func crossWindowSelectorsDoNotRouteThroughAnExplicitWindow() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let managerA = TabManager(autoWelcomeIfNeeded: false)
        let managerB = TabManager(autoWelcomeIfNeeded: false)
        let workspaceB = try #require(managerB.tabs.first)
        let groupB = try #require(managerB.createWorkspaceGroup(
            name: "Group B",
            childWorkspaceIds: [workspaceB.id]
        ))
        let surfaceB = try #require(workspaceB.panels.keys.first)
        let paneB = try #require(workspaceB.bonsplitController.allPaneIds.first).id
        var handlerCallsA = 0
        var handlerCallsB = 0
        let windowA = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerA,
            commandPaletteControlHandler: { request in
                handlerCallsA += 1
                request.complete(.listed([]))
            }
        )
        let windowB = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerB,
            commandPaletteControlHandler: { request in
                handlerCallsB += 1
                request.complete(.listed([]))
            }
        )
        AppDelegate.shared = appDelegate
        TerminalController.shared.setActiveTabManager(managerA)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowA)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowB)
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let crossWindowSelectors = [
            routing(windowID: windowA, groupID: groupB),
            routing(windowID: windowA, workspaceID: workspaceB.id),
            routing(windowID: windowA, surfaceID: surfaceB),
            routing(windowID: windowA, paneID: paneB),
        ]
        for selector in crossWindowSelectors {
            let resolution = TerminalController.shared.controlCommandPaletteList(routing: selector)
            #expect(resolution == .windowNotFound)
            let inlineResolution = TerminalController.shared.controlInlineVSCodeOpen(
                routing: selector,
                directoryPath: FileManager.default.temporaryDirectory.path
            )
            #expect(inlineResolution == .workspaceNotFound)
        }
        #expect(handlerCallsA == 0)
        #expect(handlerCallsB == 0)
    }

    @Test func validSelectorsAndNoSelectorRetainTheirWindowRouting() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let managerA = TabManager(autoWelcomeIfNeeded: false)
        let managerB = TabManager(autoWelcomeIfNeeded: false)
        let workspaceB = try #require(managerB.tabs.first)
        let groupB = try #require(managerB.createWorkspaceGroup(
            name: "Group B",
            childWorkspaceIds: [workspaceB.id]
        ))
        let surfaceB = try #require(workspaceB.panels.keys.first)
        let paneB = try #require(workspaceB.bonsplitController.allPaneIds.first).id
        let windowA = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerA,
            commandPaletteControlHandler: { $0.complete(.listed([])) }
        )
        let windowB = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerB,
            commandPaletteControlHandler: { $0.complete(.listed([])) }
        )
        AppDelegate.shared = appDelegate
        TerminalController.shared.setActiveTabManager(managerA)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowA)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowB)
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let validSelectors = [
            routing(groupID: groupB),
            routing(workspaceID: workspaceB.id),
            routing(surfaceID: surfaceB),
            routing(paneID: paneB),
        ]
        for selector in validSelectors {
            let resolution = TerminalController.shared.controlCommandPaletteList(routing: selector)
            guard case .listed(let routedWindowID, _) = resolution else {
                Issue.record("Expected valid selector to route to its owning window")
                continue
            }
            #expect(routedWindowID == windowB)
        }

        let fallback = TerminalController.shared.controlCommandPaletteList(routing: routing())
        guard case .listed(let fallbackWindowID, _) = fallback else {
            Issue.record("Expected an omitted selector to route to the caller window")
            return
        }
        #expect(fallbackWindowID == windowA)
    }

    private func routing(
        windowID: UUID? = nil,
        groupID: UUID? = nil,
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil,
        paneID: UUID? = nil,
        hasGroupIDParam: Bool? = nil,
        hasWorkspaceIDParam: Bool? = nil,
        hasSurfaceIDParam: Bool? = nil,
        hasPaneIDParam: Bool? = nil
    ) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: windowID != nil,
            windowID: windowID,
            groupID: groupID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            paneID: paneID,
            hasGroupIDParam: hasGroupIDParam,
            hasWorkspaceIDParam: hasWorkspaceIDParam,
            hasSurfaceIDParam: hasSurfaceIDParam,
            hasPaneIDParam: hasPaneIDParam
        )
    }
}
