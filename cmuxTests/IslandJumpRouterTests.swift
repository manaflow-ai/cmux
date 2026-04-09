// cmuxTests/IslandJumpRouterTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class IslandJumpRouterTests: XCTestCase {

    private final class SpyFocusSink: IslandFocusSink {
        enum Call: Equatable {
            case activate
            case selectWorkspace(UUID)
            case focusPanel(UUID, UUID)
            case collapse
        }
        var calls: [Call] = []
        var workspaceExists: Bool = true
        var panelExists: Bool = true

        func activateApp() { calls.append(.activate) }

        func selectWorkspace(id: UUID) -> Bool {
            calls.append(.selectWorkspace(id))
            return workspaceExists
        }
        func focusPanel(id: UUID, inWorkspace workspaceId: UUID) -> Bool {
            calls.append(.focusPanel(id, workspaceId))
            return panelExists
        }
        func collapseIsland() { calls.append(.collapse) }
    }

    private func makeSession(workspaceId: UUID = UUID(), panelId: UUID = UUID()) -> IslandSession {
        IslandSession(
            id: panelId,
            workspaceId: workspaceId,
            panelId: panelId,
            agentKind: .claudeCode,
            phase: .running,
            workspaceTitle: "w",
            panelTitle: "p",
            lastActivity: Date(),
            unreadCount: 0,
            rawStatusValue: "Running"
        )
    }

    func testHappyPathSequence() {
        let spy = SpyFocusSink()
        let router = IslandJumpRouter(focusSink: spy)
        let s = makeSession()
        router.jump(to: s)
        XCTAssertEqual(
            spy.calls,
            [
                .selectWorkspace(s.workspaceId),
                .activate,
                .focusPanel(s.panelId, s.workspaceId),
                .collapse
            ]
        )
    }

    func testWorkspaceGoneShortCircuits() {
        let spy = SpyFocusSink()
        spy.workspaceExists = false
        let router = IslandJumpRouter(focusSink: spy)
        let s = makeSession()
        router.jump(to: s)
        // Router skipped activation once it learned the workspace was
        // gone. Spec §6.6: "collapses the island without activating cmux".
        XCTAssertEqual(
            spy.calls,
            [
                .selectWorkspace(s.workspaceId),
                .collapse
            ]
        )
    }

    func testPanelGoneCollapsesAfterTrying() {
        let spy = SpyFocusSink()
        spy.panelExists = false
        let router = IslandJumpRouter(focusSink: spy)
        let s = makeSession()
        router.jump(to: s)
        // Workspace was found → activation + focus attempt both run;
        // focus returns false but router still collapses exactly once.
        XCTAssertEqual(
            spy.calls,
            [
                .selectWorkspace(s.workspaceId),
                .activate,
                .focusPanel(s.panelId, s.workspaceId),
                .collapse
            ]
        )
    }
}
