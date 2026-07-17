@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxTerminalGridGeometryTests {
    @Test
    func retinaGridUsesNativePixelsAndStaysTopLeft() throws {
        let geometry = try #require(CmuxTerminalGridGeometry(
            containerWidthPoints: 800,
            containerHeightPoints: 500,
            backingScale: 2,
            grid: CmuxSurfaceSize(cols: 60, rows: 18),
            cellWidthPixels: 17,
            cellHeightPixels: 34
        ))

        #expect(geometry.gridFrame == CmuxLayoutRect(
            x: 0,
            y: 0,
            width: 510,
            height: 306
        ))
        #expect(geometry.drawableWidthPixels == 1_020)
        #expect(geometry.drawableHeightPixels == 612)
        #expect(geometry.gridFrame.width * 2 == Double(geometry.drawableWidthPixels))
        #expect(geometry.gridFrame.height * 2 == Double(geometry.drawableHeightPixels))
        #expect(geometry.isForeignSmaller(
            than: CmuxSurfaceSize(cols: 80, rows: 24)
        ))
    }

    @Test
    func oddContainerKeepsForeignReplayAtItsExactGridPixels() throws {
        let geometry = try #require(CmuxTerminalGridGeometry(
            containerWidthPoints: 801.5,
            containerHeightPoints: 503.5,
            backingScale: 2,
            grid: CmuxSurfaceSize(cols: 61, rows: 19),
            cellWidthPixels: 17,
            cellHeightPixels: 33
        ))

        #expect(geometry.gridFrame == CmuxLayoutRect(
            x: 0,
            y: 0,
            width: 518.5,
            height: 313.5
        ))
        #expect(geometry.drawableWidthPixels == 1_037)
        #expect(geometry.drawableHeightPixels == 627)
        #expect(geometry.gridFrame.width != 801.5)
        #expect(geometry.gridFrame.height != 503.5)
    }
}
