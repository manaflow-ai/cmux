import CmuxiOSSettingsCore
import SwiftUI

/// Profile, team switcher and Sign Out.
struct AccountSection: View {
    let model: ShellSettingsModel
    @Binding var confirmingSignOut: Bool

    var body: some View {
        Section {
            let profile = model.profile
            LabeledContent {
                if let email = profile.email {
                    Text(email)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } label: {
                Label(profile.displayName.isEmpty ? SettingsText.account : profile.displayName,
                      systemImage: "person.crop.circle")
            }
            // Keep the profile row discoverable as one element in XCTest and
            // VoiceOver. SwiftUI otherwise exposes the LabeledContent's
            // internal label/value children separately on recent iOS builds.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("shell.settings.profile")
            if let account = model.accountModel, !account.snapshot.teams.isEmpty {
                TeamPicker(model: account)
            }
            Button(role: .destructive) {
                confirmingSignOut = true
            } label: {
                Label(SettingsText.signOut, systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(model.isSigningOut)
            .accessibilityIdentifier("shell.settings.signOut")
        } header: {
            Text(SettingsText.account)
        } footer: {
            if model.accountModel?.teamChangeFailed == true {
                Text(SettingsText.teamChangeFailed)
            } else {
                Text(SettingsText.accountFooter)
            }
        }
    }
}
