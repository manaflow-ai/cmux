import CmuxiOSSettingsCore
import SwiftUI

/// What Erase All Data removes, the typed word, and the destructive button
/// (HIG: confirm destructive actions; the typed word prevents accidents).
struct EraseAllDataView: View {
    @Bindable var model: EraseAllDataModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text(SettingsText.eraseIntro)
                Label(SettingsText.eraseListAccount, systemImage: "person.badge.key")
                Label(SettingsText.eraseListSSH, systemImage: "key")
                Label(SettingsText.eraseListContent, systemImage: "doc.on.doc")
                Label(SettingsText.eraseListPreferences, systemImage: "gearshape")
            } footer: {
                Text(SettingsText.eraseWarning)
            }
            Section {
                TextField(SettingsText.eraseTypePrompt(model.rule.word), text: $model.typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .disabled(model.phase != .idle)
                    .accessibilityIdentifier("shell.settings.erase.field")
            }
            Section {
                Button(role: .destructive) {
                    Task { await model.erase() }
                } label: {
                    HStack {
                        Text(model.phase == .erasing ? SettingsText.erasing : SettingsText.eraseAllData)
                        if model.phase == .erasing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!model.canErase)
                .accessibilityIdentifier("shell.settings.erase.confirm")
            }
        }
        .navigationTitle(SettingsText.eraseAllData)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(SettingsText.cancelErase) { dismiss() }
                    .disabled(model.phase == .erasing)
            }
        }
    }
}
