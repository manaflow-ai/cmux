import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud machines client bootstrap")
struct MachinesPanelClientBootstrapTests {
    @Test("Auth teardown clears refresh ownership and loading state")
    @MainActor
    func authTeardownClearsRefreshState() {
        let model = MachinesPanelViewModel()

        model.resetForAuthTransition()

        #expect(!model.isLoading)
        #expect(!model.hasLoadedOnce)
        #expect(model.listProblem == nil)
    }
}
