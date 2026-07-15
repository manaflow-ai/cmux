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
        await allowNotificationTasksToStart()

        notificationCenter.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: targetWorkspaceID]
        )
        for _ in 0..<100 where sampleCounts[targetManagerID, default: 0] == 0 {
            await Task.yield()
        }

        #expect(sampleCounts[targetManagerID] == 1)
        #expect(
            sampleCounts[unrelatedManagerID, default: 0] == 0,
            "an exact workspace focus event must not wake or sample unrelated observers"
        )
    }

    @Test func focusSequencesIncreaseWhenWorkspaceMovesAcrossObservers() async throws {
        let fixture = try makeTransferredWorkspaceFixture()
        let focusEventSequenceService = MobileWorkspaceFocusEventSequenceService()
        let sourceObserver = MobileWorkspaceListObserver(
            tabManager: fixture.sourceManager,
            focusEventSequenceService: focusEventSequenceService
        )
        let destinationObserver = MobileWorkspaceListObserver(
            tabManager: fixture.destinationManager,
            focusEventSequenceService: focusEventSequenceService
        )
        defer { withExtendedLifetime((sourceObserver, destinationObserver)) {} }

        await allowNotificationTasksToStart()
        let sourceSequenceBeforeFocus = try #require(
            focusEventSequence(of: focusEventSequenceService)
        )
        fixture.workspace.focusPanel(fixture.firstTargetPanelID)
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

    private func allowNotificationTasksToStart() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}
