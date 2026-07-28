import AppKit
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

@testable import CmuxControlSocket

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CommandPaletteControlRegistrationTests {
    @Test func registrationStartsRealSocketOnlyAfterBothPaletteDependenciesExist() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let controller = TerminalController.shared
            let previousAppDelegate = AppDelegate.shared
            let previousTabManager = controller.activeTabManagerForCallerNotification()
            let previousSocketState = controller.socketServer.listenerStateSnapshot()
            let defaults = UserDefaults.standard
            let previousStoredMode = defaults.object(forKey: SocketControlSettings.appStorageKey)
            let environmentKeys = ["CMUX_SOCKET_ENABLE", "CMUX_SOCKET_MODE"]
            let environment = ProcessInfo.processInfo.environment
            let previousEnvironment = environmentKeys.map { ($0, environment[$0]) }
            let socketPath = "/tmp/cmux-cpr-\(UUID().uuidString.prefix(8)).sock"
            let appDelegate = AppDelegate()
            let handlerOnlyManager = TabManager()
            let configOnlyManager = TabManager()
            let handlerOnlyWindowID = UUID()
            let configOnlyWindowID = UUID()
            let handlerOnlyWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let configOnlyWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            let (startPaths, startContinuation) = AsyncStream<String>.makeStream(
                bufferingPolicy: .unbounded
            )
            let observer = NotificationCenter.default.addObserver(
                forName: .socketListenerDidStart,
                object: controller,
                queue: nil
            ) { notification in
                if let path = notification.userInfo?["path"] as? String {
                    startContinuation.yield(path)
                }
            }

            controller.stop()
            controller.setActiveTabManager(nil)
            defaults.set(
                SocketControlMode.automation.rawValue,
                forKey: SocketControlSettings.appStorageKey
            )
            unsetenv("CMUX_SOCKET_ENABLE")
            setenv("CMUX_SOCKET_MODE", SocketControlMode.automation.rawValue, 1)
            #expect(controller.reserveStartupSocketPath(socketPath) == socketPath)
            AppDelegate.shared = appDelegate

            defer {
                startContinuation.finish()
                NotificationCenter.default.removeObserver(observer)
                appDelegate.unregisterMainWindowContextForTesting(windowId: handlerOnlyWindowID)
                appDelegate.unregisterMainWindowContextForTesting(windowId: configOnlyWindowID)
                handlerOnlyWindow.close()
                configOnlyWindow.close()
                controller.stop()
                if let previousStoredMode {
                    defaults.set(previousStoredMode, forKey: SocketControlSettings.appStorageKey)
                } else {
                    defaults.removeObject(forKey: SocketControlSettings.appStorageKey)
                }
                for (key, value) in previousEnvironment {
                    if let value {
                        setenv(key, value, 1)
                    } else {
                        unsetenv(key)
                    }
                }
                controller.setActiveTabManager(nil)
                AppDelegate.shared = previousAppDelegate
                Self.restoreSocketState(
                    previousSocketState,
                    on: controller,
                    routingFallbackTabManager: previousTabManager
                )
                let restoredSocketState = controller.socketServer.listenerStateSnapshot()
                #expect(restoredSocketState.isRunning == previousSocketState.isRunning)
                #expect(restoredSocketState.socketPath == previousSocketState.socketPath)
                #expect(
                    restoredSocketState.reservedStartupSocketPath
                        == previousSocketState.reservedStartupSocketPath
                )
                #expect(
                    restoredSocketState.configuredPreferredSocketPath
                        == previousSocketState.configuredPreferredSocketPath
                )
                #expect(controller.socketServer.accessMode == previousSocketState.accessMode)
                unlink(socketPath)
                unlink(socketPath + ".lock")
            }

            let handlerOnlyPublished = appDelegate.registerMainWindow(
                handlerOnlyWindow,
                windowId: handlerOnlyWindowID,
                tabManager: handlerOnlyManager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                commandPaletteControlHandler: {
                    $0.complete(.listed(target: $0.target, commands: []))
                }
            )
            #expect(!handlerOnlyPublished)
            #expect(!controller.socketServer.isRunning)
            #expect(!controller.socketListenerHealth(expectedSocketPath: socketPath).isHealthy)

            let configOnlyPublished = appDelegate.registerMainWindow(
                configOnlyWindow,
                windowId: configOnlyWindowID,
                tabManager: configOnlyManager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                cmuxConfigStore: CmuxConfigStore(startFileWatchers: false)
            )
            #expect(!configOnlyPublished)
            #expect(!controller.socketServer.isRunning)
            #expect(!controller.socketListenerHealth(expectedSocketPath: socketPath).isHealthy)

            let readyPublished = appDelegate.registerMainWindow(
                handlerOnlyWindow,
                windowId: handlerOnlyWindowID,
                tabManager: handlerOnlyManager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                cmuxConfigStore: CmuxConfigStore(startFileWatchers: false),
                commandPaletteControlHandler: {
                    $0.complete(.listed(target: $0.target, commands: []))
                }
            )
            #expect(readyPublished)
            #expect(controller.socketListenerHealth(expectedSocketPath: socketPath).isHealthy)
            let pingResponse = await Task.detached {
                SocketTransport().probeCommand("ping", at: socketPath, timeout: 1)
            }.value
            #expect(pingResponse == "PONG")

            startContinuation.finish()
            var observedStartPaths: [String] = []
            for await path in startPaths {
                observedStartPaths.append(path)
            }
            #expect(observedStartPaths == [socketPath])
        }
    }

    @Test func handlerOnlyBootstrapRemainsUnadvertisedWithoutAConfigStore() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
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
            #expect(
                appDelegate.mainWindowContext(for: tabManager)?.commandPaletteControlHandler != nil)
            #expect(appDelegate.mainWindowContext(for: tabManager)?.cmuxConfigStore == nil)

            let bootstrappedWindowID = appDelegate.bootstrapInitialMainWindowIfNeeded(
                debugSource: "commandPaletteHandlerOnlyRegistrationTest",
                shouldActivate: false,
                suppressWelcome: true
            )

            #expect(bootstrappedWindowID == windowID)
            #expect(
                !appDelegate.isCommandPaletteControlReady(
                    appDelegate.mainWindowContext(for: tabManager)
                ))
        }
    }

    @Test func registrationDoesNotPublishSocketControlBeforeItsHandlerExists() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
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
            #expect(
                appDelegate.mainWindowContext(for: tabManager)?.commandPaletteControlHandler == nil)
        }
    }

    @Test func snapshotlessListedTargetFailsClosedAsConfigurationPending() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
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

            #expect(resolution == .configurationPending)
        }
    }

    @Test func listUsesCurrentHandlerAfterConfigurationDiscoverySuspends() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let reader = CommandPaletteBlockingRawReader()
            let configStore = CmuxConfigStore(
                startFileWatchers: false,
                actionCatalogRawReader: reader
            )
            let staleItem = CommandPaletteControlRequestItem(
                id: "palette.stale",
                title: "Stale",
                subtitle: "Tests",
                shortcutHint: nil,
                keywords: [],
                dismissOnRun: true,
                arguments: []
            )
            let currentItem = CommandPaletteControlRequestItem(
                id: "palette.current",
                title: "Current",
                subtitle: "Tests",
                shortcutHint: nil,
                keywords: [],
                dismissOnRun: true,
                arguments: []
            )
            var staleHandlerCalls = 0
            var currentHandlerCalls = 0
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: tabManager,
                cmuxConfigStore: configStore,
                commandPaletteControlHandler: { request in
                    staleHandlerCalls += 1
                    request.complete(
                        .listed(
                            target: Self.versionedTarget(request.target),
                            commands: [staleItem]
                        ))
                }
            )
            AppDelegate.shared = appDelegate
            TerminalController.shared.setActiveTabManager(tabManager)
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                TerminalController.shared.setActiveTabManager(previousActiveManager)
                AppDelegate.shared = previousAppDelegate
            }

            let resolution = try await runWhileRawReaderIsBlocked(
                reader: reader,
                operation: {
                    await TerminalController.shared.controlCommandPaletteList(
                        routing: routing(windowID: windowID),
                        deadline: nil
                    )
                },
                afterReadStarts: {
                    let context = try #require(appDelegate.mainWindowContext(for: tabManager))
                    context.commandPaletteControlHandler = { request in
                        currentHandlerCalls += 1
                        request.complete(
                            .listed(
                                target: Self.versionedTarget(request.target),
                                commands: [currentItem]
                            ))
                    }
                }
            )

            guard case .listed(_, let commands) = resolution else {
                Issue.record("Expected the current command palette handler to list")
                return
            }
            #expect(commands.map(\.id) == [currentItem.id])
            #expect(staleHandlerCalls == 0)
            #expect(currentHandlerCalls == 1)
        }
    }

    @Test func exactRunRejectsAConfigStoreReplacedDuringDiscovery() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(tabManager.tabs.first)
            let panelID = try #require(workspace.panels.keys.first)
            let reader = CommandPaletteBlockingRawReader()
            let staleConfigStore = CmuxConfigStore(
                startFileWatchers: false,
                actionCatalogRawReader: reader
            )
            let currentConfigStore = CmuxConfigStore(startFileWatchers: false)
            let item = CommandPaletteControlRequestItem(
                id: "palette.fixture",
                title: "Fixture",
                subtitle: "Tests",
                shortcutHint: nil,
                keywords: [],
                dismissOnRun: true,
                arguments: []
            )
            var staleHandlerOperations: [RecordedCommandPaletteOperation] = []
            var currentHandlerOperations: [RecordedCommandPaletteOperation] = []
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: tabManager,
                cmuxConfigStore: staleConfigStore,
                commandPaletteControlHandler: { request in
                    staleHandlerOperations.append(
                        Self.completeProductionStyleRequest(request, item: item)
                    )
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
                panelID: panelID,
                configSnapshotID: UUID()
            )

            let resolution = try await runWhileRawReaderIsBlocked(
                reader: reader,
                operation: {
                    await TerminalController.shared.controlCommandPaletteRun(
                        target: target,
                        commandID: item.id,
                        arguments: [:],
                        workingDirectory: nil,
                        deadline: nil
                    )
                },
                afterReadStarts: {
                    let context = try #require(appDelegate.mainWindowContext(for: tabManager))
                    context.cmuxConfigStore = currentConfigStore
                    context.commandPaletteControlHandler = { request in
                        currentHandlerOperations.append(
                            Self.completeProductionStyleRequest(request, item: item)
                        )
                    }
                }
            )

            #expect(resolution == .configurationChanged)
            #expect(staleHandlerOperations.isEmpty)
            #expect(currentHandlerOperations.isEmpty)
        }
    }

    @Test func exactRunUsesCurrentHandlerAfterConfigurationDiscoverySuspends() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(tabManager.tabs.first)
            let panelID = try #require(workspace.panels.keys.first)
            let reader = CommandPaletteBlockingRawReader()
            let configStore = CmuxConfigStore(
                startFileWatchers: false,
                actionCatalogRawReader: reader
            )
            let item = CommandPaletteControlRequestItem(
                id: "palette.fixture",
                title: "Fixture",
                subtitle: "Tests",
                shortcutHint: nil,
                keywords: [],
                dismissOnRun: true,
                arguments: []
            )
            var staleHandlerOperations: [RecordedCommandPaletteOperation] = []
            var currentHandlerOperations: [RecordedCommandPaletteOperation] = []
            var receivedTargets: [CommandPaletteActionTarget] = []
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: tabManager,
                cmuxConfigStore: configStore,
                commandPaletteControlHandler: { request in
                    staleHandlerOperations.append(
                        Self.completeProductionStyleRequest(request, item: item)
                    )
                }
            )
            AppDelegate.shared = appDelegate
            TerminalController.shared.setActiveTabManager(tabManager)
            defer {
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                TerminalController.shared.setActiveTabManager(previousActiveManager)
                AppDelegate.shared = previousAppDelegate
            }
            let configSnapshotID = UUID()
            let target = ControlCommandPaletteTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                panelID: panelID,
                configSnapshotID: configSnapshotID
            )

            let resolution = try await runWhileRawReaderIsBlocked(
                reader: reader,
                operation: {
                    await TerminalController.shared.controlCommandPaletteRun(
                        target: target,
                        commandID: item.id,
                        arguments: [:],
                        workingDirectory: nil,
                        deadline: nil
                    )
                },
                afterReadStarts: {
                    let context = try #require(appDelegate.mainWindowContext(for: tabManager))
                    context.commandPaletteControlHandler = { request in
                        receivedTargets.append(request.target)
                        currentHandlerOperations.append(
                            Self.completeProductionStyleRequest(request, item: item)
                        )
                    }
                }
            )

            guard case .completed(let completedWindowID, _) = resolution else {
                Issue.record("Expected the current command palette handler to run")
                return
            }
            #expect(completedWindowID == windowID)
            let expectedTarget = CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                panelID: panelID,
                configSnapshotID: configSnapshotID
            )
            #expect(receivedTargets == [expectedTarget, expectedTarget])
            #expect(staleHandlerOperations.isEmpty)
            #expect(
                currentHandlerOperations == [
                    .list,
                    .run(commandID: item.id, arguments: [:], workingDirectory: nil),
                ])
        }
    }

    @Test func exactRunRejectsAContextReregisteredDuringDiscovery() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(tabManager.tabs.first)
            let panelID = try #require(workspace.panels.keys.first)
            let reader = CommandPaletteBlockingRawReader()
            let configStore = CmuxConfigStore(
                startFileWatchers: false,
                actionCatalogRawReader: reader
            )
            let item = CommandPaletteControlRequestItem(
                id: "palette.fixture",
                title: "Fixture",
                subtitle: "Tests",
                shortcutHint: nil,
                keywords: [],
                dismissOnRun: true,
                arguments: []
            )
            var detachedHandlerOperations: [RecordedCommandPaletteOperation] = []
            var currentHandlerOperations: [RecordedCommandPaletteOperation] = []
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: tabManager,
                cmuxConfigStore: configStore,
                commandPaletteControlHandler: { request in
                    detachedHandlerOperations.append(
                        Self.completeProductionStyleRequest(request, item: item)
                    )
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
                panelID: panelID,
                configSnapshotID: UUID()
            )

            let resolution = try await runWhileRawReaderIsBlocked(
                reader: reader,
                operation: {
                    await TerminalController.shared.controlCommandPaletteRun(
                        target: target,
                        commandID: item.id,
                        arguments: [:],
                        workingDirectory: nil,
                        deadline: nil
                    )
                },
                afterReadStarts: {
                    appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                    appDelegate.registerMainWindowContextForTesting(
                        windowId: windowID,
                        tabManager: tabManager,
                        cmuxConfigStore: configStore,
                        commandPaletteControlHandler: { request in
                            currentHandlerOperations.append(
                                Self.completeProductionStyleRequest(request, item: item)
                            )
                        }
                    )
                }
            )

            #expect(resolution == .targetUnavailable)
            #expect(detachedHandlerOperations.isEmpty)
            #expect(currentHandlerOperations.isEmpty)
        }
    }

    @Test func staleSelectorsDoNotFallBackToTheCallerWindow() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
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
                let inlineOpen = await TerminalController.shared.controlInlineVSCodeOpen(
                    routing: selector,
                    directoryPath: FileManager.default.temporaryDirectory.path,
                    deadline: nil
                )
                #expect(inlineOpen.resolution == .workspaceNotFound)
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
                let inlineOpen = await TerminalController.shared.controlInlineVSCodeOpen(
                    routing: selector,
                    directoryPath: FileManager.default.temporaryDirectory.path,
                    deadline: nil
                )
                #expect(inlineOpen.resolution == .workspaceNotFound)
            }
            #expect(handlerCalls == 0)
        }
    }

    @Test func crossWindowSelectorsDoNotRouteThroughAnExplicitWindow() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let managerA = TabManager(autoWelcomeIfNeeded: false)
            let managerB = TabManager(autoWelcomeIfNeeded: false)
            let workspaceB = try #require(managerB.tabs.first)
            let groupB = try #require(
                managerB.createWorkspaceGroup(
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
                let inlineOpen = await TerminalController.shared.controlInlineVSCodeOpen(
                    routing: selector,
                    directoryPath: FileManager.default.temporaryDirectory.path,
                    deadline: nil
                )
                #expect(inlineOpen.resolution == .workspaceNotFound)
            }
            #expect(handlerCallsA == 0)
            #expect(handlerCallsB == 0)
        }
    }

    @Test func validSelectorsAndNoSelectorRetainTheirWindowRouting() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let managerA = TabManager(autoWelcomeIfNeeded: false)
            let managerB = TabManager(autoWelcomeIfNeeded: false)
            let workspaceB = try #require(managerB.tabs.first)
            let groupB = try #require(
                managerB.createWorkspaceGroup(
                    name: "Group B",
                    childWorkspaceIds: [workspaceB.id]
                ))
            let surfaceB = try #require(workspaceB.panels.keys.first)
            let paneB = try #require(workspaceB.bonsplitController.allPaneIds.first).id
            let windowA = appDelegate.registerMainWindowContextForTesting(
                tabManager: managerA,
                commandPaletteControlHandler: { request in
                    request.complete(
                        .listed(
                            target: Self.versionedTarget(request.target),
                            commands: []
                        ))
                }
            )
            let windowB = appDelegate.registerMainWindowContextForTesting(
                tabManager: managerB,
                commandPaletteControlHandler: { request in
                    request.complete(
                        .listed(
                            target: Self.versionedTarget(request.target),
                            commands: []
                        ))
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
    }

    @Test func workspaceSelectorReachesTheHandlerWithoutChangingSelection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let selectedWorkspace = try #require(tabManager.tabs.first)
            let targetWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
            var receivedTarget: CommandPaletteActionTarget?
            let configSnapshotID = UUID()
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: tabManager,
                commandPaletteControlHandler: { request in
                    receivedTarget = request.target
                    request.complete(
                        .listed(
                            target: Self.versionedTarget(
                                request.target,
                                configSnapshotID: configSnapshotID
                            ),
                            commands: []
                        ))
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

            #expect(
                resolution
                    == .listed(
                        target: ControlCommandPaletteTarget(
                            windowID: windowID,
                            workspaceID: targetWorkspace.id,
                            panelID: targetWorkspace.focusedPanelId,
                            configSnapshotID: configSnapshotID
                        ),
                        commands: []
                    ))
            #expect(
                receivedTarget
                    == CommandPaletteActionTarget(
                        windowID: windowID,
                        workspaceID: targetWorkspace.id,
                        panelID: targetWorkspace.focusedPanelId
                    ))
            #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        }
    }

    @Test func listedIdentityCanBeEchoedAfterFocusChangesWithoutRetargetingRun() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
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
            var receivedOperations: [RecordedCommandPaletteOperation] = []
            let configSnapshotID = UUID()
            let windowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: tabManager,
                commandPaletteControlHandler: { request in
                    switch request.operation {
                    case .list:
                        let listedTarget = CommandPaletteActionTarget(
                            windowID: request.target.windowID,
                            workspaceID: request.target.workspaceID,
                            panelID: request.target.panelID,
                            configSnapshotID: configSnapshotID
                        )
                        receivedTargets.append(listedTarget)
                        receivedOperations.append(.list)
                        request.complete(.listed(target: listedTarget, commands: [item]))
                    case .run(let commandID, let arguments, let workingDirectory):
                        receivedTargets.append(request.target)
                        receivedOperations.append(
                            .run(
                                commandID: commandID,
                                arguments: arguments,
                                workingDirectory: workingDirectory
                            ))
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
            #expect(
                listedTarget
                    == ControlCommandPaletteTarget(
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
            #expect(receivedTargets == [expectedTarget, expectedTarget, expectedTarget])
            #expect(
                receivedOperations == [
                    .list,
                    .list,
                    .run(commandID: item.id, arguments: [:], workingDirectory: nil),
                ])
            #expect(tabManager.selectedWorkspace?.id == laterWorkspace.id)
        }
    }

    @Test func echoedIdentityDistinguishesADeletedPanelFromADeletedWindow() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(tabManager.tabs.first)
            let originalPanelID = try #require(workspace.panels.keys.first)
            _ = try #require(
                workspace.newTerminalSurfaceInFocusedPane(focus: false, initialInput: nil))
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
                panelID: originalPanelID,
                configSnapshotID: UUID()
            )

            #expect(workspace.closePanel(originalPanelID, force: true))
            #expect(
                await TerminalController.shared.controlCommandPaletteRun(
                    target: target,
                    commandID: "palette.fixture",
                    arguments: [:],
                    workingDirectory: nil,
                    deadline: nil
                ) == .targetUnavailable)
            #expect(handlerCalls == 0)

            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            #expect(
                await TerminalController.shared.controlCommandPaletteRun(
                    target: target,
                    commandID: "palette.fixture",
                    arguments: [:],
                    workingDirectory: nil,
                    deadline: nil
                ) == .windowNotFound)
            #expect(handlerCalls == 0)
        }
    }

    @Test func groupSelectorTargetsItsAnchorInsteadOfTheVisibleWorkspace() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let groupedWorkspace = tabManager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let groupID = try #require(
            tabManager.createWorkspaceGroup(
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

    @Test func inlineVSCodePreflightDoesNotCreateFallbackWorkspace() {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        tabManager.tabs = []
        tabManager.selectedTabId = nil

        let resolvedWorkspace = TerminalController.shared.controlInlineVSCodeWorkspace(
            routing: routing(),
            tabManager: tabManager
        )

        #expect(resolvedWorkspace == nil)
        #expect(tabManager.tabs.isEmpty)
        #expect(tabManager.selectedTabId == nil)
    }

    @Test func surfaceAndPaneSelectorsReachTheHandlerAsOneExactTarget() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
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
                    request.complete(
                        .listed(
                            target: Self.versionedTarget(request.target),
                            commands: []
                        ))
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
    }

    @Test func actionContextResolvesAndRevalidatesWithoutMutatingSelection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
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
            AppDelegate.shared = appDelegate
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
    }

    @Test func windowDockWorkspaceRoutingUsesTheOwningWindowSelection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousActiveManager = TerminalController.shared
                .activeTabManagerForCallerNotification()
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
            var callerHandlerOperations: [RecordedCommandPaletteOperation] = []
            var targetHandlerOperations: [RecordedCommandPaletteOperation] = []
            var handledWorkspaceIDs: [UUID?] = []
            let callerWindowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: callerManager,
                commandPaletteControlHandler: { request in
                    callerHandlerOperations.append(
                        Self.completeProductionStyleRequest(request, item: item)
                    )
                }
            )
            let targetWindowID = appDelegate.registerMainWindowContextForTesting(
                tabManager: targetManager,
                commandPaletteControlHandler: { request in
                    let operation = Self.completeProductionStyleRequest(request, item: item)
                    targetHandlerOperations.append(operation)
                    if case .run = operation {
                        handledWorkspaceIDs.append(
                            targetManager.selectedWorkspace?.id ?? targetManager.tabs.first?.id
                        )
                    }
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
            #expect(
                handledWorkspaceIDs == [selectedTargetWorkspace.id, selectedTargetWorkspace.id])
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
            #expect(
                handledWorkspaceIDs == [
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
            #expect(
                handledWorkspaceIDs == [
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
            #expect(callerHandlerOperations.isEmpty)
            let expectedRun = RecordedCommandPaletteOperation.run(
                commandID: item.id,
                arguments: [:],
                workingDirectory: nil
            )
            #expect(
                targetHandlerOperations == [
                    .list, expectedRun,
                    .list, expectedRun,
                    .list, expectedRun,
                    .list, expectedRun,
                ])
        }
    }

    private func runWhileRawReaderIsBlocked<Result: Sendable>(
        reader: CommandPaletteBlockingRawReader,
        operation: @escaping @MainActor () async -> Result,
        afterReadStarts: @escaping @MainActor () throws -> Void
    ) async throws -> Result {
        let operationTask = Task { @MainActor in
            await operation()
        }
        do {
            try #require(
                await reader.waitUntilReadStarted(),
                "Timed out waiting for command-palette configuration discovery"
            )
            try afterReadStarts()
            reader.release()
            let result = await operationTask.value
            operationTask.cancel()
            return result
        } catch {
            reader.release()
            operationTask.cancel()
            _ = await operationTask.value
            throw error
        }
    }

    private static func restoreSocketState(
        _ snapshot: SocketControlServer.ListenerStateSnapshot,
        on controller: TerminalController,
        routingFallbackTabManager: TabManager?
    ) {
        controller.stop()
        controller.setActiveTabManager(nil)

        if snapshot.isRunning {
            controller.startSocketTransport(
                SocketControlServerConfiguration(
                    accessMode: snapshot.accessMode,
                    preferredSocketPath: snapshot.configuredPreferredSocketPath
                        ?? snapshot.socketPath
                ),
                socketPath: snapshot.socketPath,
                routingFallbackTabManager: routingFallbackTabManager
            )
        } else {
            _ = controller.socketServer.reconfigure(accessMode: snapshot.accessMode)
            controller.socketServer.withListenerState { state in
                state.socketPath = snapshot.socketPath
                state.configuredPreferredSocketPath = snapshot.configuredPreferredSocketPath
            }
            if let reservedSocketPath = snapshot.reservedStartupSocketPath {
                _ = controller.reserveStartupSocketPath(reservedSocketPath)
            }
        }

        controller.socketServer.withListenerState { state in
            state.configuredPreferredSocketPath = snapshot.configuredPreferredSocketPath
            if !snapshot.isRunning && snapshot.reservedStartupSocketPath == nil {
                state.socketPath = snapshot.socketPath
            }
        }
        controller.setActiveTabManager(routingFallbackTabManager)
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

    private static func versionedTarget(
        _ target: CommandPaletteActionTarget,
        configSnapshotID: UUID = UUID()
    ) -> CommandPaletteActionTarget {
        CommandPaletteActionTarget(
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            panelID: target.panelID,
            configSnapshotID: configSnapshotID
        )
    }

    private static func completeProductionStyleRequest(
        _ request: CommandPaletteControlRequest,
        item: CommandPaletteControlRequestItem
    ) -> RecordedCommandPaletteOperation {
        switch request.operation {
        case .list:
            request.complete(.listed(target: request.target, commands: [item]))
            return .list
        case .run(let commandID, let arguments, let workingDirectory):
            request.complete(.ran(item, result: .completed))
            return .run(
                commandID: commandID,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        }
    }
}

nonisolated private enum RecordedCommandPaletteOperation: Equatable, Sendable {
    case list
    case run(commandID: String, arguments: [String: String], workingDirectory: String?)
}

private actor CommandPaletteBlockingRawReader: CmuxConfigActionCatalogRawReading {
    private nonisolated let readStartedEvents: AsyncStream<Void>
    private nonisolated let readStartedContinuation: AsyncStream<Void>.Continuation
    private nonisolated let releaseEvents: AsyncStream<Void>
    private nonisolated let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (readStartedEvents, readStartedContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        (releaseEvents, releaseContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    func read(
        request _: CmuxConfigActionCatalogRawReadRequest
    ) async -> CmuxConfigActionCatalogRawReadResponse? {
        readStartedContinuation.yield(())
        var releaseIterator = releaseEvents.makeAsyncIterator()
        guard await releaseIterator.next() != nil, !Task.isCancelled else { return nil }
        return CmuxConfigActionCatalogRawReadResponse(
            localPath: nil,
            local: nil,
            global: CmuxConfigActionCatalogRawFile(status: .missing, data: Data())
        )
    }

    nonisolated func waitUntilReadStarted(
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { [readStartedEvents] in
                var iterator = readStartedEvents.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                do {
                    // This deadline turns a missing production read into a bounded test failure.
                    try await ContinuousClock().sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let didStart = await group.next() ?? false
            group.cancelAll()
            return didStart
        }
    }

    nonisolated func release() {
        releaseContinuation.yield(())
        releaseContinuation.finish()
        readStartedContinuation.finish()
    }
}
