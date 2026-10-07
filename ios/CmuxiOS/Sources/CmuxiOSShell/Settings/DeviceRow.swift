import CmuxiOSFeatureKit
import SwiftUI

/// One device in Settings: platform glyph, name, trust state.
struct DeviceRow: View {
    let device: DeviceRecord

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(device.name)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch device.platform {
        case .mac: "desktopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .cloudVM: "cloud"
        }
    }

    private var detail: String {
        if device.isThisDevice { return SettingsText.thisDevice }
        switch device.trust {
        case .trusted: return SettingsText.trusted
        case .discovered: return SettingsText.notPaired
        case .revoked: return SettingsText.revoked
        }
    }
}
