import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminationDeadlineBudgetTests {
    @Test
    func hardWatchdogCoversCaptureDeferredKillsAndTeardown() {
        let budget = ConfirmedTerminationDeadlineBudget()
        #expect(
            TerminationWatchdog.defaultDeadline
                >= budget.minimumHardDeadline
        )
    }
}
