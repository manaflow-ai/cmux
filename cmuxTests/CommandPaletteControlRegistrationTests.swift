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
    @Test func bootstrapDefersSocketListenerUntilTheInitialWindowRegistersItsHandler() {
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var activations: [(TabManager, String)] = []
        appDelegate.debugSocketListenerActivationOverrideForTesting = { manager, source in
            activations.append((manager, source))
        }
        defer {
            appDelegate.debugSocketListenerActivationOverrideForTesting = nil
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            MobileHostService.shared.stop()
            TerminalController.shared.stop()
            window.close()
        }

        let didPublishBeforeHandler = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        #expect(!didPublishBeforeHandler)

        let bootstrappedWindowID = appDelegate.bootstrapInitialMainWindowIfNeeded(
            debugSource: "commandPaletteRegistrationTest",
            shouldActivate: false,
            suppressWelcome: true
        )

        #expect(bootstrappedWindowID == windowID)
        #expect(activations.isEmpty)

        let didPublishAfterHandler = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            commandPaletteControlHandler: { $0.complete(.listed([])) }
        )

        #expect(didPublishAfterHandler)
        #expect(activations.count == 1)
        #expect(activations.first?.0 === tabManager)
        #expect(activations.first?.1 == "mainWindow.register")
    }

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

    @Test func workspaceSelectorReachesTheHandlerWithoutChangingSelection() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let targetWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        var receivedTarget: CommandPaletteActionTarget?
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                receivedTarget = request.target
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

        let resolution = TerminalController.shared.controlCommandPaletteList(
            routing: routing(workspaceID: targetWorkspace.id)
        )

        #expect(resolution == .listed(windowID: windowID, commands: []))
        #expect(receivedTarget == CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: targetWorkspace.id,
            panelID: targetWorkspace.focusedPanelId
        ))
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
    }

    @Test func groupSelectorTargetsItsAnchorInsteadOfTheVisibleWorkspace() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let groupedWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let groupID = try #require(tabManager.createWorkspaceGroup(
            name: "Palette Group",
            childWorkspaceIds: [groupedWorkspace.id],
            selectAnchor: false,
            collapseSidebarSelection: false
        ))
        let group = try #require(tabManager.workspaceGroups.first(where: { $0.id == groupID }))
        let anchorWorkspace = try #require(
            tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })
        )

        let resolvedWorkspace = TerminalController.shared.controlInlineVSCodeWorkspace(
            routing: routing(groupID: groupID),
            tabManager: tabManager
        )

        #expect(resolvedWorkspace?.id == anchorWorkspace.id)
        #expect(resolvedWorkspace?.groupId == group.id)
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
    }

    @Test func surfaceAndPaneSelectorsReachTheHandlerAsOneExactTarget() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let targetWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let targetPanelID = try #require(targetWorkspace.panels.keys.first)
        let targetPaneID = try #require(targetWorkspace.paneId(forPanelId: targetPanelID)?.id)
        var receivedTargets: [CommandPaletteActionTarget] = []
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                receivedTargets.append(request.target)
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

        _ = TerminalController.shared.controlCommandPaletteList(
            routing: routing(surfaceID: targetPanelID)
        )
        _ = TerminalController.shared.controlCommandPaletteList(
            routing: routing(paneID: targetPaneID)
        )

        let expectedTarget = CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: targetWorkspace.id,
            panelID: targetPanelID
        )
        #expect(receivedTargets == [expectedTarget, expectedTarget])
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(
            TerminalController.shared.controlCommandPaletteList(
                routing: routing(workspaceID: selectedWorkspace.id, surfaceID: targetPanelID)
            ) == .windowNotFound
        )
    }

    @Test func actionTargetScopeOverridesAccessorsWithoutMutatingSelection() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let targetWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let targetPanelID = try #require(targetWorkspace.panels.keys.first)
        let selectedPanelID = selectedWorkspace.focusedPanelId
        let target = CommandPaletteActionTarget(
            windowID: UUID(),
            workspaceID: targetWorkspace.id,
            panelID: targetPanelID
        )

        CommandPaletteActionTargetScope.$current.withValue(target) {
            #expect(tabManager.selectedWorkspace?.id == targetWorkspace.id)
            #expect(targetWorkspace.focusedPanelId == targetPanelID)
        }

        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)
    }

    @Test func windowDockWorkspaceRoutingUsesTheOwningWindowSelection() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let callerManager = TabManager(autoWelcomeIfNeeded: false)
        let targetManager = TabManager(autoWelcomeIfNeeded: false)
        let firstTargetWorkspace = try #require(targetManager.tabs.first)
        let selectedTargetWorkspace = targetManager.addWorkspace(
            select: true,
            autoWelcomeIfNeeded: false
        )
        let item = CommandPaletteControlRequestItem(
            id: "palette.fixture",
            title: "Fixture",
            subtitle: "Tests",
            shortcutHint: nil,
            keywords: ["fixture"],
            dismissOnRun: true,
            arguments: []
        )
        var callerHandlerCalls = 0
        var handledWorkspaceIDs: [UUID?] = []
        let callerWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: callerManager,
            commandPaletteControlHandler: { request in
                callerHandlerCalls += 1
                request.complete(.ran(item, result: .completed))
            }
        )
        let targetWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: targetManager,
            commandPaletteControlHandler: { request in
                handledWorkspaceIDs.append(
                    targetManager.selectedWorkspace?.id ?? targetManager.tabs.first?.id
                )
                request.complete(.ran(item, result: .completed))
            }
        )
        AppDelegate.shared = appDelegate
        TerminalController.shared.setActiveTabManager(callerManager)
        let targetDock = appDelegate.windowDock(forWindowId: targetWindowID)
        let targetDockPane = try #require(targetDock.bonsplitController.allPaneIds.first)
        let targetDockSurfaceID = try #require(
            targetDock.newSurface(kind: .terminal, inPane: targetDockPane, focus: true)
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: callerWindowID)
            appDelegate.unregisterMainWindowContextForTesting(windowId: targetWindowID)
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let ownerRouting = routing(workspaceID: targetWindowID)
        #expect(
            TerminalController.shared.controlInlineVSCodeWorkspace(
                routing: ownerRouting,
                tabManager: targetManager
            )?.id == selectedTargetWorkspace.id
        )
        let ownerRun = TerminalController.shared.controlCommandPaletteRun(
            routing: ownerRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil
        )
        guard case .completed(let ownerWindowID, _) = ownerRun else {
            Issue.record("Expected Dock owner routing to run in its owning window")
            return
        }
        #expect(ownerWindowID == targetWindowID)
        #expect(handledWorkspaceIDs == [selectedTargetWorkspace.id])

        let surfaceRouting = routing(surfaceID: targetDockSurfaceID)
        #expect(
            TerminalController.shared.controlInlineVSCodeWorkspace(
                routing: surfaceRouting,
                tabManager: targetManager
            )?.id == selectedTargetWorkspace.id
        )
        #expect(
            TerminalController.shared.controlInlineVSCodeWorkspace(
                routing: surfaceRouting,
                tabManager: callerManager
            ) == nil
        )
        let surfaceRun = TerminalController.shared.controlCommandPaletteRun(
            routing: surfaceRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil
        )
        guard case .completed(let surfaceWindowID, _) = surfaceRun else {
            Issue.record("Expected Dock surface routing to run in its owning window")
            return
        }
        #expect(surfaceWindowID == targetWindowID)
        #expect(handledWorkspaceIDs == [selectedTargetWorkspace.id, selectedTargetWorkspace.id])
        #expect(
            TerminalController.shared.controlCommandPaletteRun(
                routing: routing(windowID: callerWindowID, surfaceID: targetDockSurfaceID),
                commandID: item.id,
                arguments: [:],
                workingDirectory: nil
            ) == .windowNotFound
        )

        targetManager.selectedTabId = nil
        let aliasRouting = routing(
            windowID: targetWindowID,
            workspaceID: AppDelegate.windowDockAliasWorkspaceId
        )
        #expect(
            TerminalController.shared.controlInlineVSCodeWorkspace(
                routing: aliasRouting,
                tabManager: targetManager
            )?.id == firstTargetWorkspace.id
        )
        let aliasRun = TerminalController.shared.controlCommandPaletteRun(
            routing: aliasRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil
        )
        guard case .completed(let aliasWindowID, _) = aliasRun else {
            Issue.record("Expected Dock alias routing to run in its owning window")
            return
        }
        #expect(aliasWindowID == targetWindowID)
        #expect(handledWorkspaceIDs == [
            selectedTargetWorkspace.id,
            selectedTargetWorkspace.id,
            firstTargetWorkspace.id,
        ])

        let paneRouting = routing(paneID: targetDockPane.id)
        #expect(
            TerminalController.shared.controlInlineVSCodeWorkspace(
                routing: paneRouting,
                tabManager: targetManager
            )?.id == firstTargetWorkspace.id
        )
        #expect(
            TerminalController.shared.controlInlineVSCodeWorkspace(
                routing: paneRouting,
                tabManager: callerManager
            ) == nil
        )
        let paneRun = TerminalController.shared.controlCommandPaletteRun(
            routing: paneRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil
        )
        guard case .completed(let paneWindowID, _) = paneRun else {
            Issue.record("Expected Dock pane routing to run in its owning window")
            return
        }
        #expect(paneWindowID == targetWindowID)
        #expect(handledWorkspaceIDs == [
            selectedTargetWorkspace.id,
            selectedTargetWorkspace.id,
            firstTargetWorkspace.id,
            firstTargetWorkspace.id,
        ])
        #expect(
            TerminalController.shared.controlCommandPaletteRun(
                routing: routing(windowID: callerWindowID, paneID: targetDockPane.id),
                commandID: item.id,
                arguments: [:],
                workingDirectory: nil
            ) == .windowNotFound
        )

        let unrelatedRouting = routing(workspaceID: UUID())
        #expect(
            TerminalController.shared.controlInlineVSCodeWorkspace(
                routing: unrelatedRouting,
                tabManager: targetManager
            ) == nil
        )
        #expect(
            TerminalController.shared.controlCommandPaletteRun(
                routing: unrelatedRouting,
                commandID: item.id,
                arguments: [:],
                workingDirectory: nil
            ) == .windowNotFound
        )
        #expect(callerHandlerCalls == 0)
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
