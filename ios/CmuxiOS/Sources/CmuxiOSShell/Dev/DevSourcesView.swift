import CmuxiOSFeatureKit
import SwiftUI

/// DEV screen: switch each seam between mock and real, toggle feature
/// flags, and drop the mock owners' connection to preview offline states.
struct DevSourcesView: View {
    @Bindable var model: DevSourcesModel

    var body: some View {
        Form {
            Section {
                ForEach(FeatureSeam.allCases, id: \.self) { seam in
                    SeamModeRow(seam: seam, model: model)
                }
            } header: {
                Text(SettingsText.sources)
            } footer: {
                Text(SettingsText.sourcesFooter)
            }
            Section {
                ForEach(ShellFeatureFlag.allCases, id: \.self) { flag in
                    Toggle(flag.title, isOn: Binding(
                        get: { model.flags.isEnabled(flag) },
                        set: { model.flags.set(flag, enabled: $0) }
                    ))
                    .disabled(model.flags.isPinnedByEnvironment(flag))
                    .accessibilityIdentifier("shell.dev.flag." + flag.rawValue)
                }
            } header: {
                Text(SettingsText.flags)
            } footer: {
                Text(SettingsText.flagsFooter)
            }
            Section(SettingsText.mockOwner) {
                Toggle(SettingsText.mockOffline, isOn: Binding(
                    get: { model.mockOffline },
                    set: { offline in Task { await model.setMockOffline(offline) } }
                ))
                .accessibilityIdentifier("shell.dev.mockOffline")
            }
        }
        .navigationTitle(SettingsText.developer)
    }
}
