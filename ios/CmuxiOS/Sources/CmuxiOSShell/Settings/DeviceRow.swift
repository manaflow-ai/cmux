import CmuxiOSFeatureKit
import CmuxLink
import SwiftUI

/// One device in Settings: platform glyph, name, trust and last seen, and
/// the live path with its round-trip time when a link is up.
struct DeviceRow: View {
    let device: DeviceRecord
    let badge: PathBadge?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: SettingsText.symbol(of: device.platform))
                .foregroundStyle(.secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(SettingsText.status(of: device))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let badge {
                    Text(SettingsText.pathSummary(badge))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [device.name, SettingsText.status(of: device)]
        if let badge { parts.append(SettingsText.pathSpoken(badge)) }
        return parts.joined(separator: ", ")
    }
}
