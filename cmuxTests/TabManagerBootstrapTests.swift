import Testing
import CmuxRemoteSession

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TabManagerBootstrapTests {
    @MainActor
    @Test
    func appBootstrapManagerDoesNotCreateAWorkspaceOrTerminal() {
        let nativeSSHConnectionBroker = NativeSSHConnectionBroker()
        let manager = TabManager.makeAppBootstrap(
            nativeSSHConnectionBroker: nativeSSHConnectionBroker
        )

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedWorkspace == nil)
        #expect(manager.selectedSurface == nil)
        #expect(manager.nativeSSHConnectionBroker === nativeSSHConnectionBroker)
    }
}
