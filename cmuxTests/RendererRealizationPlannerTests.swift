import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-policy tests for `RendererRealizationPlanner`, the decision for which
/// offscreen terminal surfaces release their GPU renderer (Metal swap chain /
/// IOSurface) while keeping their PTY alive.
final class RendererRealizationPlannerTests: XCTestCase {
    private func input(
        _ id: UUID,
        visible: Bool = false,
        realized: Bool = true,
        lastVisibleAt: TimeInterval
    ) -> RendererRealizationPlannerInput {
        RendererRealizationPlannerInput(
            surfaceId: id,
            isVisible: visible,
            isRealized: realized,
            lastVisibleAt: lastVisibleAt
        )
    }

    private func settings(
        enabled: Bool = true,
        idle: TimeInterval = 30,
        warm: Int = 12
    ) -> RendererRealizationSettings.Values {
        .init(enabled: enabled, idleSeconds: idle, maxWarmRenderers: warm)
    }

    func testDisabledSelectsNothing() {
        let now: TimeInterval = 1000
        let inputs = [input(UUID(), lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(enabled: false), now: now
        )
        XCTAssertTrue(selected.isEmpty)
    }

    func testNeverSelectsVisibleSurface() {
        let now: TimeInterval = 1000
        let visible = UUID()
        // Visible and very idle and warm cap 0: must still never be selected.
        let inputs = [input(visible, visible: true, lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        XCTAssertFalse(selected.contains(visible))
    }

    func testRespectsIdleThreshold() {
        let now: TimeInterval = 1000
        let recent = UUID() // idle 2s < 5s
        let old = UUID()    // idle 100s
        let inputs = [
            input(recent, lastVisibleAt: now - 2),
            input(old, lastVisibleAt: now - 100),
        ]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        XCTAssertFalse(selected.contains(recent))
        XCTAssertTrue(selected.contains(old))
    }

    func testKeepsWarmCapMostRecent() {
        let now: TimeInterval = 1000
        var ids: [UUID] = []
        var inputs: [RendererRealizationPlannerInput] = []
        for i in 0..<5 {
            let id = UUID()
            ids.append(id)
            // i = 0 is most recently visible; all are idle past the threshold.
            inputs.append(input(id, lastVisibleAt: now - TimeInterval(100 + i)))
        }
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 2), now: now
        )
        XCTAssertEqual(selected.count, 3)
        XCTAssertFalse(selected.contains(ids[0])) // 2 most-recent kept warm
        XCTAssertFalse(selected.contains(ids[1]))
        XCTAssertTrue(selected.contains(ids[2]))
        XCTAssertTrue(selected.contains(ids[4])) // oldest released
    }

    func testOnlyRealizedSurfacesAreConsidered() {
        let now: TimeInterval = 1000
        let unrealized = UUID()
        let inputs = [input(unrealized, realized: false, lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        XCTAssertTrue(selected.isEmpty)
    }

    func testVisibleSurfaceOccupiesWarmSlotButIsNeverSelected() {
        let now: TimeInterval = 1000
        let visible = UUID()
        let off1 = UUID()
        let off2 = UUID()
        let off3 = UUID()
        let inputs = [
            input(visible, visible: true, lastVisibleAt: now), // rank 1 (warm)
            input(off1, lastVisibleAt: now - 10),              // rank 2 (warm)
            input(off2, lastVisibleAt: now - 20),              // rank 3 (release)
            input(off3, lastVisibleAt: now - 30),              // rank 4 (release)
        ]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 2), now: now
        )
        XCTAssertFalse(selected.contains(visible))
        XCTAssertFalse(selected.contains(off1))
        XCTAssertTrue(selected.contains(off2))
        XCTAssertTrue(selected.contains(off3))
    }

    func testDeterministicTieBreakById() {
        let now: TimeInterval = 1000
        // Two surfaces with identical timestamps, warm cap 1: the tie-break
        // sorts by ascending uuidString, so the lower id is kept warm and the
        // higher id is released. Deterministic regardless of input order.
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let inputs = [
            input(a, lastVisibleAt: now - 100),
            input(b, lastVisibleAt: now - 100),
        ]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 1), now: now
        )
        // Sort is by uuidString ascending for the tie, then we keep the first
        // (warm) and release the rest, so exactly one is selected.
        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected.contains(b))
        XCTAssertFalse(selected.contains(a))
    }
}
