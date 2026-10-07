import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import SwiftUI

/// The Settings tab (plans/cmux-next/ios-next/c11-settings.md section 1):
/// Account, Devices & Macs, Preferences, Help, About, Developer (DEBUG) and
/// Delete Account last. A low-frequency form, so SwiftUI.
struct ShellSettingsView: View {
    @Bindable var model: ShellSettingsModel
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            if let signIn = model.signIn {
                GuestAccountSection(signIn: signIn)
            } else {
                AccountSection(model: model, confirmingSignOut: $confirmingSignOut)
            }
            if let devicesModel = model.devicesModel {
                DevicesSection(model: devicesModel)
            }
            preferences
            help
            AboutSection(about: model.about)
            if let developer = model.developer {
                Section {
                    NavigationLink(SettingsText.developer) {
                        DevSourcesView(model: developer())
                    }
                    .accessibilityIdentifier("shell.settings.developer")
                }
            }
            if let account = model.accountModel {
                DeleteAccountSection(model: account)
            }
            if model.eraseAllData != nil {
                EraseAllDataSection { [model] in model.makeEraseModel() }
            }
        }
        .navigationTitle(ShellTab.settings.title)
        .navigationDestination(item: $model.openedPage) { page in
            destination(page)
        }
        .task { await model.observe() }
        .confirmationDialog(SettingsText.signOutConfirm, isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button(SettingsText.signOut, role: .destructive) {
                Task { await model.signOut() }
            }
        }
    }

    /// The page `openedPage` pushes; a page this build lacks shows nothing.
    @ViewBuilder private func destination(_ page: ShellSettingsPage) -> some View {
        switch page {
        case .terminal:
            if let terminal = model.terminal { TerminalSettingsView(store: terminal) }
        case .notifications:
            if let notifications = model.notifications {
                NotificationSettingsView(store: notifications, authorization: model.notificationAuthorization)
            }
        case .privacy:
            if let privacy = model.privacy { PrivacySettingsView(privacy: privacy) }
        }
    }

    @ViewBuilder private var preferences: some View {
        if model.terminal != nil || model.notifications != nil || model.privacy != nil || model.haptics != nil {
            Section(SettingsText.preferences) {
                if let terminal = model.terminal {
                    NavigationLink {
                        TerminalSettingsView(store: terminal)
                    } label: {
                        Label(SettingsText.terminal, systemImage: "terminal")
                    }
                    .accessibilityIdentifier("shell.settings.terminal")
                }
                if let notifications = model.notifications {
                    NavigationLink {
                        NotificationSettingsView(store: notifications, authorization: model.notificationAuthorization)
                    } label: {
                        Label(SettingsText.notifications, systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("shell.settings.notifications")
                }
                if let haptics = model.haptics {
                    HapticsRow(haptics: haptics)
                }
                if let privacy = model.privacy {
                    NavigationLink {
                        PrivacySettingsView(privacy: privacy)
                    } label: {
                        Label(SettingsText.privacy, systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("shell.settings.privacy")
                }
            }
        }
    }

    @ViewBuilder private var help: some View {
        if !model.links.isEmpty || model.replayTour != nil {
            Section(SettingsText.help) {
                ForEach(model.links) { link in
                    NavigationLink {
                        link.destination()
                    } label: {
                        Label(link.title, systemImage: link.systemImage)
                    }
                    .accessibilityIdentifier("shell.settings." + link.id)
                }
                if let replayTour = model.replayTour {
                    Button {
                        replayTour()
                    } label: {
                        Label(SettingsText.replayTour, systemImage: "play.circle")
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("shell.settings.replayTour")
                }
            }
        }
    }
}
