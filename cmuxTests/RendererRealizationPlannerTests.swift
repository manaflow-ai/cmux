import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-policy tests for `RendererRealizationPlanner`, the decision for which
/// offscreen terminal surfaces release their GPU renderer (Metal swap chain /
/// IOSurface) while keeping their PTY alive.
struct RendererRealizationPlannerTests {
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
        idle: TimeInterval = RendererRealizationSettings.defaultIdleSeconds,
        warm: Int = 12
    ) -> RendererRealizationSettings.Values {
        .init(enabled: enabled, idleSeconds: idle, maxWarmRenderers: warm)
    }

    @Test func defaultsUseLongUnfocusedIdleThreshold() throws {
        let suiteName = "RendererRealizationPlannerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let defaultIdleSeconds = RendererRealizationSettings.defaultIdleSeconds
        #expect(defaultIdleSeconds == 10 * 60)
        #expect(RendererRealizationSettings.idleSeconds(defaults: defaults) == defaultIdleSeconds)
        #expect(RendererRealizationSettings.sanitizedIdleSeconds(.infinity) == defaultIdleSeconds)
        #expect(TerminalCatalogSection().rendererRealizationIdleSeconds.defaultValue == defaultIdleSeconds)
    }

    @Test func disabledSelectsNothing() {
        let now: TimeInterval = 1000
        let inputs = [input(UUID(), lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(enabled: false), now: now
        )
        #expect(selected.isEmpty)
    }

    @Test func neverSelectsVisibleSurface() {
        let now: TimeInterval = 1000
        let visible = UUID()
        // Visible and very idle and warm cap 0: must still never be selected.
        let inputs = [input(visible, visible: true, lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        #expect(!selected.contains(visible))
    }

    @Test func respectsIdleThreshold() {
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
        #expect(!selected.contains(recent))
        #expect(selected.contains(old))
    }

    @Test func idleThresholdReclaimsHiddenSurfaceInsideWarmCap() {
        let now: TimeInterval = 1000
        let oldHidden = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [input(oldHidden, lastVisibleAt: now - 601)],
            settings: settings(idle: 600, warm: 12),
            now: now
        )
        #expect(selected.count == 1)
        #expect(selected.contains(oldHidden))
    }

    @Test func warmCapOverflowReclaimsBeforeLongIdleThreshold() {
        let now: TimeInterval = 1000
        var ids: [UUID] = []
        var inputs: [RendererRealizationPlannerInput] = []
        for i in 0..<5 {
            let id = UUID()
            ids.append(id)
            inputs.append(input(id, lastVisibleAt: now - TimeInterval(i)))
        }

        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 600, warm: 2), now: now
        )

        #expect(!selected.contains(ids[0]))
        #expect(!selected.contains(ids[1]))
        #expect(selected.contains(ids[2]))
        #expect(selected.contains(ids[3]))
        #expect(selected.contains(ids[4]))
    }

    @Test func keepsWarmCapMostRecent() {
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
        #expect(selected.count == 3)
        #expect(!selected.contains(ids[0])) // 2 most-recent kept warm
        #expect(!selected.contains(ids[1]))
        #expect(selected.contains(ids[2]))
        #expect(selected.contains(ids[4])) // oldest released
    }

    @Test func onlyRealizedSurfacesAreConsidered() {
        let now: TimeInterval = 1000
        let unrealized = UUID()
        let inputs = [input(unrealized, realized: false, lastVisibleAt: 0)]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 0), now: now
        )
        #expect(selected.isEmpty)
    }

    @Test func visibleSurfaceOccupiesWarmSlotButIsNeverSelected() {
        let now: TimeInterval = 1000
        let visible = UUID()
        let off1 = UUID()
        let off2 = UUID()
        let off3 = UUID()
        let inputs = [
            input(visible, visible: true, lastVisibleAt: now), // rank 1 (warm)
            input(off1, lastVisibleAt: now - 1),               // rank 2 (warm)
            input(off2, lastVisibleAt: now - 20),              // rank 3 (release)
            input(off3, lastVisibleAt: now - 30),              // rank 4 (release)
        ]
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs, settings: settings(idle: 5, warm: 2), now: now
        )
        #expect(!selected.contains(visible))
        #expect(!selected.contains(off1))
        #expect(selected.contains(off2))
        #expect(selected.contains(off3))
    }

    @Test func deterministicTieBreakById() {
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
        #expect(selected.count == 1)
        #expect(selected.contains(b))
        #expect(!selected.contains(a))
    }

    @Test func systemMemoryPressureReclaimsAllHiddenRealizedRenderers() {
        let now: TimeInterval = 1000
        let visible = UUID()
        let recentHidden = UUID()
        let oldHidden = UUID()
        let alreadyReleased = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [
                input(visible, visible: true, lastVisibleAt: now),
                input(recentHidden, lastVisibleAt: now - 1),
                input(oldHidden, lastVisibleAt: now - 100),
                input(alreadyReleased, realized: false, lastVisibleAt: now - 100),
            ],
            settings: settings(idle: 600, warm: 12),
            now: now,
            trigger: .systemMemoryPressure
        )

        #expect(!selected.contains(visible))
        #expect(selected.contains(recentHidden))
        #expect(selected.contains(oldHidden))
        #expect(!selected.contains(alreadyReleased))
    }

    @Test func systemMemoryPressureRespectsDisabledSetting() {
        let now: TimeInterval = 1000
        let hidden = UUID()
        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: [input(hidden, lastVisibleAt: now - 1)],
            settings: settings(enabled: false, idle: 600, warm: 12),
            now: now,
            trigger: .systemMemoryPressure
        )

        #expect(selected.isEmpty)
    }
}
