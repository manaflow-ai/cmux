import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Renderable system symbols")
struct RenderableSystemSymbolTests {
    @Test func rasterPointSizeClampsInvalidInputs() {
        #expect(RenderableSystemSymbol.clampedRasterPointSize(0) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(-8) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(11) == 11)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(.nan) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(.infinity) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(-.infinity) == 1)
    }
}
