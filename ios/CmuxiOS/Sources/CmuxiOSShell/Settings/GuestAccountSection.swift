import SwiftUI

/// The Account section of the signed-out guest shell (deferred sign-in):
/// what works without an account, and Sign In.
struct GuestAccountSection: View {
    let signIn: @MainActor () -> Void

    var body: some View {
        Section {
            Label(SettingsText.notSignedIn, systemImage: "person.crop.circle.badge.questionmark")
                .accessibilityIdentifier("shell.settings.guest")
            Button {
                signIn()
            } label: {
                Label(SettingsText.signIn, systemImage: "person.crop.circle.badge.plus")
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("shell.settings.signIn")
        } header: {
            Text(SettingsText.account)
        } footer: {
            Text(SettingsText.guestFooter)
        }
    }
}
