import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileWorkspaceListFocusEventTests {
    @Test func workspaceScopedFocusDoesNotSampleUnrelatedObserver() async throws {
        let notificationCenter = NotificationCenter()
        let targetManager = TabManager(autoWelcomeIfNeeded: false)
        let unrelatedManager = TabManager(autoWelcomeIfNeeded: false)
        let targetWorkspaceID = try #require(targetManager.selectedWorkspace?.id)
        let targetManagerID = ObjectIdentifier(targetManager)
        let unrelatedManagerID = ObjectIdentifier(unrelatedManager)
        var sampleCounts: [ObjectIdentifier: Int] = [:]
        let registry = MobileWorkspaceObserverRegistry(
            notificationCenter: notificationCenter,
            focusWorkspaceSampler: { tabManager, workspaceID in
                sampleCounts[ObjectIdentifier(tabManager), default: 0] += 1
                return tabManager.tabs.first(where: { $0.id == workspaceID })
            }
        )
        registry.ensureObserver(for: targetManager, notificationStore: nil)
        registry.ensureObserver(for: unrelatedManager, notificationStore: nil)

        #expect(await postFocusUntilObserved(
            on: notificationCenter,
            workspaceID: targetWorkspaceID,
            condition: { sampleCounts[targetManagerID, default: 0] > 0 }
        ))

        #expect(sampleCounts[targetManagerID, default: 0] > 0)
        #expect(
            sampleCounts[unrelatedManagerID, default: 0] == 0,
            "an exact workspace focus event must not wake or sample unrelated observers"
        )
    }

    @Test func focusSequencesIncreaseWhenWorkspaceMovesAcrossObservers() async throws {
        let fixture = try makeTransferredWorkspaceFixture()
        let notificationCenter = NotificationCenter()
        let focusEventSequenceService = MobileWorkspaceFocusEventSequenceService()
        var sampleCount = 0
        let registry = MobileWorkspaceObserverRegistry(
            notificationCenter: notificationCenter,
            focusEventSequenceService: focusEventSequenceService,
            focusWorkspaceSampler: { tabManager, workspaceID in
                sampleCount += 1
                return tabManager.workspacesById[workspaceID]
            }
        )
        registry.ensureObserver(for: fixture.sourceManager, notificationStore: nil)
        registry.ensureObserver(for: fixture.destinationManager, notificationStore: nil)
        defer { withExtendedLifetime(registry) {} }

        #expect(await postFocusUntilObserved(
            on: notificationCenter,
            workspaceID: fixture.workspace.id,
            condition: { sampleCount > 0 }
        ))
        let sourceSequenceBeforeFocus = try #require(
            focusEventSequence(of: focusEventSequenceService)
        )
        fixture.workspace.focusPanel(fixture.firstTargetPanelID)
        notificationCenter.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: fixture.workspace.id]
        )
        #expect(await waitForSequence(
            on: focusEventSequenceService,
            after: sourceSequenceBeforeFocus
        ))
        let firstSequence = try #require(focusEventSequence(of: focusEventSequenceService))

        let detached = try #require(
            fixture.sourceManager.detachWorkspace(tabId: fixture.workspace.id)
        )
        #expect(detached === fixture.workspace)
        fixture.destinationManager.attachWorkspace(detached, select: true)
        #expect(fixture.destinationManager.tabs.contains { $0.id == fixture.workspace.id })

        let destinationSequenceBeforeFocus = try #require(
            focusEventSequence(of: focusEventSequenceService)
        )
        fixture.workspace.focusPanel(fixture.secondTargetPanelID)
        notificationCenter.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: fixture.workspace.id]
        )
        #expect(await waitForSequence(
            on: focusEventSequenceService,
            after: destinationSequenceBeforeFocus
        ))
        let secondSequence = try #require(focusEventSequence(of: focusEventSequenceService))

        #expect(
            secondSequence > firstSequence,
            "focus ordering for one workspace must increase after it moves between TabManager observers"
        )
    }

    @Test func removingObserverReleasesItsWorkspaceFocusRoute() async throws {
        let notificationCenter = NotificationCenter()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let liveManager = TabManager(autoWelcomeIfNeeded: false)
        let workspaceID = try #require(tabManager.selectedWorkspace?.id)
        let liveWorkspaceID = try #require(liveManager.selectedWorkspace?.id)
        let tabManagerID = ObjectIdentifier(tabManager)
        let liveManagerID = ObjectIdentifier(liveManager)
        var sampleCounts: [ObjectIdentifier: Int] = [:]
        let registry = MobileWorkspaceObserverRegistry(
            notificationCenter: notificationCenter,
            focusWorkspaceSampler: { tabManager, workspaceID in
                sampleCounts[ObjectIdentifier(tabManager), default: 0] += 1
                return tabManager.workspacesById[workspaceID]
            }
        )
        registry.ensureObserver(for: tabManager, notificationStore: nil)
        registry.ensureObserver(for: liveManager, notificationStore: nil)

        #expect(await postFocusUntilObserved(
            on: notificationCenter,
            workspaceID: workspaceID,
            condition: { sampleCounts[tabManagerID, default: 0] > 0 }
        ))
        let removedObserverBaseline = sampleCounts[tabManagerID, default: 0]
        #expect(removedObserverBaseline > 0)

        registry.removeObserver(for: tabManager)
        notificationCenter.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: workspaceID]
        )
        #expect(await postFocusUntilObserved(
            on: notificationCenter,
            workspaceID: liveWorkspaceID,
            condition: { sampleCounts[liveManagerID, default: 0] > 0 }
        ))

        #expect(
            sampleCounts[tabManagerID, default: 0] == removedObserverBaseline,
            "removed observers must release their workspace routes"
        )
    }

    private func makeTransferredWorkspaceFixture() throws -> (
        sourceManager: TabManager,
        destinationManager: TabManager,
        workspace: Workspace,
        firstTargetPanelID: UUID,
        secondTargetPanelID: UUID
    ) {
        let sourceManager = TabManager(autoWelcomeIfNeeded: false)
        let destinationManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(sourceManager.selectedWorkspace)
        let initialPanelID = try #require(workspace.focusedPanelId)
        let firstTargetPanel = try #require(workspace.newTerminalSplit(
            from: initialPanelID,
            orientation: .horizontal,
            focus: false
        ))
        let secondTargetPanel = try #require(workspace.newTerminalSplit(
            from: firstTargetPanel.id,
            orientation: .vertical,
            focus: false
        ))
        return (
            sourceManager: sourceManager,
            destinationManager: destinationManager,
            workspace: workspace,
            firstTargetPanelID: firstTargetPanel.id,
            secondTargetPanelID: secondTargetPanel.id
        )
    }

    private func focusEventSequence(
        of service: MobileWorkspaceFocusEventSequenceService
    ) -> UInt64? {
        Mirror(reflecting: service).children
            .first(where: { $0.label == "sequence" })?.value as? UInt64
    }

    private func waitForSequence(
        on service: MobileWorkspaceFocusEventSequenceService,
        after previousSequence: UInt64
    ) async -> Bool {
        for _ in 0..<100 {
            if (focusEventSequence(of: service) ?? 0) > previousSequence {
                return true
            }
            await Task.yield()
        }
        return (focusEventSequence(of: service) ?? 0) > previousSequence
    }

    private func postFocusUntilObserved(
        on notificationCenter: NotificationCenter,
        workspaceID: UUID,
        condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            notificationCenter.post(
                name: .ghosttyDidFocusSurface,
                object: nil,
                userInfo: [GhosttyNotificationKey.tabId: workspaceID]
            )
            await Task.yield()
            if condition() {
                return true
            }
        }
        return condition()
    }

}
