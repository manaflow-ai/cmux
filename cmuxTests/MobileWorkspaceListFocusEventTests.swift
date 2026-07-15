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
    @Test func focusSequencesIncreaseWhenWorkspaceMovesAcrossObservers() async throws {
        let fixture = try makeTransferredWorkspaceFixture()
        let sourceObserver = MobileWorkspaceListObserver(tabManager: fixture.sourceManager)
        let destinationObserver = MobileWorkspaceListObserver(tabManager: fixture.destinationManager)
        defer { withExtendedLifetime((sourceObserver, destinationObserver)) {} }

        await allowNotificationTasksToStart()
        let sourceSequenceBeforeFocus = try #require(focusEventSequence(of: sourceObserver))
        fixture.workspace.focusPanel(fixture.firstTargetPanelID)
        #expect(await waitForSequence(on: sourceObserver, after: sourceSequenceBeforeFocus))
        let firstSequence = try #require(focusEventSequence(of: sourceObserver))

        let detached = try #require(
            fixture.sourceManager.detachWorkspace(tabId: fixture.workspace.id)
        )
        #expect(detached === fixture.workspace)
        fixture.destinationManager.attachWorkspace(detached, select: true)
        #expect(fixture.destinationManager.tabs.contains { $0.id == fixture.workspace.id })

        let destinationSequenceBeforeFocus = try #require(
            focusEventSequence(of: destinationObserver)
        )
        fixture.workspace.focusPanel(fixture.secondTargetPanelID)
        #expect(await waitForSequence(
            on: destinationObserver,
            after: destinationSequenceBeforeFocus
        ))
        let secondSequence = try #require(focusEventSequence(of: destinationObserver))

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

    private func focusEventSequence(of observer: MobileWorkspaceListObserver) -> UInt64? {
        let mirror = Mirror(reflecting: observer)
        if let sequence = mirror.children.first(where: { $0.label == "focusEventSequence" })?.value as? UInt64 {
            return sequence
        }
        guard let service = mirror.children.first(where: { $0.label == "focusEventSequenceService" })?.value else {
            return nil
        }
        return Mirror(reflecting: service).children
            .first(where: { $0.label == "sequence" })?.value as? UInt64
    }

    private func waitForSequence(
        on observer: MobileWorkspaceListObserver,
        after previousSequence: UInt64
    ) async -> Bool {
        for _ in 0..<100 {
            if (focusEventSequence(of: observer) ?? 0) > previousSequence {
                return true
            }
            await Task.yield()
        }
        return (focusEventSequence(of: observer) ?? 0) > previousSequence
    }

    private func allowNotificationTasksToStart() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}
