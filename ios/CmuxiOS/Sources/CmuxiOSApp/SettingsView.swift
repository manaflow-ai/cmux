import CmuxiOSAccount
import CmuxiOSDesign
import SwiftUI

/// The Settings sheet (HIG "Settings": a grouped list; a destructive
/// account action last, in its own section): Chat Server, then Account
/// with the signed-in email and Delete Account.
struct SettingsView: View {
    let email: String?
    let chatServer: ChatServerSettingsModel
    @Bindable var deletion: AccountDeletionModel
    let onClose: () -> Void

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ChatServerSettingsView(model: chatServer, onDone: onClose, onCancel: onClose)
                } label: {
                    Text(String(localized: "settings.chatServer.title", defaultValue: "Chat Server", bundle: .module))
                }
                .accessibilityIdentifier("settings.chatServer")
            }
            if let email, !email.isEmpty {
                Section {
                    LabeledContent(String(localized: "settings.account.email", defaultValue: "Email", bundle: .module), value: email)
                        .accessibilityIdentifier("settings.account.email")
                } header: {
                    Text(String(localized: "settings.account.header", defaultValue: "Account", bundle: .module))
                }
            }
            AccountDeletionSection(model: deletion)
        }
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "settings.done", defaultValue: "Done", bundle: .module), action: onClose)
                    .disabled(deletion.isDeleting)
                    .accessibilityIdentifier("settings.done")
            }
        }
        // A deletion in flight finishes (or fails) before the sheet can go.
        .interactiveDismissDisabled(deletion.isDeleting)
        .tint(Color(uiColor: HomePalette.accent))
    }
}
