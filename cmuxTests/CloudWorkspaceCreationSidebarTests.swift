import AppKit
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
struct CloudWorkspaceCreationSidebarTests {
    @Test("Both workspace sidebars share the create receipt before daemon refresh", arguments: [false, true])
    func receiptAppearsBeforeRefresh(focus: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let originalIDs = Set(fixture.manager.tabs.map(\.id))
            var pendingID: UUID?
            fixture.provider.beforeRefresh = {
                let created = fixture.manager.tabs.filter { !originalIDs.contains($0.id) }
                #expect(created.count == 1, "The left navigator must contain the new workspace before refresh returns")
                pendingID = created.first?.id
                let row = try #require(fixture.workspaceRows().first)
                if case .workspace(_, _, _, _, let openIn) = row.kind {
                    #expect(openIn != nil, "The Cloud row must navigate to the same pending local workspace")
                    #expect(openIn == pendingID)
                }
                // Completion must not select over navigation performed while connecting.
                fixture.manager.selectedTabId = fixture.originalWorkspaceID
            }
            let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                name: nil, focus: focus
            )
            let opened = try #require(result.opened)
            #expect(opened.workspaceID == pendingID)
            #expect(fixture.manager.tabs.filter { !originalIDs.contains($0.id) }.count == 1)
            #expect(fixture.workspaceRows().count == 1)
            #expect(fixture.catalog.projections.filter { $0.workspaceID == opened.workspaceID }.count == 1)
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.provider.terminalCreates == 0, "A starter receipt must not spawn another terminal")
        }
    }

    @Test("Receipt, older snapshot, and accepted graph retain one native terminal and its first input")
    func snapshotsConvergeWithoutReplacingTheReservation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            var pendingID: UUID?
            var pendingPanel: TerminalPanel?
            var relay: CloudOptimisticInputRelay?
            fixture.provider.beforeMaterialize = { _, reservation in
                let reservation = try #require(reservation)
                let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
                pendingID = workspace.id
                pendingPanel = try #require(workspace.terminalPanel(for: reservation.panelID))
                relay = reservation.inputRelay
                reservation.inputRelay.send(.bytes(Data("echo first command\n".utf8)))
                #expect(workspace.panels.count == 1)
                #expect(workspace.cloudVMBinding?.remoteWorkspaceID == fixture.provider.createdWorkspaces.first?.id)
                #expect(fixture.provider.refreshes == 0, "Current daemons must not refresh before publishing the receipt")
                try fixture.provider.publish(revision: 9, includesWorkspaces: false)
                await fixture.catalog.cloudWorkspaceProjectionCoordinator.waitForIdle()
                #expect(fixture.workspaceRows().count == 1)
                #expect(workspace.cloudVMBinding != nil, "A pre-receipt snapshot cannot clear the new binding")
                #expect(workspace.panels.count == 1)
                try fixture.provider.publish(revision: 10)
                await fixture.catalog.cloudWorkspaceProjectionCoordinator.waitForIdle()
                #expect(workspace.panels.count == 1, "An early event must not materialize a competing pane")
                fixture.manager.selectedTabId = fixture.originalWorkspaceID
            }
            let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                name: nil, focus: true
            )
            let opened = try #require(result.opened)
            let workspace = try #require(fixture.manager.workspacesById[opened.workspaceID])
            #expect(opened.workspaceID == pendingID)
            #expect(workspace.terminalPanel(for: opened.projections[0].panelID) === pendingPanel)
            #expect(relay?.pendingCount == 1, "Adoption must preserve the existing input relay")
            for revision in [10, 11, 12] {
                try fixture.provider.publish(revision: revision)
                await fixture.catalog.cloudWorkspaceProjectionCoordinator.waitForIdle()
                #expect(fixture.workspaceRows().count == 1)
                #expect(fixture.catalog.projections.count == 1)
                #expect(workspace.panels.count == 1)
                #expect(workspace.terminalPanel(for: opened.projections[0].panelID) === pendingPanel)
            }
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.provider.adoptedPanels == [opened.projections[0].panelID])
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
        }
    }

    @Test("Failed attachment or starter creation retries the same workspace and pending pane", arguments: [false, true], [false, true])
    func failedCreateRetainsItsReceiptForRetry(terminalFailure: Bool, retryFromAction: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            fixture.provider.includesStarter = !terminalFailure
            if terminalFailure { fixture.provider.terminalError = CloudDiagnosticFailure.conflict }
            else { fixture.provider.beforeMaterialize = { _, _ in throw CloudDiagnosticFailure.conflict } }
            fixture.provider.beforeRefresh = {
                #expect(fixture.manager.tabs.count == 2)
                #expect(fixture.workspaceRows().count == 1, "An empty receipt must remain navigable while its starter is pending")
            }
            await #expect(throws: CloudDiagnosticFailure.conflict) {
                try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                    name: nil, focus: false, reuseFailedCreation: retryFromAction
                )
            }
            let pending = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.operations.values.first)
            let reservation = try #require(pending.reservation)
            let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
            #expect(workspace.cloudMaterializationFailures[reservation.panelID] != nil)
            #expect(fixture.manager.tabs.count == 2 && fixture.workspaceRows().count == 1)
            #expect(fixture.catalog.projections.isEmpty)
            reservation.inputRelay.send(.bytes(Data("echo retry\n".utf8)))
            fixture.provider.terminalError = nil
            fixture.provider.beforeMaterialize = nil
            if retryFromAction {
                let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                    name: nil, focus: false, reuseFailedCreation: true
                )
                #expect(result.opened?.workspaceID == reservation.workspaceID)
                #expect(result.opened?.projections.first?.panelID == reservation.panelID)
            } else {
                reservation.retry?()
                let retry = try #require(pending.retryTask)
                await retry.value
                #expect(fixture.catalog.projection(forPanel: reservation.panelID)?.workspaceID == reservation.workspaceID)
            }
            #expect(fixture.provider.createdWorkspaces.count == 1)
            #expect(Set(fixture.provider.terminalRequests).count == (terminalFailure ? 1 : 0))
            #expect(reservation.inputRelay.pendingCount == 1)
            #expect(workspace.cloudMaterializationFailures[reservation.panelID] == nil)
            try fixture.provider.publish(revision: 10)
            await fixture.catalog.cloudWorkspaceProjectionCoordinator.waitForIdle()
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.catalog.projections.count == 1)
        }
    }

    @Test("Invalidated creates cannot resurrect a workspace from a late provider callback",
          arguments: ["cancel", "account", "provider", "close", "daemon", "tab", "cursorless", "generation"])
    func staleCompletionCannotRestoreEitherProjection(reason: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            fixture.provider.beforeMaterialize = { _, reservation in
                let reservation = try #require(reservation)
                switch reason {
                case "cancel": withUnsafeCurrentTask { $0?.cancel() }
                case "account":
                    fixture.catalog.cloudWorkspaceCreationCoordinator.cancelAll()
                    NotificationCenter.default.post(name: .cmuxCloudVMAccessDidEnd, object: nil)
                case "provider": fixture.catalog.register(CloudPlacementTestProvider(machine: fixture.provider.machine))
                case "close":
                    let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
                    fixture.manager.closeWorkspace(workspace, recordHistory: false)
                case "daemon": try fixture.provider.publish(revision: 10, includesWorkspaces: false)
                case "tab": try fixture.provider.publish(revision: 10, includesTabs: false)
                case "cursorless": try fixture.provider.publish(revision: 10, hasCursor: false)
                default: try fixture.provider.publish(revision: 1, includesWorkspaces: false, generation: "restarted")
                }
                // Deliberately return success even after invalidation, modelling an
                // uncooperative provider callback. The request fence owns admission.
            }
            let creation = Task { @MainActor in
                try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                    name: nil, focus: false
                )
            }
            await #expect(throws: CancellationError.self) { try await creation.value }
            #expect(fixture.manager.tabs.map(\.id) == [fixture.originalWorkspaceID])
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.catalog.projections.isEmpty)
            #expect(fixture.catalog.cloudWorkspaceCreationCoordinator.operations.isEmpty)
        }
    }

    @Test("Overlapping creates finish out of order without sharing native or remote identities")
    func overlappingCreatesStayIndependent() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            let starts = AsyncStream<UUID>.makeStream()
            let gates = [CloudLinkFirstValue<Bool>(), CloudLinkFirstValue<Bool>()]
            fixture.provider.beforeMaterialize = { resource, reservation in
                let reservation = try #require(reservation)
                starts.continuation.yield(reservation.workspaceID)
                let index = try #require(resource.remoteWorkspace?.index)
                _ = await gates[index].result
            }
            let first = Task { @MainActor in
                try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                    name: nil, focus: false
                )
            }
            var events = starts.stream.makeAsyncIterator()
            let firstID = try #require(await events.next())
            let second = Task { @MainActor in
                try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                    name: nil, focus: false
                )
            }
            let secondID = try #require(await events.next())
            #expect(firstID != secondID)
            #expect(fixture.manager.tabs.count == 3)
            #expect(fixture.workspaceRows().count == 2)
            gates[1].resolve(true)
            let secondResult = try await second.value
            gates[0].resolve(true)
            let firstResult = try await first.value
            #expect(firstResult.opened?.workspaceID == firstID)
            #expect(secondResult.opened?.workspaceID == secondID)
            try fixture.provider.publish(revision: 10)
            await fixture.catalog.cloudWorkspaceProjectionCoordinator.waitForIdle()
            #expect(fixture.catalog.projections.count == 2)
            #expect(fixture.workspaceRows().count == 2)
            #expect(fixture.manager.tabs.count == 3)
            #expect(fixture.catalog.snapshot.pendingWorkspaceCreations == nil)
            #expect(fixture.provider.terminalCreates == 0)
        }
    }


    @Test("A delayed access-end notification cannot retire work admitted after synchronous teardown")
    func delayedAccountNotificationCannotCancelNewWork() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.catalog.cloudWorkspaceCreationCoordinator.cancelAll()
            fixture.provider.usesReceipt = true
            fixture.provider.beforeMaterialize = { _, reservation in
                let reservation = try #require(reservation)
                NotificationCenter.default.post(name: .cmuxCloudVMAccessDidEnd, object: nil)
                #expect(fixture.manager.workspacesById[reservation.workspaceID] != nil)
                #expect(fixture.catalog.cloudWorkspaceCreationCoordinator.operations.count == 1)
            }
            let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                name: nil, focus: false
            )
            #expect(result.opened != nil)
            #expect(fixture.manager.tabs.count == 2)
        }
    }

    @Test("The Cloud action uses its injected window even when the app-global manager points elsewhere")
    func creationStaysInTheInitiatingWindow() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let other = TabManager(autoWelcomeIfNeeded: false)
            defer { other.tabs.forEach { $0.teardownAllPanels() } }
            fixture.app.tabManager = other
            fixture.provider.usesReceipt = true
            let completed = CloudLinkFirstValue<Bool>()
            let actions = CloudTreeNodeActions.bound(
                catalog: { fixture.catalog }, selectedWorkspaceID: { fixture.manager.selectedTabId },
                selectLocalWorkspace: { fixture.manager.selectedTabId = $0 },
                onWillMutate: { _ in }, onDidMutate: { completed.resolve(true) },
                onFailure: { Issue.record("Unexpected create failure: \($0)") }, refresh: {}
            )
            actions.newWorkspace(fixture.provider.machine)
            #expect(await completed.result == true)
            #expect(fixture.manager.tabs.count == 2)
            #expect(other.tabs.count == 1)
            #expect(fixture.catalog.projections.allSatisfy { fixture.manager.workspacesById[$0.workspaceID] != nil })
        }
    }

}
