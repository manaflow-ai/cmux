import Testing
import CmuxTerminal

@Suite
struct TerminalSurfaceResizePolicyTests {
    @Test
    func pixelOnlyResizeWithinExistingGridIsCoalesced() {
        #expect(
            !TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 800,
                currentHeightPx: 480,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 805,
                targetHeightPx: 485,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )
    }

    @Test
    func ambiguousRemainderShrinkKeepsGridChangeDetectionConservative() {
        #expect(
            !TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 805,
                currentHeightPx: 485,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 806,
                targetHeightPx: 486,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 805,
                currentHeightPx: 485,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 810,
                targetHeightPx: 485,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 805,
                currentHeightPx: 485,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 804,
                targetHeightPx: 485,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 808,
                currentHeightPx: 488,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 807,
                targetHeightPx: 487,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 805,
                currentHeightPx: 485,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 799,
                targetHeightPx: 485,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )
    }

    @Test
    func fullCellRemainderKeepsGridChangeDetectionConservative() {
        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 810,
                currentHeightPx: 500,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 819,
                targetHeightPx: 519,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 818,
                currentHeightPx: 500,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 820,
                targetHeightPx: 519,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 810,
                currentHeightPx: 500,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 820,
                targetHeightPx: 519,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )
    }

    @Test
    func resizeAppliesWhenGridChangesOutsideLiveResizeOrFirstApply() {
        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 800,
                currentHeightPx: 480,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 810,
                targetHeightPx: 485,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 800,
                currentHeightPx: 480,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 805,
                targetHeightPx: 485,
                coalescePixelOnlyResize: false,
                hasAppliedPixelSize: true
            )
        )

        #expect(
            TerminalSurface.shouldApplySurfacePixelSizeChange(
                currentColumns: 80,
                currentRows: 24,
                currentWidthPx: 800,
                currentHeightPx: 480,
                currentCellWidthPx: 10,
                currentCellHeightPx: 20,
                targetWidthPx: 805,
                targetHeightPx: 485,
                coalescePixelOnlyResize: true,
                hasAppliedPixelSize: false
            )
        )
    }
}
