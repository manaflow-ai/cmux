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
            incomingResized: owned,
            measurement: measurement(width: 1_000, height: 760)
        )

        #expect(action == .none)
    }

    @Test
    func unchangedMeasuredGridAcceptsForeignResizeWithoutPingPong() {
        let action = policy.action(
            lastSent: CmuxSurfaceSize(cols: 100, rows: 38),
            incomingResized: CmuxSurfaceSize(cols: 46, rows: 16),
            measurement: measurement(width: 1_009.9, height: 779.9)
        )

        #expect(action == .none)
    }

    @Test
    func changedFinalBoundsUseFloorAndScheduleExactlyOneGrid() {
        let action = policy.action(
            lastSent: CmuxSurfaceSize(cols: 100, rows: 38),
            incomingResized: CmuxSurfaceSize(cols: 46, rows: 16),
            measurement: measurement(width: 1_209.9, height: 819.9)
        )

        #expect(action == .resize(CmuxSurfaceSize(cols: 120, rows: 40)))
    }

    @Test
    func newerBoundsStillResizeAfterThePreviousEcho() {
        let owned = CmuxSurfaceSize(cols: 100, rows: 38)
        let action = policy.action(
            lastSent: owned,
            incomingResized: owned,
            measurement: measurement(width: 1_209.9, height: 819.9)
        )

        #expect(action == .resize(CmuxSurfaceSize(cols: 120, rows: 40)))
    }

    @Test
    func incompleteCellMetricsNeverResize() {
        let action = policy.action(
            lastSent: nil,
            incomingResized: nil,
            measurement: CmuxTerminalMeasurement(
                widthPixels: 1_000,
                heightPixels: 760,
                cellWidthPixels: 0,
                cellHeightPixels: 20
            )
        )

        #expect(action == .none)
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
