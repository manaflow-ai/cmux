import Foundation

/// Strings of the Cloud step (lane C12).
enum CloudStepText {
    static var title: String { String(localized: "onboarding.cloud.title", defaultValue: "Want a machine in the cloud?", bundle: .module) }
    static var body: String {
        String(localized: "onboarding.cloud.body",
               defaultValue: "A Cloud machine keeps agents running while your Mac sleeps. It starts with the smallest size your plan allows.",
               bundle: .module)
    }
    static var create: String { String(localized: "onboarding.cloud.create", defaultValue: "Create Cloud Machine", bundle: .module) }
}
