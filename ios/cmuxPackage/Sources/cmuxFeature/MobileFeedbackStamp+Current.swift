import CmuxMobileShellModel
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the current ``MobileFeedbackStamp`` from the running app's bundle and
/// device at the composition root.
///
/// Lives in the app layer because it reads `Bundle.main`, `UIDevice`, and the
/// hardware machine identifier, none of which belong in the platform-light shell
/// package. The build type is derived from `#if DEBUG` plus the bundle id, the
/// single place that derivation lives.
extension MobileFeedbackStamp {
    /// Resolve the stamp for the running build.
    @MainActor
    static func current() -> MobileFeedbackStamp {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let buildType = MobileBuildType.resolve(
            isDebugBuild: isDebugBuild,
            bundleIdentifier: bundleID
        )
        return MobileFeedbackStamp(
            buildType: buildType,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            appBuild: info["CFBundleVersion"] as? String ?? "",
            bundleIdentifier: bundleID,
            osVersion: osVersion,
            deviceModel: deviceModel
        )
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static var osVersion: String {
        #if canImport(UIKit)
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion)"
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    /// The hardware machine identifier (e.g. `"iPhone16,2"`), which is more
    /// useful for triage than the marketing model name. Falls back to
    /// `UIDevice.model` when the sysctl is empty (e.g. simulator).
    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        if !machine.isEmpty {
            return machine
        }
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return ""
        #endif
    }
}
