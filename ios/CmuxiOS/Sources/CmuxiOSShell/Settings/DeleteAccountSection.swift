import CmuxiOSSettingsCore
import SwiftUI

/// Delete Account with a destructive confirmation, then the outcome alert
/// (shipping copy). The model signs out when the account is gone.
struct DeleteAccountSection: View {
    let model: AccountSettingsModel
    @State private var confirming = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                confirming = true
            } label: {
                Label(model.isDeleting ? SettingsText.deletingAccount : SettingsText.deleteAccount,
                      systemImage: model.isDeleting ? "hourglass" : "trash")
            }
            .disabled(model.isDeleting)
            .accessibilityIdentifier("shell.settings.deleteAccount")
        } footer: {
            Text(SettingsText.deleteAccountFooter)
        }
        .alert(SettingsText.deleteAccountTitle, isPresented: $confirming) {
            Button(SettingsText.cancel, role: .cancel) {}
            Button(SettingsText.deleteAccount, role: .destructive) {
                Task { await model.deleteAccount() }
            }
        } message: {
            Text(SettingsText.deleteAccountMessage)
        }
        .alert(
            model.deletionAlert.map(SettingsText.deletionTitle) ?? "",
            isPresented: Binding(
                get: { model.deletionAlert != nil },
                set: { shown in if !shown { Task { await model.acknowledgeDeletionAlert() } } }
            ),
            presenting: model.deletionAlert
        ) { _ in
            Button(SettingsText.ok, role: .cancel) {}
        } message: { failure in
            Text(SettingsText.deletionMessage(failure))
        }
    }
}
