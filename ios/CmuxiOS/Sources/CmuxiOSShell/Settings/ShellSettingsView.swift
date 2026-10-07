import CmuxiOSFeatureKit
import SwiftUI

/// The Settings tab until lane C11 lands: account, devices, about, sign out,
/// and the Developer section in DEBUG builds. A low-frequency form, so SwiftUI.
struct ShellSettingsView: View {
    @Bindable var model: ShellSettingsModel
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            Section(SettingsText.account) {
                LabeledContent(SettingsText.name, value: model.account.displayName)
                if let email = model.account.email {
                    LabeledContent(SettingsText.email, value: email)
                }
            }
            Section {
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
                }
            } header: {
                Text(SettingsText.devices)
            } footer: {
                if !model.devicesConnection.isLive {
                    Text(SettingsText.devicesOffline)
                }
            }
            if !model.links.isEmpty {
                Section {
                    ForEach(model.links) { link in
                        NavigationLink {
                            link.destination()
                        } label: {
                            Label(link.title, systemImage: link.systemImage)
                        }
                        .accessibilityIdentifier("shell.settings." + link.id)
                    }
                }
            }
            if let developer = model.developer {
                Section {
                    NavigationLink(SettingsText.developer) {
                        DevSourcesView(model: developer())
                    }
                    .accessibilityIdentifier("shell.settings.developer")
                }
            }
            Section(SettingsText.about) {
                LabeledContent(SettingsText.version, value: model.about.summary)
            }
            Section {
                Button(SettingsText.signOut, role: .destructive) { confirmingSignOut = true }
                    .disabled(model.isSigningOut)
                    .accessibilityIdentifier("shell.settings.signOut")
            }
        }
        .navigationTitle(ShellTab.settings.title)
        .task { await model.observeDevices() }
        .confirmationDialog(SettingsText.signOutConfirm, isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button(SettingsText.signOut, role: .destructive) {
                Task { await model.signOut() }
            }
        }
    }
}
