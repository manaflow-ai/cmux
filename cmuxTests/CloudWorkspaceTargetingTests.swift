import AppKit
import CmuxCloudMachines
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud workspace targeting", .serialized)
struct CloudWorkspaceTargetingTests {
    @Test("The shared UI action follows A → local and B → local, independent of the legacy default")
    func selectionFlow() async throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        let local = try #require(manager.selectedWorkspace)
        let a = try fixture.workspace(machineID: "a")
        let b = try fixture.workspace(machineID: "b")
        fixture.defaults.set("a", forKey: "cloud.defaultMachineID")
        fixture.pins.reconcile(machineIDs: ["b", "a"])
        manager.selectWorkspace(a)
        manager.selectWorkspace(local)
        #expect(fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: manager))
        await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
        manager.selectWorkspace(b)
        manager.selectWorkspace(local)
        let context = try #require(fixture.app.mainWindowContexts.values.first { $0.windowId == fixture.windowID })
        #expect(fixture.app.executeConfiguredCmuxAction(.builtIn(.newCloudWorkspace), context: context))
        await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(fixture.requests.map(\.machineID) == ["a", "b"])
        #expect(fixture.requests.allSatisfy { $0.windowID == fixture.windowID })
        #expect(manager.selectedTabId == local.id)
    }

    @Test("Deleting the remembered workspace invalidates it while another window keeps its own memory")
    func deletedWorkspaceAndWindowIsolation() throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let first = try fixture.workspace(machineID: "a")
        fixture.manager.selectWorkspace(first)
        let second = TabManager(cloudWorkspaceSelection: fixture.coordinator.makeSelectionState())
        defer { second.finalizeAllWorkspacesForWindowClose() }
        let other = try #require(second.selectedWorkspace)
        other.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "b", isBase: false)
        second.recordCloudWorkspaceSelection()
        #expect(fixture.manager.rememberedCloudWorkspaceSelection?.machineID == "a")
        #expect(second.rememberedCloudWorkspaceSelection?.machineID == "b")
        fixture.manager.closeWorkspace(first, recordHistory: false)
        #expect(fixture.manager.rememberedCloudWorkspaceSelection == nil)
        #expect(second.rememberedCloudWorkspaceSelection?.machineID == "b")
    }

    @Test("Pinning and native machine reordering produce the shortcut's exact fallback order")
    func sidebarOrder() async throws {
        let fixture = CloudMachineOrderingFixture(ids: ["b", "a"])
        defer { fixture.close() }
        var targets: [String] = []
        let coordinator = CloudWorkspaceCoordinator(
            machinePinStore: fixture.store, allowsOperation: { true }, loadMachines: { ["a", "b"] },
            createWorkspace: { targets.append($0.machineID); return UUID() }
        )
        let windowID = UUID()
        _ = try await coordinator.createOnResolvedMachine(selection: nil, windowID: windowID, scopeID: "user:a|team:one")
        fixture.model.setMachinePinned(true, id: "a")
        fixture.render()
        #expect(fixture.order.first == "a")
        _ = try await coordinator.createOnResolvedMachine(selection: nil, windowID: windowID, scopeID: "user:a|team:one")
        fixture.model.setMachinePinned(true, id: "b")
        fixture.render()
        let actions = try #require(fixture.coordinator.machineActions.ordering)
        #expect(fixture.coordinator.moveMachine("b", move: .top, using: actions))
        #expect(fixture.order.first == "b")
        _ = try await coordinator.createOnResolvedMachine(selection: nil, windowID: windowID, scopeID: "user:a|team:one")
        #expect(targets == ["b", "a", "b"])
    }

    @Test("A captured projection host creates in its original window without changing selection")
    func projectionOwnership() throws {
        let owner = TabManager()
        let other = TabManager()
        defer { owner.finalizeAllWorkspacesForWindowClose(); other.finalizeAllWorkspacesForWindowClose() }
        let original = owner.selectedTabId
        let otherIDs = other.tabs.map(\.id)
        let host = SurfaceCatalog.NewWorkspaceHost(tabManager: owner)
        let created = try host.create("Cloud workspace")
        #expect(owner.workspacesById[created.workspaceID] != nil)
        #expect(owner.selectedTabId == original)
        #expect(other.tabs.map(\.id) == otherIDs)
        owner.finalizeAllWorkspacesForWindowClose()
        #expect(throws: CancellationError.self) { try host.create("Late workspace") }
    }

    @Test("A Cloud binding arriving after initial selection is remembered when switching to local")
    func lateBinding() throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let selected = try #require(fixture.manager.selectedWorkspace)
        selected.cloudVMBinding = WorkspaceCloudVMBinding(vmID: "a", isBase: false)
        let local = try #require(fixture.manager.addWorkspaceIfActive(select: false))
        fixture.manager.selectWorkspace(local)
        #expect(fixture.manager.rememberedCloudWorkspaceSelection?.machineID == "a")
    }

    @Test("Shift-Command-Y dispatches the configured action to the last selected Cloud machine")
    func actualShortcut() async throws {
#if DEBUG
        let previousStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "cloud-workspace-target")
        defer { KeyboardShortcutSettings.settingsFileStore = previousStore }
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        let local = try #require(manager.selectedWorkspace)
        let a = try fixture.workspace(machineID: "a")
        manager.selectWorkspace(a)
        manager.selectWorkspace(local)
        fixture.pins.reconcile(machineIDs: ["b", "a"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(fixture.windowID.uuidString)")
        fixture.app.mainWindowContexts.values.first { $0.windowId == fixture.windowID }?.window = window
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        KeyboardShortcutSettings.resetShortcut(for: .newCloudWorkspace)
        fixture.app.debugResetShortcutRoutingStateForTesting()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "Y",
            charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16
        ))
        #expect(fixture.app.debugHandleCustomShortcut(event: event))
        await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(fixture.requests.map(\.machineID) == ["a"])
        #expect(manager.tabs.count == 2)
#endif
    }

    @Test("A late creation preserves newer workspace navigation", arguments: [false, true])
    func completionFocus(navigate: Bool) async throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        let local = try #require(manager.selectedWorkspace)
        let other = try #require(manager.addWorkspaceIfActive(initialSurface: .cloudVMLoading, select: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(fixture.windowID.uuidString)")
        fixture.app.mainWindowContexts.values.first { $0.windowId == fixture.windowID }?.window = window
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        #expect(NSApp.keyWindow === window)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var createdID: UUID?
        fixture.onCreate = { _ in
            entered.continuation.yield(())
            for await _ in release.stream { break }
            let created = manager.addWorkspaceIfActive(initialSurface: .cloudVMLoading, select: false)
            createdID = created?.id
            return created?.id
        }
        #expect(fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: manager))
        for await _ in entered.stream { break }
        if navigate { manager.selectWorkspace(other) }
        release.continuation.yield(())
        await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
        let created = try #require(createdID)
        #expect(manager.selectedTabId == (navigate ? other.id : created))
        #expect(manager.workspacesById[local.id] != nil)
    }

    @Test("Unavailable Cloud access is consumed without creating a local workspace")
    func unavailableAction() {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        fixture.available = false
        let ids = fixture.manager.tabs.map(\.id)
        #expect(!fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: fixture.manager))
        #expect(fixture.requests.isEmpty)
        #expect(fixture.manager.tabs.map(\.id) == ids)
    }

}
