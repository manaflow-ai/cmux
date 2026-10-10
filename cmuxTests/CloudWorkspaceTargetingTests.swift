import AppKit
import CmuxCloud
import CmuxCloudMachines
import CmuxSettings
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

    /// #16189: the sidebar offers New Workspace only while an unlocked machine
    /// exists, so the Cmd-N resolver behind it must never land on a locked one,
    /// even when the locked machine is first in the fleet or was used last.
    @Test("A locked machine is never a New Workspace target, first or remembered")
    func lockedMachinesAreNotTargets() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        func vm(_ id: String, createdAt: Int64 = 0, expiresAt: Int64? = nil) -> VMSummary {
            VMSummary(id: id, provider: "test", status: "running", image: "test", createdAt: createdAt, freeAccessExpiresAt: expiresAt)
        }
        let page = VMListPage(
            vms: [
                vm("expired-by-server", expiresAt: nowMs - 1),
                // No server expiry: the plan's 7-day window decides, as it does for the row.
                vm("expired-by-window", createdAt: nowMs - 8 * 86_400_000),
                vm("deleting"),
                vm("open-window", createdAt: nowMs - 86_400_000),
                vm("paid", expiresAt: nowMs + 86_400_000)
            ],
            limits: VMPlanLimits(planId: "free", freeAccessWindowDays: 7)
        )
        let targets = cmuxApp.cloudWorkspaceTargetMachineIDs(page: page, deleting: ["deleting"], now: now)
        #expect(targets == ["open-window", "paid"])

        let resolver = CloudWorkspaceTargetResolver()
        #expect(resolver.resolve(lastSelection: nil, currentScopeID: "scope", sidebarMachineIDs: targets) == "open-window")
        let rememberedLocked = CloudWorkspaceSelection(workspaceID: UUID(), scopeID: "scope", machineID: "expired-by-server")
        #expect(resolver.resolve(lastSelection: rememberedLocked, currentScopeID: "scope", sidebarMachineIDs: targets) == "open-window")

        let allLocked = VMListPage(vms: [vm("expired-by-server", expiresAt: nowMs - 1)], limits: nil)
        #expect(cmuxApp.cloudWorkspaceTargetMachineIDs(page: allLocked, deleting: [], now: now).isEmpty)
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
        let created = try host.create("Cloud workspace", false)
        #expect(owner.workspacesById[created.workspaceID] != nil)
        #expect(owner.selectedTabId == original)
        #expect(other.tabs.map(\.id) == otherIDs)
        owner.finalizeAllWorkspacesForWindowClose()
        #expect(throws: CancellationError.self) { try host.create("Late workspace", false) }
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

    @Test("Clicking a Cloud row immediately replaces the previous shortcut context")
    func clickedCloudRowWinsBeforeProjection() throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let local = try #require(fixture.manager.selectedWorkspace)
        fixture.manager.recordCloudWorkspaceSelection(machineID: .cloud("first"))
        fixture.manager.selectWorkspace(local)
        fixture.manager.recordCloudWorkspaceSelection(machineID: .cloud("second"))
        fixture.manager.selectWorkspace(local)
        #expect(fixture.manager.rememberedCloudWorkspaceSelection?.machineID == "second")
        #expect(fixture.manager.rememberedCloudWorkspaceSelection?.workspaceID == nil)
    }

    @Test("A later materialized Cloud selection replaces an older provisional click")
    func materializedCloudSelectionReplacesProvisionalClick() throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let local = try #require(fixture.manager.selectedWorkspace)
        fixture.manager.recordCloudWorkspaceSelection(machineID: .cloud("pending"))
        let materialized = try fixture.workspace(machineID: "materialized")
        fixture.manager.selectWorkspace(materialized)
        fixture.manager.selectWorkspace(local)
        #expect(fixture.manager.rememberedCloudWorkspaceSelection?.machineID == "materialized")
        #expect(fixture.manager.rememberedCloudWorkspaceSelection?.workspaceID == materialized.id)
    }

    @Test("Cmd-Y preserves a clicked Cloud machine while its row is still opening")
    func shortcutUsesClickedMachineBeforeProjection() async throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let local = try #require(fixture.manager.selectedWorkspace)
        let first = try fixture.workspace(machineID: "a")
        fixture.manager.selectWorkspace(first)
        fixture.manager.selectWorkspace(local)
        fixture.manager.recordCloudWorkspaceSelection(machineID: .cloud("b"))
        #expect(fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: fixture.manager))
        await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(fixture.requests.map(\.machineID) == ["b"])
    }

    @Test("Command-Y dispatches the configured action to the last selected Cloud machine")
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
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
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
        // The creation-completion focus rule only applies while the window that
        // started the creation is key. The app-host test process runs headless
        // and is usually not the active app, so `makeKeyAndOrderFront` does not
        // make a programmatic window key; pin key status the way the other
        // focus suites do so this exercises the rule instead of the host.
        let window = KeyStatusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(fixture.windowID.uuidString)")
        fixture.app.mainWindowContexts.values.first { $0.windowId == fixture.windowID }?.window = window
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        // Assert the app's own answer for "which window may a finished creation
        // navigate", which is the precondition the selection expectation below
        // depends on.
        #expect(fixture.app.cloudWorkspaceCreationFocusWindow(windowID: fixture.windowID) === window)
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
        let defaults = UserDefaults.standard
        let cloudEnabledKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
        let previousCloudEnabled = defaults.object(forKey: cloudEnabledKey)
        defaults.set(true, forKey: cloudEnabledKey)
        defer {
            if let previousCloudEnabled {
                defaults.set(previousCloudEnabled, forKey: cloudEnabledKey)
            } else {
                defaults.removeObject(forKey: cloudEnabledKey)
            }
        }
        fixture.available = false
        let ids = fixture.manager.tabs.map(\.id)
        #expect(!fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: fixture.manager))
        #expect(fixture.requests.isEmpty)
        #expect(fixture.manager.tabs.map(\.id) == ids)
    }

}
