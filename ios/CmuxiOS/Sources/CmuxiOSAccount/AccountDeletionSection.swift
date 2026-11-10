import CmuxiOSDesign
public import SwiftUI

/// The Delete Account section of Settings (HIG "Alerts": a destructive,
/// irreversible action asks first, with Cancel as the default and the
/// destructive button named for what it does). Progress and failure stay
/// inline in the row (no second alert), so VoiceOver reads them in place.
public struct AccountDeletionSection: View {
    @Bindable var model: AccountDeletionModel

    public init(model: AccountDeletionModel) {
        self.model = model
    }

    public var body: some View {
        Section {
            Button(role: .destructive) {
                model.requestDeletion()
            } label: {
                HStack {
                    Text(model.isDeleting ? AccountText.deleting : AccountText.deleteButton)
                    if model.isDeleting {
                        Spacer()
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                }
            }
            .disabled(model.isDeleting)
            .accessibilityLabel(model.isDeleting ? AccountText.deleting : AccountText.deleteButton)
            .accessibilityHint(model.isDeleting ? "" : AccountText.deleteHint)
            .accessibilityIdentifier(model.isDeleting ? "settings.account.delete.progress" : "settings.account.delete")
            if let failure = model.failure {
                Text(failure.message)
                    .foregroundStyle(Color(uiColor: HomePalette.failure))
                    .accessibilityIdentifier("settings.account.delete.error")
                Button(AccountText.retry) {
                    model.retry()
                }
                .foregroundStyle(Color(uiColor: HomePalette.accent))
                .accessibilityIdentifier("settings.account.delete.retry")
            }
        } footer: {
            Text(AccountText.footer)
        }
        .alert(AccountText.confirmTitle, isPresented: confirming) {
            Button(AccountText.deleteButton, role: .destructive) {
                model.confirm()
            }
            .accessibilityIdentifier("settings.account.delete.confirm")
            Button(AccountText.cancel, role: .cancel) {
                model.cancel()
            }
            .accessibilityIdentifier("settings.account.delete.cancel")
        } message: {
            Text(AccountText.confirmMessage)
        }
    }

    /// Only the alert's own buttons change the phase; the system's dismissal
    /// (which can run before or after a button's action) does not.
    private var confirming: Binding<Bool> {
        Binding(get: { model.isConfirming }, set: { _ in })
    }
}
