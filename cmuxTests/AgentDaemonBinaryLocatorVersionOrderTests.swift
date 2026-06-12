import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The cached-daemon fallback must pick the newest version numerically:
/// lexicographic sorting put 0.9.0 ahead of 0.10.0, so a user holding both
/// got the older (capability-incompatible) daemon and chat reported the
/// cache as too old.
@Suite struct AgentDaemonBinaryLocatorVersionOrderTests {
    @Test func numericComponentsBeatLexicographicOrder() {
        #expect(AgentDaemonBinaryLocator.isVersionNewer("0.10.0", "0.9.0"))
        #expect(!AgentDaemonBinaryLocator.isVersionNewer("0.9.0", "0.10.0"))
        #expect(AgentDaemonBinaryLocator.isVersionNewer("1.0.0", "0.99.99"))
    }

    @Test func missingComponentsCountAsZero() {
        #expect(AgentDaemonBinaryLocator.isVersionNewer("1.2.1", "1.2"))
        #expect(!AgentDaemonBinaryLocator.isVersionNewer("1.2", "1.2.0"))
        #expect(!AgentDaemonBinaryLocator.isVersionNewer("1.2.0", "1.2"))
    }

    @Test func nonNumericComponentsFallBackToStringOrder() {
        #expect(AgentDaemonBinaryLocator.isVersionNewer("1.0.0-rc2", "1.0.0-rc1"))
        #expect(!AgentDaemonBinaryLocator.isVersionNewer("1.0.0-rc1", "1.0.0-rc2"))
    }

    @Test func sortingNewestFirst() {
        let versions = ["0.9.0", "0.10.0", "0.2.1", "1.0.0"]
        let sorted = versions.sorted(by: AgentDaemonBinaryLocator.isVersionNewer)
        #expect(sorted == ["1.0.0", "0.10.0", "0.9.0", "0.2.1"])
    }
}
