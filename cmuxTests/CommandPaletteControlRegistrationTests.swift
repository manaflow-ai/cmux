import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
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
            target: ControlCommandPaletteTarget(
                windowID: windowID,
                workspaceID: tabManager.selectedWorkspace?.id,
                panelID: tabManager.selectedWorkspace?.focusedPanelId
            ),
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
            routing(windowID: UUID()),
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
            guard case .listed(let target, _) = resolution else {
                Issue.record("Expected valid selector to route to its owning window")
                continue
            }
            #expect(target.windowID == windowB)
        }

        let fallback = TerminalController.shared.controlCommandPaletteList(routing: routing())
        guard case .listed(let fallbackTarget, _) = fallback else {
            Issue.record("Expected an omitted selector to route to the caller window")
            return
        }
        #expect(fallbackTarget.windowID == windowA)
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

        #expect(resolution == .listed(
            target: ControlCommandPaletteTarget(
                windowID: windowID,
                workspaceID: targetWorkspace.id,
                panelID: targetWorkspace.focusedPanelId
            ),
            commands: []
        ))
        #expect(receivedTarget == CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: targetWorkspace.id,
            panelID: targetWorkspace.focusedPanelId
        ))
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
    }

    @Test func listedIdentityCanBeEchoedAfterFocusChangesWithoutRetargetingRun() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let listedWorkspace = try #require(tabManager.tabs.first)
        let listedPanelID = try #require(listedWorkspace.panels.keys.first)
        let laterWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let item = CommandPaletteControlRequestItem(
            id: "palette.fixture",
            title: "Fixture",
            subtitle: "Tests",
            shortcutHint: nil,
            keywords: ["fixture"],
            dismissOnRun: true,
            arguments: []
        )
        var receivedTargets: [CommandPaletteActionTarget] = []
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                receivedTargets.append(request.target)
                if receivedTargets.count == 1 {
                    request.complete(.listed([item]))
                } else {
                    request.complete(.ran(item, result: .completed))
                }
            }
        )
        AppDelegate.shared = appDelegate
        TerminalController.shared.setActiveTabManager(tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let list = TerminalController.shared.controlCommandPaletteList(
            routing: routing(windowID: windowID)
        )
        guard case .listed(let listedTarget, _) = list else {
            Issue.record("Expected palette target identity")
            return
        }
        #expect(listedTarget == ControlCommandPaletteTarget(
            windowID: windowID,
            workspaceID: listedWorkspace.id,
            panelID: listedPanelID
        ))

        tabManager.selectedTabId = laterWorkspace.id
        let run = TerminalController.shared.controlCommandPaletteRun(
            target: listedTarget,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil
        )

        guard case .completed(let runWindowID, _) = run else {
            Issue.record("Expected echoed palette target to run")
            return
        }
        #expect(runWindowID == windowID)
        let expectedTarget = CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: listedWorkspace.id,
            panelID: listedPanelID
        )
        #expect(receivedTargets == [expectedTarget, expectedTarget])
        #expect(tabManager.selectedWorkspace?.id == laterWorkspace.id)
    }

    @Test func echoedIdentityDistinguishesADeletedPanelFromADeletedWindow() throws {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(tabManager.tabs.first)
        let originalPanelID = try #require(workspace.panels.keys.first)
        _ = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false, initialInput: nil))
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
        let target = ControlCommandPaletteTarget(
            windowID: windowID,
            workspaceID: workspace.id,
            panelID: originalPanelID
        )

        #expect(workspace.closePanel(originalPanelID, force: true))
        #expect(TerminalController.shared.controlCommandPaletteRun(
            target: target,
            commandID: "palette.fixture",
            arguments: [:],
            workingDirectory: nil
        ) == .targetUnavailable)
        #expect(handlerCalls == 0)

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        #expect(TerminalController.shared.controlCommandPaletteRun(
            target: target,
            commandID: "palette.fixture",
            arguments: [:],
            workingDirectory: nil
        ) == .windowNotFound)
        #expect(handlerCalls == 0)
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

    @Test func actionContextResolvesAndRevalidatesWithoutMutatingSelection() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let targetWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let targetPanelID = try #require(targetWorkspace.panels.keys.first)
        let selectedPanelID = selectedWorkspace.focusedPanelId
        let nonTargetPanel = try #require(
            targetWorkspace.newTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
        )
        #expect(targetWorkspace.focusedPanelId == nonTargetPanel.id)

        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }
        let target = CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: targetWorkspace.id,
            panelID: targetPanelID
        )
        let context = CommandPaletteActionContext(
            target: target,
            tabManager: tabManager,
            owningWindowID: windowID
        )

        #expect(context.workspace()?.id == targetWorkspace.id)
        #expect(context.panel()?.panelId == targetPanelID)
        #expect(context.terminalPanel?.id == targetPanelID)
        #expect(context.browserPanel == nil)
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)
        #expect(targetWorkspace.focusedPanelId == nonTargetPanel.id)

        let wrongWindowContext = CommandPaletteActionContext(
            target: target,
            tabManager: tabManager,
            owningWindowID: UUID()
        )
        #expect(wrongWindowContext.workspace() == nil)
        #expect(wrongWindowContext.panel() == nil)

        let mismatchedLiveWindowID = UUID()
        let mismatchedLiveWindowContext = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: mismatchedLiveWindowID,
                workspaceID: targetWorkspace.id,
                panelID: targetPanelID
            ),
            tabManager: tabManager,
            owningWindowID: mismatchedLiveWindowID
        )
        #expect(mismatchedLiveWindowContext.workspace() == nil)
        #expect(mismatchedLiveWindowContext.panel() == nil)

        #expect(targetWorkspace.closePanel(targetPanelID, force: true))
        #expect(context.workspace()?.id == targetWorkspace.id)
        #expect(context.panel() == nil)
        #expect(context.terminalPanel == nil)
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)
        #expect(targetWorkspace.focusedPanelId == nonTargetPanel.id)

        tabManager.closeWorkspace(targetWorkspace, recordHistory: false)
        #expect(context.workspace() == nil)
        #expect(context.panel() == nil)
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)

        let staleWindowContext = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: selectedWorkspace.id,
                panelID: selectedPanelID
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        #expect(staleWindowContext.workspace()?.id == selectedWorkspace.id)
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        #expect(staleWindowContext.workspace() == nil)
        #expect(staleWindowContext.panel() == nil)
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

@MainActor
@Suite(.serialized)
struct CommandPaletteCLIPathActionTests {
    @Test func automationInstallReturnsCompletedAndCreatesTheSymlink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let result = AppDelegate().installCmuxCLIInPath(
            resultPresentation: .silent,
            installer: fixture.installer
        )

        #expect(result == .completed)
        #expect(
            try fixture.fileManager.destinationOfSymbolicLink(atPath: fixture.destinationURL.path)
                == fixture.sourceURL.path
        )
    }

    @Test func automationUninstallReturnsCompletedAndRemovesTheSymlink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.fileManager.createDirectory(
            at: fixture.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixture.fileManager.createSymbolicLink(
            at: fixture.destinationURL,
            withDestinationURL: fixture.sourceURL
        )

        let result = AppDelegate().uninstallCmuxCLIInPath(
            resultPresentation: .silent,
            installer: fixture.installer
        )

        #expect(result == .completed)
        #expect(
            (try? fixture.fileManager.attributesOfItem(atPath: fixture.destinationURL.path)) == nil
        )
    }

    @Test func automationInstallFailureReturnsTypedFailureWithoutPresentingAResultAlert() {
        let installer = CmuxCLIPathInstaller(
            bundledCLIURLProvider: { nil },
            expectedBundledCLIPath: "/missing/cmux"
        )

        let result = AppDelegate().installCmuxCLIInPath(
            resultPresentation: .silent,
            installer: installer
        )

        guard case .failed(let code, let message) = result else {
            Issue.record("Expected a typed install failure")
            return
        }
        #expect(code == "cli_install_failed")
        #expect(message == String(localized: "cli.installFailed", defaultValue: "Couldn't Install cmux CLI"))
    }

    @Test func automationUninstallFailureReturnsTypedFailureWithoutPresentingAResultAlert() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-palette-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let destinationURL = rootURL.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        let installer = CmuxCLIPathInstaller(destinationURL: destinationURL)

        let result = AppDelegate().uninstallCmuxCLIInPath(
            resultPresentation: .silent,
            installer: installer
        )

        guard case .failed(let code, let message) = result else {
            Issue.record("Expected a typed uninstall failure")
            return
        }
        #expect(code == "cli_uninstall_failed")
        #expect(message == String(localized: "cli.uninstallFailed", defaultValue: "Couldn't Uninstall cmux CLI"))
    }

    private func makeFixture() throws -> CLIPathFixture {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-palette-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let sourceURL = rootURL.appendingPathComponent("bundled-cmux")
        try Data("#!/bin/sh\n".utf8).write(to: sourceURL)
        let destinationURL = rootURL.appendingPathComponent("bin/cmux")
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { sourceURL },
            expectedBundledCLIPath: sourceURL.path
        )
        return CLIPathFixture(
            fileManager: fileManager,
            rootURL: rootURL,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            installer: installer
        )
    }
}

@MainActor
struct CommandPaletteBrowserHistoryActionTests {
    @Test func destructiveHistoryActionDeclaresRequiredBooleanForce() throws {
        #expect(ContentView.commandPaletteBrowserHistoryClearArguments.count == 1)
        let argument = try #require(ContentView.commandPaletteBrowserHistoryClearArguments.first)

        #expect(argument.name == "force")
        #expect(argument.valueType == .boolean)
        #expect(argument.required)
    }

    @Test func browserHistoryAutomationRequiresExplicitTrue() {
        #expect(!ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .automation)
        ))
        #expect(!ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .automation, arguments: ["force": "false"])
        ))
        #expect(ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .automation, arguments: ["force": "true"])
        ))
        #expect(ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .commandPalette)
        ))
    }
}

@MainActor
@Suite("State mutation command palette action contracts")
struct CommandPaletteStateMutationActionContractTests {
    @Test("Toggle actions declare optional Boolean setters")
    func toggleActionsDeclareOptionalBooleanSetters() throws {
        let contracts: [([CmuxActionArgumentDefinition], String)] = [
            (ContentView.commandPaletteSidebarVisibilityArguments, "visible"),
            (ContentView.commandPaletteEnabledToggleArguments, "enabled"),
            (ContentView.commandPalettePinnedToggleArguments, "pinned"),
            (ContentView.commandPaletteUnreadToggleArguments, "unread"),
        ]

        for (arguments, expectedName) in contracts {
            let argument = try #require(arguments.first)
            #expect(arguments.count == 1)
            #expect(argument.name == expectedName)
            #expect(argument.valueType == .boolean)
            #expect(!argument.required)
        }
    }

    @Test("Omitted values toggle while explicit values are idempotent")
    func toggleValueResolutionPreservesInteractiveBehavior() {
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .commandPalette),
            argumentName: "enabled",
            currentValue: false
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .automation),
            argumentName: "enabled",
            currentValue: true
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            ),
            argumentName: "enabled",
            currentValue: true
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "false"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "maybe"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == nil)
    }
}

@MainActor
@Suite("Notification command palette action contracts")
struct CommandPaletteNotificationActionContractTests {
    @Test("Notification commands expose only the deterministic unread setter argument")
    func notificationCommandSchemas() throws {
        let contributions = ContentView.commandPaletteNotificationCommandContributions()
        #expect(Set(contributions.map(\.commandId)) == Set([
            "palette.showNotifications",
            "palette.jumpUnread",
            "palette.toggleUnread",
            "palette.markOldestUnreadAndJumpNext",
        ]))

        let toggle = try #require(contributions.first { $0.commandId == "palette.toggleUnread" })
        #expect(toggle.arguments == [
            CmuxActionArgumentDefinition(
                name: "unread",
                valueType: .boolean,
                required: false
            ),
        ])

        let jump = try #require(contributions.first { $0.commandId == "palette.jumpUnread" })
        var context = CommandPaletteContextSnapshot()
        #expect(!jump.enablement(context))
        context.setBool(CommandPaletteContextKeys.notificationsCanJumpUnread, true)
        #expect(jump.enablement(context))

        for contribution in contributions where contribution.commandId != "palette.toggleUnread" {
            #expect(contribution.arguments.isEmpty)
        }
    }
}

@MainActor
@Suite("Browser command palette action contracts")
struct CommandPaletteBrowserActionContractTests {
    @Test("Browser state actions declare optional Boolean enabled")
    func stateActionsDeclareOptionalEnabled() throws {
        let argument = try #require(ContentView.commandPaletteOptionalEnabledArguments.first)

        #expect(ContentView.commandPaletteOptionalEnabledArguments.count == 1)
        #expect(argument.name == "enabled")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test("Explicit browser state is idempotent and omission remains a toggle")
    func enabledPolicySupportsStateAndLegacyToggle() {
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            ),
            argumentName: "enabled",
            currentValue: true
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["enabled": "false"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .automation),
            argumentName: "enabled",
            currentValue: true
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .commandPalette),
            argumentName: "enabled",
            currentValue: false
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "maybe"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == nil)
    }

    @Test("Browser split actions declare optional Boolean focus")
    func splitActionsDeclareOptionalFocus() throws {
        let argument = try #require(ContentView.commandPaletteBrowserSplitArguments.first)

        #expect(ContentView.commandPaletteBrowserSplitArguments.count == 1)
        #expect(argument.name == "focus")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test("Browser split focus has deterministic adapter defaults")
    func splitFocusPolicyIsDeterministic() {
        #expect(!ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["focus": "false"]
            ),
            targetIsSelected: true
        ))
        #expect(ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["focus": "true"]
            ),
            targetIsSelected: false
        ))
        #expect(ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(source: .automation),
            targetIsSelected: false
        ))
        #expect(!ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetIsSelected: false
        ))
        #expect(ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetIsSelected: true
        ))
    }

    @Test("Rejected and no-op browser actions return typed failure")
    func actionResultReflectsWhetherWorkStarted() {
        #expect(ContentView.commandPaletteBrowserActionResult(
            didStart: true,
            acceptedResult: .completed
        ) == .completed)
        #expect(ContentView.commandPaletteBrowserActionResult(
            didStart: true,
            acceptedResult: .queued
        ) == .queued)

        guard case .failed(let code, let message) = ContentView.commandPaletteBrowserActionResult(
            didStart: false,
            acceptedResult: .completed
        ) else {
            Issue.record("Expected a typed browser action failure")
            return
        }
        #expect(code == "panel_action_failed")
        #expect(message == String(
            localized: "action.error.panelActionFailed",
            defaultValue: "The panel action could not be completed."
        ))
    }

    @Test("Browser state outcomes preserve completion and queue semantics")
    func stateActionResultReflectsMutationOutcome() {
        #expect(ContentView.commandPaletteBrowserStateActionResult(
            .alreadySatisfied
        ) == .completed)
        #expect(ContentView.commandPaletteBrowserStateActionResult(
            .completed
        ) == .completed)
        #expect(ContentView.commandPaletteBrowserStateActionResult(
            .queued
        ) == .queued)

        guard case .failed(let code, _) = ContentView.commandPaletteBrowserStateActionResult(
            .failed
        ) else {
            Issue.record("Expected a typed browser state failure")
            return
        }
        #expect(code == "panel_action_failed")
    }

    @Test("Browser state setters use exact identities and report idempotence")
    func stateSettersUseExactTarget() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let ambientWorkspaceID = try #require(manager.selectedWorkspace?.id)
        let targetWorkspace = manager.addWorkspace(
            initialSurface: .browser,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let peerWorkspace = manager.addWorkspace(
            initialSurface: .browser,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let targetPanel = try #require(targetWorkspace.panels.values.first as? BrowserPanel)
        let peerPanel = try #require(peerWorkspace.panels.values.first as? BrowserPanel)
        defer {
            targetPanel.close()
            peerPanel.close()
        }

        let targetInitialOmnibar = targetPanel.isOmnibarVisible
        let peerInitialOmnibar = peerPanel.isOmnibarVisible
        #expect(manager.setBrowserOmnibar(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: !targetInitialOmnibar
        ) == .completed)
        #expect(targetPanel.isOmnibarVisible == !targetInitialOmnibar)
        #expect(peerPanel.isOmnibarVisible == peerInitialOmnibar)
        #expect(manager.selectedTabId == ambientWorkspaceID)
        #expect(manager.setBrowserOmnibar(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: !targetInitialOmnibar
        ) == .alreadySatisfied)

        #expect(manager.setBrowserFocusMode(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: false,
            reason: "test"
        ) == .alreadySatisfied)
        #expect(manager.setBrowserDeveloperTools(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: false
        ) == .alreadySatisfied)
        #expect(manager.setBrowserReactGrab(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: false,
            focusWebView: false
        ) == .alreadySatisfied)
        #expect(manager.setBrowserOmnibar(
            workspaceID: targetWorkspace.id,
            panelID: UUID(),
            enabled: targetInitialOmnibar
        ) == .failed)
    }

    @Test("Back and forward model entrypoints reject unavailable traversal")
    func navigationModelRejectsNoOpTraversal() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        #expect(!panel.goBackIfPossible())
        #expect(!panel.goForwardIfPossible())

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.com/back"],
            forwardHistoryURLStrings: ["https://example.com/forward"],
            currentURLString: "https://example.com/current"
        )

        #expect(panel.goBackIfPossible())
        #expect(panel.goForwardIfPossible())
    }

    @Test("Back and forward enablement follows the captured browser state")
    func navigationEnablementUsesCapturedState() {
        var context = CommandPaletteContextSnapshot()

        #expect(!ContentView.commandPaletteBrowserBackEnabled(context))
        #expect(!ContentView.commandPaletteBrowserForwardEnabled(context))

        context.setBool(CommandPaletteContextKeys.panelBrowserCanGoBack, true)
        #expect(ContentView.commandPaletteBrowserBackEnabled(context))
        #expect(!ContentView.commandPaletteBrowserForwardEnabled(context))

        context.setBool(CommandPaletteContextKeys.panelBrowserCanGoForward, true)
        #expect(ContentView.commandPaletteBrowserForwardEnabled(context))
    }

    @Test("Address-bar activation selects an exact background browser target")
    func addressBarActivationSelectsExactTarget() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalWorkspaceID = try #require(manager.selectedWorkspace?.id)
        let browserWorkspace = manager.addWorkspace(
            initialSurface: .browser,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let browserPanel = try #require(browserWorkspace.panels.values.first as? BrowserPanel)
        defer { browserPanel.close() }

        #expect(manager.selectedTabId == originalWorkspaceID)
        let activated = manager.activateBrowserPanelForAddressBarFocus(
            workspaceID: browserWorkspace.id,
            panelID: browserPanel.id
        )

        #expect(activated === browserPanel)
        #expect(manager.selectedTabId == browserWorkspace.id)
        #expect(browserWorkspace.focusedPanelId == browserPanel.id)
    }

    @Test("Browser focus actions dismiss the palette before moving AppKit focus")
    func focusActionsDismissBeforeRun() {
        #expect(ContentView.commandPaletteShouldDismissBeforeRun(
            forCommandId: "palette.browserFocusMode"
        ))
        #expect(ContentView.commandPaletteShouldDismissBeforeRun(
            forCommandId: "palette.browserFocusAddressBar"
        ))
    }
}

@MainActor
@Suite("Workspace and global command palette action contracts")
struct CommandPaletteWorkspaceAndGlobalActionContractTests {
    @Test("Full-screen declares optional Boolean enabled")
    func fullScreenDeclaresOptionalEnabled() throws {
        #expect(ContentView.commandPaletteToggleFullScreenArguments.count == 1)
        let argument = try #require(ContentView.commandPaletteToggleFullScreenArguments.first)

        #expect(argument.name == "enabled")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test("Full-screen toggles interactively and treats explicit state idempotently")
    func fullScreenMutationPolicyIsDeterministic() {
        let interactiveToggle = CmuxActionInvocation(source: .commandPalette)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            interactiveToggle,
            currentIsFullScreen: false
        ) == true)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            interactiveToggle,
            currentIsFullScreen: true
        ) == true)

        let enable = CmuxActionInvocation(
            source: .automation,
            arguments: ["enabled": "true"]
        )
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            enable,
            currentIsFullScreen: false
        ) == true)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            enable,
            currentIsFullScreen: true
        ) == false)

        let disable = CmuxActionInvocation(
            source: .automation,
            arguments: ["enabled": "false"]
        )
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            disable,
            currentIsFullScreen: true
        ) == true)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            disable,
            currentIsFullScreen: false
        ) == false)

        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "invalid"]
            ),
            currentIsFullScreen: false
        ) == nil)
    }

    @Test("Focus adapters prefer explicit state and default automation to focused")
    func focusAdapterPolicyIsDeterministic() {
        #expect(!ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["focus": "false"]
            ),
            interactiveDefault: true
        ))
        #expect(ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["focus": "true"]
            ),
            interactiveDefault: false
        ))
        #expect(ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(source: .automation),
            interactiveDefault: false
        ))
        #expect(!ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            interactiveDefault: false
        ))
        #expect(ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            interactiveDefault: true
        ))

        #expect(!ContentView.commandPaletteDiffShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetWasSelected: false
        ))
        #expect(ContentView.commandPaletteDiffShouldFocus(
            CmuxActionInvocation(source: .automation),
            targetWasSelected: false
        ))
    }

    @Test("Update request outcomes map to queued, no-op, and suppression")
    func updateRequestOutcomesAreTruthful() {
        #expect(ContentView.commandPaletteUpdateResult(.accepted) == .queued)
        #expect(ContentView.commandPaletteUpdateResult(.inProgress) == .completed)
        guard case .failed(let code, _) = ContentView.commandPaletteUpdateResult(.suppressed) else {
            Issue.record("Expected a suppressed update request to return typed failure")
            return
        }
        #expect(code == "update_suppressed")

        guard case .failed(let failureCode, _) = ContentView.commandPaletteUpdateResult(.failed) else {
            Issue.record("Expected updater startup failure to remain a typed failure")
            return
        }
        #expect(failureCode == "update_failed")
    }

    @Test("Close action availability requires its exact target scope")
    func closeActionAvailabilityUsesTargetContext() {
        var context = CommandPaletteContextSnapshot()
        #expect(!ContentView.commandPaletteCloseTabIsAvailable(context))
        #expect(!ContentView.commandPaletteCloseWorkspaceIsAvailable(context))

        context.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        #expect(!ContentView.commandPaletteCloseTabIsAvailable(context))
        #expect(ContentView.commandPaletteCloseWorkspaceIsAvailable(context))

        context.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        #expect(ContentView.commandPaletteCloseTabIsAvailable(context))
    }

    @Test("Workspace pull request focus uses explicit and adapter defaults")
    func workspacePullRequestFocusPolicyIsDeterministic() {
        #expect(!ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["focus": "false"]
            ),
            targetWasSelected: true
        ))
        #expect(ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["focus": "true"]
            ),
            targetWasSelected: false
        ))
        #expect(ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(source: .automation),
            targetWasSelected: false
        ))
        #expect(!ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetWasSelected: false
        ))
        #expect(ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetWasSelected: true
        ))
    }

    @Test("Default-terminal errors use the captured interactive window and no automation UI")
    func defaultTerminalFailurePresentationUsesExactTarget() throws {
        let targetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { targetWindow.close() }

        let interactivePresentation = try #require(
            ContentView.commandPaletteDefaultTerminalFailurePresentation(
                CmuxActionInvocation(source: .commandPalette),
                targetWindow: targetWindow
            )
        )
        guard case .alert(presentingWindow: let resolvedWindow) = interactivePresentation else {
            Issue.record("Expected an interactive default-terminal alert")
            return
        }
        #expect(resolvedWindow === targetWindow)
        #expect(ContentView.commandPaletteDefaultTerminalFailurePresentation(
            CmuxActionInvocation(source: .commandPalette),
            targetWindow: nil
        ) == nil)

        let automationPresentation = try #require(
            ContentView.commandPaletteDefaultTerminalFailurePresentation(
                CmuxActionInvocation(source: .automation),
                targetWindow: targetWindow
            )
        )
        guard case .silent = automationPresentation else {
            Issue.record("Expected automation to suppress default-terminal error UI")
            return
        }
    }
}

@MainActor
@Suite(.serialized)
struct CommandPaletteForkActionTests {
    @Test func forkActionsDeclareOptionalBooleanFocus() throws {
        #expect(ContentView.commandPaletteOptionalFocusArguments.count == 1)
        let argument = try #require(ContentView.commandPaletteOptionalFocusArguments.first)

        #expect(argument.name == "focus")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
        #expect(ContentView.commandPaletteForkShouldFocus(
            CmuxActionInvocation(source: .commandPalette)
        ))
        #expect(ContentView.commandPaletteForkShouldFocus(
            CmuxActionInvocation(source: .automation)
        ))
        #expect(!ContentView.commandPaletteForkShouldFocus(
            CmuxActionInvocation(source: .automation, arguments: ["focus": "false"])
        ))
    }

    @Test(arguments: AgentConversationForkDestination.allCases)
    func staleExactPanelReturnsTypedTargetFailure(
        _ destination: AgentConversationForkDestination
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: tabManager.tabs.first?.id,
                panelID: tabManager.tabs.first?.focusedPanelId
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        let contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        var registry = CommandPaletteHandlerRegistry()
        contentView.registerForkAgentConversationCommandPaletteHandlers(
            &registry,
            context: context
        )
        let handler = try #require(registry.handler(for: destination.commandPaletteCommandId))

        guard case .failed(let code, _) = handler(CmuxActionInvocation(source: .automation)) else {
            Issue.record("Expected a typed target failure")
            return
        }
        #expect(code == "target_unavailable")
    }

    @Test(arguments: AgentConversationForkDestination.allCases)
    func focusFalseReservesExactPanelAndPreservesAmbientFocus(
        _ destination: AgentConversationForkDestination
    ) async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let selectedPanelID = try #require(selectedWorkspace.focusedPanelId)
        let targetWorkspace = tabManager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let targetPanelID = try #require(targetWorkspace.focusedPanelId)
        let targetPaneID = try #require(targetWorkspace.paneId(forPanelId: targetPanelID))
        let snapshot = makeForkableClaudeSnapshot()
        targetWorkspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: targetPanelID)

        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: targetWorkspace.id,
                panelID: targetPanelID
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        var contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: targetWorkspace.id,
            panelId: targetPanelID
        )
        contentView.commandPaletteForkableAgentSupportedPanelKeys = [panelKey]
        contentView.commandPaletteForkableAgentSnapshotFingerprintsByPanelKey = [
            panelKey: ContentView.commandPaletteForkSnapshotFingerprint(snapshot)
        ]
        contentView.commandPaletteForkableAgentRemoteContextsByPanelKey = [panelKey: false]
        var registry = CommandPaletteHandlerRegistry()
        contentView.registerForkAgentConversationCommandPaletteHandlers(
            &registry,
            context: context
        )
        let handler = try #require(registry.handler(for: destination.commandPaletteCommandId))
        let invocation = CmuxActionInvocation(
            source: .automation,
            arguments: ["focus": "false"]
        )

        #expect(handler(invocation) == .queued)
        guard case .failed(let duplicateCode, _) = handler(invocation) else {
            Issue.record("Expected the duplicate fork to be rejected synchronously")
            return
        }
        #expect(duplicateCode == "action_in_progress")
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)
        #expect(targetWorkspace.focusedPanelId == targetPanelID)

        await Task.yield()

        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)
        #expect(targetWorkspace.focusedPanelId == targetPanelID)
        switch destination {
        case .right, .left, .top, .bottom:
            #expect(targetWorkspace.bonsplitController.allPaneIds.count == 2)
        case .newTab:
            #expect(targetWorkspace.bonsplitController.tabs(inPane: targetPaneID).count == 2)
        case .newWorkspace:
            #expect(tabManager.tabs.count == 3)
        }
    }

    private func makeForkableClaudeSnapshot() -> SessionRestorableAgentSnapshot {
        let workingDirectory = "/tmp/command-palette-fork"
        return SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }
}

@MainActor
@Suite("Terminal command palette action preconditions")
struct CommandPaletteTerminalActionPreconditionTests {
    @Test func findActionsRejectMissingSearchAndSelection() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)

        #expect(!manager.findNext(workspaceID: workspace.id, panelID: panelID))
        #expect(!manager.findPrevious(workspaceID: workspace.id, panelID: panelID))
        #expect(!manager.hideFind(workspaceID: workspace.id, panelID: panelID))
        #expect(!manager.searchSelection(workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.terminalPanel(for: panelID)?.searchState == nil)
    }
}

@MainActor
@Suite("Command palette typed view and identifier outcomes", .serialized)
struct CommandPaletteTypedViewAndIdentifierOutcomeTests {
    @Test func triggerFlashIsVisibleOnlyWithACapturedPanel() throws {
        let contribution = try #require(
            ContentView.commandPaletteViewCommandContributions().first {
                $0.commandId == "palette.triggerFlash"
            }
        )
        var context = CommandPaletteContextSnapshot()

        #expect(!contribution.when(context))
        context.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        #expect(contribution.when(context))
    }

    @Test func identifierCopyHandlersWriteTheExactBackgroundTargetAndReportCompletion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("cmux.palette.identifiers.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerIdentifierCopyCommandHandlers(
            &registry,
            context: fixture.context,
            pasteboard: pasteboard
        )
        let paneID = try #require(
            fixture.targetWorkspace.paneId(forPanelId: fixture.targetPanelID)?.id
        )
        let panel = try #require(fixture.targetWorkspace.panels[fixture.targetPanelID])
        let expectedSubstringByCommandID = [
            "palette.copyWorkspaceID": fixture.targetWorkspace.id.uuidString,
            "palette.copyWorkspaceIDAndRef": fixture.targetWorkspace.id.uuidString,
            "palette.copyWorkspaceLink": WorkspaceSurfaceIdentifierClipboardText.makeWorkspaceLink(
                workspaceId: fixture.targetWorkspace.stableId
            ),
            "palette.copyPaneID": paneID.uuidString,
            "palette.copyPaneLink": WorkspaceSurfaceIdentifierClipboardText.makePaneLink(
                workspaceId: fixture.targetWorkspace.stableId,
                paneId: paneID
            ),
            "palette.copySurfaceID": fixture.targetPanelID.uuidString,
            "palette.copySurfaceLink": WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: fixture.targetWorkspace.stableId,
                surfaceId: panel.stableSurfaceId
            ),
            "palette.copyIdentifiers": fixture.targetPanelID.uuidString,
        ]

        for (commandID, expectedSubstring) in expectedSubstringByCommandID {
            pasteboard.clearContents()
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(CmuxActionInvocation(source: .automation)) == .completed)
            #expect(pasteboard.string(forType: .string)?.contains(expectedSubstring) == true)
            #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
            #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)
        }

        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))
        _ = pasteboard.clearContents()
        #expect(pasteboard.setString("unchanged", forType: .string))
        for commandID in expectedSubstringByCommandID.keys {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(CmuxActionInvocation(source: .automation)) == .targetUnavailable)
            #expect(pasteboard.string(forType: .string) == "unchanged")
        }
    }

    @Test func identifierCopyWriteFailureHasATypedOutcome() {
        #expect(
            ContentView.identifierCopyExecutionResult(didWrite: false)
                == .failed(
                    code: "clipboard_write_failed",
                    message: String(
                        localized: "action.error.identifierCopyFailed",
                        defaultValue: "The identifiers could not be copied."
                    )
                )
        )
    }

    @Test func viewHandlersReportExactOutcomesWithoutChangingSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var taskManagerPresentations = 0
        var sleepyModePresentations = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerViewCommandHandlers(
            &registry,
            context: fixture.context,
            showTaskManager: { taskManagerPresentations += 1 },
            activateSleepyMode: { sleepyModePresentations += 1 }
        )

        let invocation = CmuxActionInvocation(source: .automation)
        let triggerFlash = try #require(registry.handler(for: "palette.triggerFlash"))
        let openTaskManager = try #require(registry.handler(for: "palette.openTaskManager"))
        let activateSleepyMode = try #require(registry.handler(for: "palette.sleepyMode"))
        #expect(triggerFlash(invocation) == .completed)
        #expect(openTaskManager(invocation) == .presented)
        #expect(activateSleepyMode(invocation) == .presented)
        #expect(taskManagerPresentations == 1)
        #expect(sleepyModePresentations == 1)
        #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
        #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)

        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))
        for commandID in ["palette.triggerFlash", "palette.openTaskManager", "palette.sleepyMode"] {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(invocation) == .targetUnavailable)
        }
        #expect(taskManagerPresentations == 1)
        #expect(sleepyModePresentations == 1)
    }

    @Test func tabPinHandlerReportsQueuedUntilRemoteMirrorVerification() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let workspace = fixture.targetWorkspace
        let targetPanelID = fixture.nonTargetPanelID
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let orderBefore = workspace.bonsplitController.tabs(inPane: paneID)
            .compactMap { workspace.panelIdFromSurfaceId($0.id) }
        workspace.isRemoteTmuxMirror = true
        var verification: ((Bool) -> Void)?
        workspace.remoteTmuxWindowOrderSync = { _, completion in
            verification = completion
            return true
        }
        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: fixture.windowID,
                workspaceID: workspace.id,
                panelID: targetPanelID
            ),
            tabManager: fixture.tabManager,
            owningWindowID: fixture.windowID
        )
        let emptyCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: context,
            configCatalog: emptyCatalog
        )
        let handler = try #require(registry.handler(for: "palette.toggleTabPin"))
        let invocation = CmuxActionInvocation(
            source: .automation,
            arguments: ["pinned": "true"]
        )

        #expect(handler(invocation) == .queued)
        #expect(handler(invocation) == .queued)
        #expect(workspace.isPanelPinned(targetPanelID))

        verification?(false)

        #expect(!workspace.isPanelPinned(targetPanelID))
        #expect(workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder: orderBefore))
    }

    @Test func proPresentationOutcomesAreTyped() {
        #expect(ContentView.commandPaletteProPresentationResult(targetAvailable: true) == .presented)
        #expect(ContentView.commandPaletteProPresentationResult(targetAvailable: false) == .targetUnavailable)
    }

    @Test func proHandlersRejectAStaleExactPanelBeforePresentation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerProCommandHandlers(
            &registry,
            context: fixture.context
        )
        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))

        let invocation = CmuxActionInvocation(source: .automation)
        for commandID in [
            ContentView.commandPaletteProUpgradeCommandId,
            ContentView.commandPaletteProWelcomeChecklistCommandId,
        ] {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(invocation) == .targetUnavailable)
        }
    }

    @Test func cmuxOwnedHandlerIDsReserveFeatureOffAndDynamicActions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let flags = CmuxFeatureFlags.shared
        let agentChatFlag = try #require(
            CmuxFeatureFlags.allFlags.first { $0.key == "agent-chat-ui-enabled-release" }
        )
        let previousAgentChatOverride = flags.overrideValue(for: agentChatFlag)
        flags.setOverride(false, for: agentChatFlag)
        defer { flags.setOverride(previousAgentChatOverride, for: agentChatFlag) }

        let extensionsKey = BetaFeaturesCatalogSection().extensions.userDefaultsKey
        let previousExtensionsValue = UserDefaults.standard.object(forKey: extensionsKey)
        UserDefaults.standard.set(false, forKey: extensionsKey)
        defer {
            if let previousExtensionsValue {
                UserDefaults.standard.set(previousExtensionsValue, forKey: extensionsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: extensionsKey)
            }
        }

        let emptyCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyCatalog
        )

        let agentChatID = "palette.newAgentChat"
        let hostedExtensionID = ContentView.commandPaletteExtensionSidebarCommandID(
            CmuxExtensionSidebarSelection.hostedExtensionsProviderId
        )
        #expect(ContentView.commandPaletteNewAgentChatContributions().isEmpty)
        #expect(!CmuxExtensionSidebarSelection.descriptors.contains {
            $0.id == CmuxExtensionSidebarSelection.hostedExtensionsProviderId
        })

        let representativeOwnedIDs: Set<String> = [
            ContentView.commandPaletteAuthSignInCommandId,
            ContentView.commandPaletteCloudOpenCommandId,
            agentChatID,
            "palette.canvas.toggleLayout",
            CommandPaletteSettingsToggleCommands.commandIdPrefix + "workspaceInheritWorkingDirectory",
            "palette.layout.saveCurrent",
            hostedExtensionID,
        ]
        #expect(representativeOwnedIDs.isSubset(of: registry.commandIDs))

        var beeps = 0
        var agentChatRegistry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAgentChatCommandPaletteHandler(
            &agentChatRegistry,
            context: fixture.context,
            configCatalog: emptyCatalog,
            beep: { beeps += 1 }
        )
        let agentChatHandler = try #require(agentChatRegistry.handler(for: agentChatID))
        guard case .failed(let automationCode, _) = agentChatHandler(
            CmuxActionInvocation(source: .automation)
        ) else {
            Issue.record("Expected disabled agent chat to return a typed failure")
            return
        }
        #expect(automationCode == "action_unavailable")
        #expect(beeps == 0)
        _ = agentChatHandler(CmuxActionInvocation(source: .commandPalette))
        #expect(beeps == 1)

        let collidingActions = [agentChatID, hostedExtensionID].map { id in
            CmuxResolvedConfigAction(
                id: id,
                title: id,
                subtitle: nil,
                keywords: [],
                palette: true,
                shortcut: nil,
                icon: nil,
                tooltip: nil,
                action: .command("echo collision"),
                confirm: nil,
                terminalCommandTarget: nil,
                actionSourcePath: "/tmp/cmux.json",
                iconSourcePath: nil,
                newWorkspaceMenu: nil
            )
        }
        let collisionCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: collidingActions,
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        let composition = collisionCatalog.composingPaletteActions(
            reservedActionIDs: registry.commandIDs,
            diagnosticActionID: { "diagnostic.\($0.id)" }
        )

        #expect(composition.actions.isEmpty)
        #expect(Set(composition.issues.compactMap(\.commandName)) == [agentChatID, hostedExtensionID])
    }

    @Test func authSignInPresentsFromTheExactBackgroundTargetWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var presentedWindow: NSWindow?
        var beeps = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                CommandPaletteAuthActions(
                    isAuthenticated: false,
                    isWorking: false,
                    beginSignIn: { window in
                        presentedWindow = window
                        return true
                    },
                    signOut: {}
                )
            },
            beep: { beeps += 1 }
        )
        let handler = try #require(
            registry.handler(for: ContentView.commandPaletteAuthSignInCommandId)
        )

        #expect(handler(CmuxActionInvocation(source: .automation)) == .presented)
        #expect(presentedWindow === fixture.window)
        #expect(beeps == 0)
        #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
        #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)
    }

    @Test func authHandlersRejectAStaleExactPanelBeforeStartingWork() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var authLookups = 0
        var beeps = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                authLookups += 1
                return CommandPaletteAuthActions(
                    isAuthenticated: false,
                    isWorking: false,
                    beginSignIn: { _ in true },
                    signOut: {}
                )
            },
            beep: { beeps += 1 }
        )
        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))

        for commandID in [
            ContentView.commandPaletteAuthSignInCommandId,
            ContentView.commandPaletteAuthSignOutCommandId,
        ] {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(CmuxActionInvocation(source: .automation)) == .targetUnavailable)
        }
        #expect(authLookups == 0)
        #expect(beeps == 0)
    }

    @Test func authSignOutReportsQueuedOnlyAfterAcceptingWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var signOutCalls = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                CommandPaletteAuthActions(
                    isAuthenticated: true,
                    isWorking: false,
                    beginSignIn: { _ in false },
                    signOut: { signOutCalls += 1 }
                )
            }
        )
        let handler = try #require(
            registry.handler(for: ContentView.commandPaletteAuthSignOutCommandId)
        )

        #expect(handler(CmuxActionInvocation(source: .automation)) == .queued)
        await Task.yield()
        #expect(signOutCalls == 1)
        #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
        #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)
    }

    @Test func authSignInFailureIsTypedAndAutomationDoesNotBeep() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var beeps = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                CommandPaletteAuthActions(
                    isAuthenticated: false,
                    isWorking: false,
                    beginSignIn: { _ in false },
                    signOut: {}
                )
            },
            beep: { beeps += 1 }
        )
        let handler = try #require(
            registry.handler(for: ContentView.commandPaletteAuthSignInCommandId)
        )

        guard case .failed(let code, _) = handler(
            CmuxActionInvocation(source: .automation)
        ) else {
            Issue.record("Expected a typed sign-in failure")
            return
        }
        #expect(code == "auth_sign_in_failed")
        #expect(beeps == 0)

        _ = handler(CmuxActionInvocation(source: .commandPalette))
        #expect(beeps == 1)
    }

    private struct Fixture {
        let previousAppDelegate: AppDelegate?
        let appDelegate: AppDelegate
        let window: NSWindow
        let windowID: UUID
        let tabManager: TabManager
        let selectedWorkspace: Workspace
        let targetWorkspace: Workspace
        let targetPanelID: UUID
        let nonTargetPanelID: UUID
        let context: CommandPaletteActionContext
        let contentView: ContentView

        func cleanup() {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }
    }

    private func makeFixture() throws -> Fixture {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let targetWorkspace = tabManager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let targetPanelID = try #require(targetWorkspace.focusedPanelId)
        let nonTargetPanel = try #require(
            targetWorkspace.newTerminalSurfaceInFocusedPane(
                focus: true,
                initialInput: nil
            )
        )
        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        AppDelegate.shared = appDelegate
        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: targetWorkspace.id,
                panelID: targetPanelID
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        let contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        return Fixture(
            previousAppDelegate: previousAppDelegate,
            appDelegate: appDelegate,
            window: window,
            windowID: windowID,
            tabManager: tabManager,
            selectedWorkspace: selectedWorkspace,
            targetWorkspace: targetWorkspace,
            targetPanelID: targetPanelID,
            nonTargetPanelID: nonTargetPanel.id,
            context: context,
            contentView: contentView
        )
    }
}

private struct CLIPathFixture {
    let fileManager: FileManager
    let rootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let installer: CmuxCLIPathInstaller

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }
}
