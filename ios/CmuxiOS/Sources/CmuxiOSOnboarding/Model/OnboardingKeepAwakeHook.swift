public import CmuxiOSFeatureKit
public import CmuxiOSOnboardingCore

/// Lane E5's hook for the keep-awake card, over C16's `KeepAwakeControl`
/// (the Mac's power assertion lands with D1b; a mock stands in). Reports
/// stream per Mac; `set` answers nil on success or a message to show.
public struct OnboardingKeepAwakeHook: Sendable {
    public var reports: @Sendable () async -> AsyncStream<[HostID: KeepAwakeReport]>
    public var set: @Sendable (HostID, Bool) async -> String?

    public init(reports: @escaping @Sendable () async -> AsyncStream<[HostID: KeepAwakeReport]>,
                set: @escaping @Sendable (HostID, Bool) async -> String?) {
        self.reports = reports
        self.set = set
    }
}
