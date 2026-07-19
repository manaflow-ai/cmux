import Testing

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
        let manager = TabManager(createInitialWorkspace: false)

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedWorkspace == nil)
        #expect(manager.selectedSurface == nil)
    }
}
