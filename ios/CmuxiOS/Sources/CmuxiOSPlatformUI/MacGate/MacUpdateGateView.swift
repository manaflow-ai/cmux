public import CmuxiOSPlatform
public import SwiftUI

/// Shown instead of a Mac's surfaces when it is not compatible: which side
/// to update and how. Feature screens show it from the verdict of
/// `MacCompatibilityPolicy`.
public struct MacUpdateGateView: View {
    let mac: MacCapabilities
    let verdict: MacCompatibility

    public init(mac: MacCapabilities, verdict: MacCompatibility) {
        self.mac = mac
        self.verdict = verdict
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isPhoneUpdate ? "iphone.and.arrow.forward" : "desktopcomputer.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(steps).font(.callout).multilineTextAlignment(.center)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(24)
        .frame(maxWidth: 480)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("platform.macGate")
    }

    private var isPhoneUpdate: Bool {
        if case .phoneUpdateRequired = verdict { return true }
        return false
    }

    private var title: String {
        isPhoneUpdate ? PlatformText.gatePhoneTitle : PlatformText.gateMacTitle(mac.name)
    }

    private var message: String {
        switch verdict {
        case .compatible: ""
        case .macUpdateRequired, .missingCapabilities: PlatformText.gateMacMessage(mac.name, mac.appVersion)
        case .phoneUpdateRequired: PlatformText.gatePhoneMessage(mac.name)
        }
    }

    private var steps: String {
        isPhoneUpdate ? PlatformText.gatePhoneSteps : PlatformText.gateMacSteps
    }
}
