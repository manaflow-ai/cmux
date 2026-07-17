@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxResizePolicyTests {
    private let policy = CmuxResizePolicy()

    @Test
    func echoedResizeDoesNotScheduleAnotherResize() {
        let owned = CmuxSurfaceSize(cols: 100, rows: 38)
        let action = policy.action(
            lastSent: owned,
            measurement: measurement(width: 1_000, height: 760)
        )

        #expect(action == .none)
    }

    @Test
    func unchangedLocalGridIgnoresSharedResizeWithoutPingPong() {
        let action = policy.action(
            lastSent: CmuxSurfaceSize(cols: 100, rows: 38),
            measurement: measurement(width: 1_009.9, height: 779.9)
        )

        #expect(action == .none)
    }

    @Test
    func initialGridIsReportedEvenWhenSharedSurfaceAlreadyMatches() {
        let action = policy.action(
            lastSent: nil,
            measurement: measurement(width: 1_000, height: 760)
        )

        #expect(action == .resize(CmuxSurfaceSize(cols: 100, rows: 38)))
    }

    @Test
    func changedFinalBoundsUseFloorAndScheduleExactlyOneGrid() {
        let action = policy.action(
            lastSent: CmuxSurfaceSize(cols: 100, rows: 38),
            measurement: measurement(width: 1_209.9, height: 819.9)
        )

        #expect(action == .resize(CmuxSurfaceSize(cols: 120, rows: 40)))
    }

    @Test
    func newerBoundsStillResizeAfterThePreviousEcho() {
        let owned = CmuxSurfaceSize(cols: 100, rows: 38)
        let action = policy.action(
            lastSent: owned,
            measurement: measurement(width: 1_209.9, height: 819.9)
        )

        #expect(action == .resize(CmuxSurfaceSize(cols: 120, rows: 40)))
    }

    @Test
    func incompleteCellMetricsNeverResize() {
        let action = policy.action(
            lastSent: nil,
            measurement: CmuxTerminalMeasurement(
                widthPixels: 1_000,
                heightPixels: 760,
                cellWidthPixels: 0,
                cellHeightPixels: 20
            )
        )

        #expect(action == .none)
    }

    @Test
    func fittedGhosttyGridWinsOverCellOnlyEstimate() {
        let fitted = CmuxSurfaceSize(cols: 94, rows: 36)
        let measurement = CmuxTerminalMeasurement(
            widthPixels: 1_330,
            heightPixels: 1_036,
            cellWidthPixels: 14,
            cellHeightPixels: 28,
            fittedGrid: fitted
        )

        #expect(policy.grid(for: measurement) == fitted)
    }

    private func measurement(width: Double, height: Double) -> CmuxTerminalMeasurement {
        CmuxTerminalMeasurement(
            widthPixels: width,
            heightPixels: height,
            cellWidthPixels: 10,
            cellHeightPixels: 20
        )
    }
}
