import CmuxAgentJournal
import CmuxSettings
import Foundation
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Wiring of `app.reorderOnNotification` modes to real TabManager ordering.
/// The decision table itself is covered by `WorkspaceActivityReorderGateTests`
/// in CmuxWorkspaces and `AgentLifecycleActivityTests` in CmuxAgentJournal.
@MainActor
final class WorkspaceActivityReorderControllerTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 10_000)
    }

    private final class Counter {
        var value = 0
    }

    private struct Fixture {
        let manager: TabManager
        let clock: Clock
        let controller: WorkspaceActivityReorderController
        /// Selected workspace, then two background ones, in sidebar order.
        let selected: Workspace
        let middle: Workspace
        let bottom: Workspace
    }

    private var interacting = false

    private func makeFixture(
        mode: WorkspaceAutoReorderMode = .agentActivity,
        cooldown: TimeInterval = 10
    ) -> Fixture {
        let manager = TabManager()
        let first = manager.tabs[0]
        _ = manager.addWorkspaceIfActive()
        _ = manager.addWorkspaceIfActive()
        let ordered = manager.tabs
        XCTAssertEqual(ordered.count, 3)
        manager.selectedTabId = first.id
        let clock = Clock()
        let controller = WorkspaceActivityReorderController(
            cooldown: cooldown,
            now: { clock.now },
            mode: { mode },
            isSidebarInteracting: { [unowned self] in interacting },
            tabManagerForWorkspace: { id in manager.workspacesById[id] == nil ? nil : manager }
        )
        let background = ordered.filter { $0.id != first.id }
        let reordered = [first] + background
        manager.reorderWorkspaces(orderedWorkspaceIds: reordered.map(\.id))
        return Fixture(
            manager: manager,
            clock: clock,
            controller: controller,
            selected: first,
            middle: background[0],
            bottom: background[1]
        )
    }

    func testTurnFinishedMovesBackgroundWorkspaceToTop() {
        let fixture = makeFixture()
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.bottom.id)
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.bottom.id)
    }

    func testNotificationsModeIgnoresAgentActivity() {
        let fixture = makeFixture(mode: .notifications)
        let before = fixture.manager.tabs.map(\.id)
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.bottom.id)
        XCTAssertEqual(fixture.manager.tabs.map(\.id), before)
    }

    func testSelectedWorkspaceIsNeverMovedByActivity() {
        let fixture = makeFixture()
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.bottom.id)
        let before = fixture.manager.tabs.map(\.id)
        fixture.controller.agentActivity(.needsInput, workspaceId: fixture.selected.id)
        XCTAssertEqual(fixture.manager.tabs.map(\.id), before)
        XCTAssertTrue(fixture.controller.pendingWorkspaceIds.isEmpty)
    }

    func testPinnedWorkspaceStaysPut() {
        let fixture = makeFixture()
        fixture.manager.setPinned(fixture.middle, pinned: true)
        let before = fixture.manager.tabs.map(\.id)
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.middle.id)
        XCTAssertEqual(fixture.manager.tabs.map(\.id), before)
    }

    func testSidebarHoverDefersTheMoveUntilThePointerLeaves() {
        let fixture = makeFixture()
        let before = fixture.manager.tabs.map(\.id)
        interacting = true
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.bottom.id)
        XCTAssertEqual(fixture.manager.tabs.map(\.id), before, "no row may jump under the cursor")
        XCTAssertEqual(fixture.controller.pendingWorkspaceIds, [fixture.bottom.id])

        fixture.controller.drainPendingMoves()
        XCTAssertEqual(fixture.manager.tabs.map(\.id), before)

        interacting = false
        fixture.controller.drainPendingMoves()
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.bottom.id)
        XCTAssertTrue(fixture.controller.pendingWorkspaceIds.isEmpty)
    }

    func testBurstMovesOnceThenCoalescesIntoOneTrailingMove() {
        let fixture = makeFixture(cooldown: 10)
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.bottom.id)
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.bottom.id)

        // Another workspace moves above it, then the first one finishes again
        // inside its cooldown: it must not jump back yet.
        fixture.clock.now += 1
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.middle.id)
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.middle.id)
        fixture.clock.now += 1
        fixture.controller.agentActivity(.promptSubmitted, workspaceId: fixture.bottom.id)
        fixture.clock.now += 1
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.bottom.id)
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.middle.id)
        XCTAssertEqual(fixture.controller.pendingWorkspaceIds, [fixture.bottom.id])

        fixture.clock.now += 7
        fixture.controller.drainPendingMoves()
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.bottom.id)
        XCTAssertTrue(fixture.controller.pendingWorkspaceIds.isEmpty)
    }

    func testNotificationForAnEventThatAlreadyMovedLeavesNoTrailingMove() {
        let fixture = makeFixture(cooldown: 10)
        fixture.controller.agentActivity(.turnFinished, workspaceId: fixture.bottom.id)
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.bottom.id)
        // The same journal event's notification arrives right after.
        fixture.clock.now += 0.1
        fixture.controller.notificationRequestsReorder(workspaceId: fixture.bottom.id)
        XCTAssertTrue(fixture.controller.pendingWorkspaceIds.isEmpty)
        // Newer activity elsewhere is not overturned when the cooldown ends.
        fixture.clock.now += 1
        fixture.controller.agentActivity(.needsInput, workspaceId: fixture.middle.id)
        fixture.clock.now += 10
        fixture.controller.drainPendingMoves()
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.middle.id)
    }

    func testNotificationOrderingFollowsTheMode() throws {
        let suiteName = "WorkspaceActivityReorderControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = makeFixture()
        let key = SettingCatalog().app.reorderOnNotification
        var effects = TerminalNotificationPolicyEffects()
        effects.reorderWorkspace = true
        let localMoves = Counter()
        let cloudRaises = Counter()
        func apply() {
            effects.applySidebarOrdering(
                defaults: defaults,
                workspaceId: fixture.bottom.id,
                controller: fixture.controller,
                raiseCloudRow: { cloudRaises.value += 1 },
                moveLocalWorkspace: { localMoves.value += 1 }
            )
        }

        UserDefaultsSettingsClient(defaults: defaults).set(.off, for: key)
        apply()
        XCTAssertEqual(localMoves.value, 0)
        XCTAssertEqual(cloudRaises.value, 0)

        // The legacy mode moves immediately, even while the sidebar is hovered.
        interacting = true
        UserDefaultsSettingsClient(defaults: defaults).set(.notifications, for: key)
        apply()
        XCTAssertEqual(localMoves.value, 1)
        XCTAssertEqual(cloudRaises.value, 1)

        // Agent-activity mode raises the Cloud row at once and routes the
        // local move through the gate, which defers it while hovered.
        let before = fixture.manager.tabs.map(\.id)
        UserDefaultsSettingsClient(defaults: defaults).set(.agentActivity, for: key)
        apply()
        XCTAssertEqual(cloudRaises.value, 2)
        XCTAssertEqual(localMoves.value, 1)
        XCTAssertEqual(fixture.manager.tabs.map(\.id), before)
        interacting = false
        fixture.controller.drainPendingMoves()
        XCTAssertEqual(fixture.manager.tabs.first?.id, fixture.bottom.id)
    }
}
