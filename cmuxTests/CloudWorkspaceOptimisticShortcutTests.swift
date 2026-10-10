import AppKit
import CmuxCloud
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs Cmd-Y's action through the production composition with delayed providers.
@MainActor
@Suite(.serialized, .exclusiveAppContext)
struct CloudWorkspaceOptimisticShortcutTests {
    private func pendingWorkspace(manager: TabManager, machine: SurfaceMachineID) -> Workspace? {
        manager.tabs.first { $0.cloudVMBinding?.vmID == machine.rawValue }
    }

    @Test("Cmd-Y paints the predicted daemon workspace name during admission")
    func optimisticWorkspaceName() async throws {
        let fixture = try CloudWorkspaceCreationSidebarFixture(useSharedCatalog: true)
        defer { fixture.close() }
        let existing = SurfaceRemoteWorkspace(id: "existing", name: "workspace-1", index: 0, focused: false)
        fixture.provider.info.remoteWorkspaces = [existing]
        fixture.catalog.updateMachine(fixture.provider.info, from: fixture.provider)
        let suite = "optimistic-cloud-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        fixture.provider.beforeCreate = {
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }
        fixture.app.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { true })
        fixture.app.cloudWorkspaceCoordinator = cmuxApp.makeCloudWorkspaceCoordinator(
            machinePinStore: CloudMachinePinStore(defaults: defaults, scopeProvider: { "scope" }),
            allowsOperation: { true }, loadMachines: { [fixture.provider.machine.rawValue] },
            tabManager: { $0 == fixture.windowID ? fixture.manager : nil },
            provider: { _ in fixture.provider }, catalog: fixture.catalog
        )
        defer {
            release.continuation.finish()
            fixture.app.cloudWorkspaceOperationController?.cancelAll()
            fixture.app.cloudWorkspaceCoordinator = nil
        }
        #expect(fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: fixture.manager))
        for await _ in entered.stream { break }
        let pending = try #require(fixture.manager.tabs.first { $0.cloudPendingCreations.isEmpty == false })
        #expect(pending.title == "workspace-2")
        release.continuation.yield(())
        await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()
    }

    @Test("Cmd-Y selects its reservation before remote creation and preserves newer navigation",
          arguments: ["stay", "beforeResolution", "beforeProvider", "providerDelay", "awayAndBack", "afterAdmission", "background"])
    func optimisticSelection(navigation: String) async throws {
        let fixture = try CloudWorkspaceCreationSidebarFixture(useSharedCatalog: true)
        defer { fixture.close() }
        let manager = fixture.manager
        let original = try #require(manager.selectedWorkspace)
        let other = try #require(manager.addWorkspaceIfActive(initialSurface: .cloudVMLoading, select: false))
        let keyWindow = KeyStatusTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let context = try #require(fixture.app.mainWindowContexts.values.first { $0.windowId == fixture.windowID })
        if navigation != "background" {
            manager.window = keyWindow
            context.window = keyWindow
        }
        defer { manager.window = fixture.window; context.window = fixture.window; withExtendedLifetime(keyWindow) {} }
        let suite = "optimistic-cloud-shortcut-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = CloudMachinePinStore(defaults: defaults, scopeProvider: { "scope" })
        let providerEntered = AsyncStream<Void>.makeStream()
        let providerRelease = AsyncStream<Void>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let operations = CloudWorkspaceOperationController(isAvailable: { true })
        fixture.app.cloudWorkspaceOperationController = operations
        defer { fixture.app.cloudWorkspaceCoordinator = nil; operations.cancelAll() }
        fixture.app.cloudWorkspaceCoordinator = cmuxApp.makeCloudWorkspaceCoordinator(
            machinePinStore: pins, allowsOperation: { true },
            loadMachines: {
                if navigation == "beforeResolution" || navigation == "awayAndBack" {
                    manager.selectWorkspace(other)
                    if navigation == "awayAndBack" { manager.selectWorkspace(original) }
                }
                return [fixture.provider.machine.rawValue]
            },
            tabManager: { $0 == fixture.windowID ? manager : nil },
            provider: { id in
                #expect(id == fixture.provider.machine.rawValue)
                if navigation == "providerDelay" {
                    providerEntered.continuation.yield(())
                    for await _ in providerRelease.stream { break }
                }
                if navigation == "beforeProvider" { manager.selectWorkspace(other) }
                return fixture.provider
            },
            catalog: fixture.catalog
        )
        fixture.provider.usesReceipt = true
        defer { providerRelease.continuation.finish(); release.continuation.finish() }
        fixture.provider.beforeCreate = {
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }

        #expect(fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: manager))
        if navigation == "providerDelay" {
            for await _ in providerEntered.stream { break }
        } else {
            for await _ in entered.stream { break }
        }
        let pending = try #require(manager.tabs.first {
            $0.cloudVMBinding?.vmID == fixture.provider.machine.rawValue
                && !$0.cloudPendingCreations.isEmpty
        })
        let reservation = try #require(pending.cloudPendingCreations.values.first)
        let shouldSelect = navigation == "stay" || navigation == "afterAdmission"
        let previous = navigation == "beforeResolution" || navigation == "beforeProvider" ? other.id : original.id
        #expect(fixture.provider.createdWorkspaces.isEmpty, "The remote response is still held open")
        #expect(manager.selectedTabId == (shouldSelect ? pending.id : previous))
        #expect(pending.cloudVMBinding?.vmID == fixture.provider.machine.rawValue)
        #expect(pending.cloudVMBinding?.remoteWorkspaceID == nil)
        #expect(pending.cloudPendingCreations[reservation.panelID] === reservation)
        if navigation == "afterAdmission" { manager.selectWorkspace(other) }
        if navigation == "providerDelay" { providerRelease.continuation.yield(()) }
        for await _ in entered.stream { break }
        release.continuation.yield(())
        await operations.waitForPendingOperations()

        let remote = try #require(fixture.provider.createdWorkspaces.first)
        #expect(pending.cloudVMBinding?.remoteWorkspaceID == remote.id)
        #expect(fixture.provider.createdWorkspaces.count == 1)
        #expect(fixture.provider.adoptedPanels == [reservation.panelID])
        #expect(manager.tabs.count == 3, "Reconciliation adopts the same workspace")
        #expect(manager.selectedTabId == (navigation == "afterAdmission" ? other.id : shouldSelect ? pending.id : previous))
        let reveal = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.reveals.reveal(for: manager))
        #expect(reveal.isWithdrawn == (navigation != "stay"))
    }

    @Test("An optimistic Cmd-Y failure retains a retry pane; cancellation removes its reservation",
          arguments: ["failure", "retry", "cancel", "cancelAfterNavigation"])
    func unsuccessfulCreation(outcome: String) async throws {
        let fixture = try CloudWorkspaceCreationSidebarFixture(useSharedCatalog: true)
        defer { fixture.close() }
        let manager = fixture.manager
        let original = try #require(manager.selectedWorkspace)
        let other = try #require(manager.addWorkspaceIfActive(initialSurface: .cloudVMLoading, select: false))
        let keyWindow = KeyStatusTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let context = try #require(fixture.app.mainWindowContexts.values.first { $0.windowId == fixture.windowID })
        manager.window = keyWindow
        context.window = keyWindow
        defer { manager.window = fixture.window; context.window = fixture.window; withExtendedLifetime(keyWindow) {} }
        let suite = "optimistic-cloud-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let operations = CloudWorkspaceOperationController(isAvailable: { true })
        fixture.app.cloudWorkspaceOperationController = operations
        defer { fixture.app.cloudWorkspaceCoordinator = nil; operations.cancelAll() }
        fixture.app.cloudWorkspaceCoordinator = cmuxApp.makeCloudWorkspaceCoordinator(
            machinePinStore: CloudMachinePinStore(defaults: defaults, scopeProvider: { "scope" }),
            allowsOperation: { true }, loadMachines: { [fixture.provider.machine.rawValue] },
            tabManager: { $0 == fixture.windowID ? manager : nil }, provider: { _ in fixture.provider },
            catalog: fixture.catalog
        )
        let entered = AsyncStream<Void>.makeStream()
        let retryEntered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var attempts = 0
        defer { release.continuation.finish() }
        fixture.provider.beforeCreate = {
            attempts += 1
            if attempts == 1 {
                entered.continuation.yield(())
                for await _ in release.stream { break }
                if outcome == "failure" || outcome == "retry" { throw CloudDiagnosticFailure.conflict }
                throw CancellationError()
            }
            retryEntered.continuation.yield(())
        }
        #expect(fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: manager))
        for await _ in entered.stream { break }
        let operation = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.operations.values.first)
        let reservation = try #require(operation.reservation)
        #expect(manager.selectedTabId == reservation.workspaceID)
        if outcome == "cancelAfterNavigation" { manager.selectWorkspace(other) }
        release.continuation.yield(())
        await operations.waitForPendingOperations()

        #expect(fixture.provider.createdWorkspaces.isEmpty)
        let reveal = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.reveals.reveal(for: manager))
        #expect(reveal.isWithdrawn)
        if outcome == "failure" {
            #expect(manager.selectedTabId == reservation.workspaceID)
            #expect(operation.failure != nil)
            #expect(reservation.retry != nil, "The failed pane exposes the shared reconnect action")
        } else if outcome == "retry" {
            let retry = try #require(reservation.retry)
            retry()
            for await _ in retryEntered.stream { break }
            if let retryTask = operation.retryTask { await retryTask.value }
            #expect(operation.wasPreAdmitted == false)
            #expect(operation.isComplete)
            #expect(operation.failure == nil)
            #expect(reservation.retry == nil)
            #expect(pendingWorkspace(manager: manager, machine: fixture.provider.machine)?.cloudVMBinding?.remoteWorkspaceID != nil)
        } else {
            #expect(manager.workspacesById[reservation.workspaceID] == nil)
            #expect(manager.selectedTabId == (outcome == "cancelAfterNavigation" ? other.id : original.id))
            #expect(fixture.catalog.cloudWorkspaceCreationCoordinator.operations.isEmpty)
        }
    }
}
