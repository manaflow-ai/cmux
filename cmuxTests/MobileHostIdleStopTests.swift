import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MobileHostIdleStopTests {
    @Test(arguments: ["active", "activating", "failed"])
    func prepareForStopClearsSettingsReadinessBeforeCleanup(phase: String) async {
        let runtime = MobileHostIrxRuntime(pairingEnabled: { false })
        runtime.setSettingsPhase(phase == "active" ? .active : (phase == "activating" ? .activating : .failed))
        runtime.prepareForStop()
        #expect(runtime.settingsPhase == .idle)
        #expect(runtime.listenerState == MobileHostListenerState())
        await runtime.stopHost()
    }
}
