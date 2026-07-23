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
    @Test func bootstrapDefersSocketListenerUntilTheInitialWindowRegistersPaletteDependencies() {
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

        let didPublishAfterDependencies = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            cmuxConfigStore: CmuxConfigStore(startFileWatchers: false),
            commandPaletteControlHandler: {
                $0.complete(.listed(target: $0.target, commands: []))
            }
        )

        #expect(didPublishAfterDependencies)
        #expect(activations.count == 1)
        #expect(activations.first?.0 === tabManager)
        #expect(activations.first?.1 == "mainWindow.register")
    }

    @Test func handlerOnlyBootstrapRemainsUnadvertisedWithoutAConfigStore() {
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

        let didPublishHandlerOnly = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            commandPaletteControlHandler: {
                $0.complete(.listed(target: $0.target, commands: []))
            }
        )

        #expect(!didPublishHandlerOnly)
        #expect(appDelegate.mainWindowContext(for: tabManager)?.commandPaletteControlHandler != nil)
        #expect(appDelegate.mainWindowContext(for: tabManager)?.cmuxConfigStore == nil)

        let bootstrappedWindowID = appDelegate.bootstrapInitialMainWindowIfNeeded(
            debugSource: "commandPaletteHandlerOnlyRegistrationTest",
            shouldActivate: false,
            suppressWelcome: true
        )

        #expect(bootstrappedWindowID == windowID)
        #expect(activations.isEmpty)
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

    @Test func registeredWindowPublishesItsHandlerWithItsRoutingContext() async {
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
                request.complete(.listed(target: request.target, commands: [item]))
            }
        )
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let resolution = await TerminalController.shared.controlCommandPaletteList(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: windowID,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            ),
            deadline: nil
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

    @Test func staleSelectorsDoNotFallBackToTheCallerWindow() async {
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        var handlerCalls = 0
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                handlerCalls += 1
                request.complete(.listed(target: request.target, commands: []))
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
            let resolution = await TerminalController.shared.controlCommandPaletteList(
                routing: selector,
                deadline: nil
            )
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
            let resolution = await TerminalController.shared.controlCommandPaletteList(
                routing: selector,
                deadline: nil
            )
            #expect(resolution == .windowNotFound)
            let inlineResolution = TerminalController.shared.controlInlineVSCodeOpen(
                routing: selector,
                directoryPath: FileManager.default.temporaryDirectory.path
            )
            #expect(inlineResolution == .workspaceNotFound)
        }
        #expect(handlerCalls == 0)
    }

    @Test func crossWindowSelectorsDoNotRouteThroughAnExplicitWindow() async throws {
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
                request.complete(.listed(target: request.target, commands: []))
            }
        )
        let windowB = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerB,
            commandPaletteControlHandler: { request in
                handlerCallsB += 1
                request.complete(.listed(target: request.target, commands: []))
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
            let resolution = await TerminalController.shared.controlCommandPaletteList(
                routing: selector,
                deadline: nil
            )
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

    @Test func validSelectorsAndNoSelectorRetainTheirWindowRouting() async throws {
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
            commandPaletteControlHandler: {
                $0.complete(.listed(target: $0.target, commands: []))
            }
        )
        let windowB = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerB,
            commandPaletteControlHandler: {
                $0.complete(.listed(target: $0.target, commands: []))
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

        let validSelectors = [
            routing(groupID: groupB),
            routing(workspaceID: workspaceB.id),
            routing(surfaceID: surfaceB),
            routing(paneID: paneB),
        ]
        for selector in validSelectors {
            let resolution = await TerminalController.shared.controlCommandPaletteList(
                routing: selector,
                deadline: nil
            )
            guard case .listed(let target, _) = resolution else {
                Issue.record("Expected valid selector to route to its owning window")
                continue
            }
            #expect(target.windowID == windowB)
        }

        let fallback = await TerminalController.shared.controlCommandPaletteList(
            routing: routing(),
            deadline: nil
        )
        guard case .listed(let fallbackTarget, _) = fallback else {
            Issue.record("Expected an omitted selector to route to the caller window")
            return
        }
        #expect(fallbackTarget.windowID == windowA)
    }

    @Test func workspaceSelectorReachesTheHandlerWithoutChangingSelection() async throws {
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
                request.complete(.listed(target: request.target, commands: []))
            }
        )
        AppDelegate.shared = appDelegate
        TerminalController.shared.setActiveTabManager(tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let resolution = await TerminalController.shared.controlCommandPaletteList(
            routing: routing(workspaceID: targetWorkspace.id),
            deadline: nil
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

    @Test func listedIdentityCanBeEchoedAfterFocusChangesWithoutRetargetingRun() async throws {
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
        let configSnapshotID = UUID()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                if receivedTargets.isEmpty {
                    let listedTarget = CommandPaletteActionTarget(
                        windowID: request.target.windowID,
                        workspaceID: request.target.workspaceID,
                        panelID: request.target.panelID,
                        configSnapshotID: configSnapshotID
                    )
                    receivedTargets.append(listedTarget)
                    request.complete(.listed(target: listedTarget, commands: [item]))
                } else {
                    receivedTargets.append(request.target)
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

        let list = await TerminalController.shared.controlCommandPaletteList(
            routing: routing(windowID: windowID),
            deadline: nil
        )
        guard case .listed(let listedTarget, _) = list else {
            Issue.record("Expected palette target identity")
            return
        }
        #expect(listedTarget == ControlCommandPaletteTarget(
            windowID: windowID,
            workspaceID: listedWorkspace.id,
            panelID: listedPanelID,
            configSnapshotID: configSnapshotID
        ))

        tabManager.selectedTabId = laterWorkspace.id
        let run = await TerminalController.shared.controlCommandPaletteRun(
            target: listedTarget,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil,
            deadline: nil
        )

        guard case .completed(let runWindowID, _) = run else {
            Issue.record("Expected echoed palette target to run")
            return
        }
        #expect(runWindowID == windowID)
        let expectedTarget = CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: listedWorkspace.id,
            panelID: listedPanelID,
            configSnapshotID: configSnapshotID
        )
        #expect(receivedTargets == [expectedTarget, expectedTarget])
        #expect(tabManager.selectedWorkspace?.id == laterWorkspace.id)
    }

    @Test func echoedIdentityDistinguishesADeletedPanelFromADeletedWindow() async throws {
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
                request.complete(.listed(target: request.target, commands: []))
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
        #expect(await TerminalController.shared.controlCommandPaletteRun(
            target: target,
            commandID: "palette.fixture",
            arguments: [:],
            workingDirectory: nil,
            deadline: nil
        ) == .targetUnavailable)
        #expect(handlerCalls == 0)

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        #expect(await TerminalController.shared.controlCommandPaletteRun(
            target: target,
            commandID: "palette.fixture",
            arguments: [:],
            workingDirectory: nil,
            deadline: nil
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

    @Test func surfaceAndPaneSelectorsReachTheHandlerAsOneExactTarget() async throws {
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
                request.complete(.listed(target: request.target, commands: []))
            }
        )
        AppDelegate.shared = appDelegate
        TerminalController.shared.setActiveTabManager(tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        _ = await TerminalController.shared.controlCommandPaletteList(
            routing: routing(surfaceID: targetPanelID),
            deadline: nil
        )
        _ = await TerminalController.shared.controlCommandPaletteList(
            routing: routing(paneID: targetPaneID),
            deadline: nil
        )

        let expectedTarget = CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: targetWorkspace.id,
            panelID: targetPanelID
        )
        #expect(receivedTargets == [expectedTarget, expectedTarget])
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(
            await TerminalController.shared.controlCommandPaletteList(
                routing: routing(workspaceID: selectedWorkspace.id, surfaceID: targetPanelID),
                deadline: nil
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

    @Test func windowDockWorkspaceRoutingUsesTheOwningWindowSelection() async throws {
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
        let ownerRun = await TerminalController.shared.controlCommandPaletteRun(
            routing: ownerRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil,
            deadline: nil
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
        let surfaceRun = await TerminalController.shared.controlCommandPaletteRun(
            routing: surfaceRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil,
            deadline: nil
        )
        guard case .completed(let surfaceWindowID, _) = surfaceRun else {
            Issue.record("Expected Dock surface routing to run in its owning window")
            return
        }
        #expect(surfaceWindowID == targetWindowID)
        #expect(handledWorkspaceIDs == [selectedTargetWorkspace.id, selectedTargetWorkspace.id])
        #expect(
            await TerminalController.shared.controlCommandPaletteRun(
                routing: routing(windowID: callerWindowID, surfaceID: targetDockSurfaceID),
                commandID: item.id,
                arguments: [:],
                workingDirectory: nil,
                deadline: nil
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
        let aliasRun = await TerminalController.shared.controlCommandPaletteRun(
            routing: aliasRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil,
            deadline: nil
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
        let paneRun = await TerminalController.shared.controlCommandPaletteRun(
            routing: paneRouting,
            commandID: item.id,
            arguments: [:],
            workingDirectory: nil,
            deadline: nil
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
            await TerminalController.shared.controlCommandPaletteRun(
                routing: routing(windowID: callerWindowID, paneID: targetDockPane.id),
                commandID: item.id,
                arguments: [:],
                workingDirectory: nil,
                deadline: nil
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
            await TerminalController.shared.controlCommandPaletteRun(
                routing: unrelatedRouting,
                commandID: item.id,
                arguments: [:],
                workingDirectory: nil,
                deadline: nil
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
