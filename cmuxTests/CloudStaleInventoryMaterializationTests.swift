import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud stale inventory admission")
struct CloudStaleInventoryMaterializationTests {
    @Test("a stale graph never materializes an interactive restored terminal")
    func staleGraphIsNotInteractive() {
        #expect(!CmuxTuiSurfaceProvider.shouldReprojectRestoredPanes(observation: .stale(reason: "link timeout")))
        #expect(CmuxTuiSurfaceProvider.shouldReprojectRestoredPanes(observation: .current))
    }
}
