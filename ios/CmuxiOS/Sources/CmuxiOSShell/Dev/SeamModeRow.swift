import CmuxiOSFeatureKit
import SwiftUI

/// One seam's mock/real picker with its lane and registration state.
struct SeamModeRow: View {
    let seam: FeatureSeam
    @Bindable var model: DevSourcesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(seam.protocolName)
                    .font(.body.monospaced())
                Spacer()
                Text(seam.lane)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(seam.protocolName, selection: Binding(
                get: { model.modes.mode(seam) },
                set: { model.modes.set(seam, to: $0) }
            )) {
                Text(SettingsText.mock).tag(FeatureSourceMode.mock)
                Text(SettingsText.real).tag(FeatureSourceMode.real)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.modes.isPinnedByEnvironment(seam))
            .accessibilityIdentifier("shell.dev.source." + seam.rawValue)
            if model.modes.mode(seam) == .real && !model.isRegistered(seam) {
                Text(SettingsText.notRegistered)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
