public import CmuxiOSCloudCore
public import CmuxiOSFeatureKit
import SwiftUI
public import UIKit

/// Lane C12's entry for the shell: the Cloud tab over the account's
/// `CloudMachineSource` (plans/cmux-next/ios-next/c12-cloud.md).
@MainActor
public struct CloudFeature {
    private let source: any CloudMachineSource
    private let isMock: Bool

    public init(source: any CloudMachineSource, isMock: Bool) {
        self.source = source
        self.isMock = isMock
    }

    /// The Cloud tab root in its navigation controller.
    public func makeCloudScreen() -> UIViewController {
        let model = CloudModel(source: source, isMock: isMock)
        let hosting = UIHostingController(rootView: NavigationStack { CloudView(model: model) })
        hosting.view.accessibilityIdentifier = "cloud.screen"
        return hosting
    }
}

extension CloudFeature {
    /// Onboarding's sentence for a create that did not succeed; nil when created.
    public static func message(for outcome: CloudFirstMachineOutcome) -> String? {
        switch outcome {
        case .created: nil
        case .refused(let code): CloudText.refusal(code)
        case .offline: CloudText.offlineError
        }
    }
}
