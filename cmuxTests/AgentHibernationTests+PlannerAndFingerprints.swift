import Foundation
import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Hibernation planner selection, fingerprints, stability window
extension AgentHibernationTests {
    func testPlannerOnlySelectsIdleUnprotectedExcessLiveAgents() {
        let workspaceId = UUID()
        let now: TimeInterval = 1_000
        let idleOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let idleNew = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let runningOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let needsInputOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let unknownOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let unconfirmedInputOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let visibleOld = AgentHibernationPanelKey(workspaceId: workspaceId, panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 1,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(key: idleOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: idleNew, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 10),
                .init(key: runningOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .running, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: needsInputOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .needsInput, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: unknownOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .unknown, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
                .init(key: unconfirmedInputOld, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: true, lastActivityAt: now - 300),
                .init(key: visibleOld, hasRestorableAgent: true, isLive: true, isProtected: true, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: now - 300),
            ],
            settings: settings,
            now: now
        )

        XCTAssertEqual(selected, Set([idleOld]))
    }

    func testPlannerDoesNotSelectWhenUnderLiveLimit() {
        let key = AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
        let settings = AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: 60,
            maxLiveTerminals: 2,
            confirmationSeconds: 5
        )

        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [
                .init(key: key, hasRestorableAgent: true, isLive: true, isProtected: false, lifecycle: .idle, hasUnconfirmedTerminalInput: false, lastActivityAt: 0),
            ],
            settings: settings,
            now: 1_000
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testProcessFallbackFingerprintIncludesProcessIDs() {
        let first = AgentHibernationController.processFallbackFingerprint(
            kind: .opencode,
            sessionId: "same-session",
            processIDs: [7, 3]
        )
        let sameIDsDifferentOrder = AgentHibernationController.processFallbackFingerprint(
            kind: .opencode,
            sessionId: "same-session",
            processIDs: [3, 7]
        )
        let restarted = AgentHibernationController.processFallbackFingerprint(
            kind: .opencode,
            sessionId: "same-session",
            processIDs: [8]
        )

        XCTAssertEqual(first, sameIDsDifferentOrder)
        XCTAssertNotEqual(first, restarted)
    }

    func testScrollbackFingerprintIncludesProcessIDs() {
        let first = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [7, 3]
        )
        let sameIDsDifferentOrder = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [3, 7]
        )
        let restarted = AgentHibernationController.scrollbackFingerprint(
            tail: "stable tail",
            processIDs: [8]
        )

        XCTAssertEqual(first, sameIDsDifferentOrder)
        XCTAssertNotEqual(first, restarted)
    }

    func testFirstTailSampleStartsObservedStabilityWindow() {
        XCTAssertEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: nil,
                previousStableSince: nil,
                currentFingerprint: "tail-a",
                lastActivityAt: 100,
                now: 500
            ),
            500
        )
        XCTAssertEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: "tail-a",
                previousStableSince: 100,
                currentFingerprint: "tail-a",
                lastActivityAt: 120,
                now: 500
            ),
            100
        )
        XCTAssertEqual(
            AgentHibernationController.tailFingerprintStableSince(
                previousFingerprint: "tail-a",
                previousStableSince: 100,
                currentFingerprint: "tail-b",
                lastActivityAt: 120,
                now: 500
            ),
            500
        )
    }

}
