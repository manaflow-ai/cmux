import CmuxMobileShellModel
import Foundation

extension MobileDaemonLaneFlag {
    /// The flag for the running build: its build type (from `#if DEBUG` and
    /// the bundle id, as ``MobileFeedbackStamp/current()`` derives it), the
    /// launch environment, and standard defaults.
    @MainActor
    static func current() -> MobileDaemonLaneFlag {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return MobileDaemonLaneFlag(
            buildType: MobileBuildType.resolve(
                isDebugBuild: isDebugBuild,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? ""
            ),
            environment: ProcessInfo.processInfo.environment,
            defaults: .standard
        )
    }
}
