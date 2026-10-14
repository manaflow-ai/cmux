#if os(iOS)
import CnxAuth
import CnxDesign
import CnxModel
import SwiftUI
import UIKit
import UserNotifications

private let theme = CnxTheme.standard

extension View {
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, theme.metrics.settingsRowHeight)
            .scrollContentBackground(.hidden)
            .background(theme.colors.bgGrouped.color.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountPage: View {
    let auth: CnxAuthModel
    let directory: (any SettingsDeviceDirectory)?
    @State private var confirmsDeletion = false
    @State private var deleting = false
    @State private var deletionError: String?

    var body: some View {
        List {
            if let user = auth.user {
                Section {
                    HStack(spacing: 14) {
                        UserInitials(user.initials, size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name).font(theme.type.rowTitle.weight(.semibold))
                            if let email = user.email { Text(email).font(theme.type.meta).foregroundStyle(theme.colors.label2) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Name") { Text(user.name) }
                Section("Email") { Text(user.email ?? "No email") }
            }
            Section {
                Text("Sign-in methods are managed by the cmux sign-in service. Linked Apple, Google, GitHub and email methods show here once account details sync.")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
            } header: {
                Text("Sign-in methods")
            }
            Section {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    HStack {
                        Text("Delete Account").foregroundStyle(theme.colors.danger)
                        if deleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(deleting)
                .accessibilityIdentifier("settings.deleteAccount")
            } footer: {
                Text("Deletes your cmux account and its data for every cmux app, and removes your Macs and phones from the cmux service. This can't be undone.")
            }
        }
        .settingsPage("Account")
        .confirmationDialog("Delete your cmux account?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Your cmux account is used by every cmux app (Mac, iPhone and web). Deleting it signs you out everywhere, removes your Macs and phones from the cmux service and permanently deletes your account. This can't be undone.")
        }
        .alert("Account not deleted", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        var purge: (@MainActor () async throws -> Void)?
        if let directory {
            purge = { try await directory.deleteAccountData() }
        }
        do {
            try await auth.deleteAccount(purgeServiceData: purge)
        } catch let error as CnxAuthModel.AccountDeletionError {
            deletionError = error.message
        } catch {
            deletionError = "Your account couldn't be deleted. Try again."
        }
    }
}

struct TeamPage: View {
    let team: Team
    let user: CnxAuthModel.User?
    let edit: () -> Void
    let invite: () -> Void

    var body: some View {
        List {
            Section {
                Button(action: edit) {
                    HStack(spacing: 14) {
                        TeamAvatar(name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji, size: 28)
                        Text("Color and icon").font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.colors.label3)
                    }
                }
            } footer: {
                Text("Color and icon are yours only; teammates choose their own.")
            }
            Section("Members") {
                if let user {
                    HStack(spacing: 14) {
                        UserInitials(user.initials, size: 28)
                        Text(user.name).font(theme.type.rowTitle)
                        Spacer()
                        Text("You").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                    }
                }
            }
            Section {
                Button(action: invite) {
                    SettingsLabel("Invite to team", symbol: "person.badge.plus")
                }
            }
        }
        .settingsPage(LocalizedStringKey(team.name))
    }
}

struct TerminalPage: View {
    let settings: SettingsStore
    private let themes = ["Follow Mac", "Ghostty Default", "Catppuccin Mocha", "Gruvbox Dark", "Solarized Light", "Tokyo Night"]

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Stepper(value: $settings.terminalFontSize, in: 9...24) {
                    SettingsLabel("Font size", symbol: "textformat.size", value: "\(settings.terminalFontSize) pt")
                }
                Text(verbatim: "~/cmux $ swift build")
                    .font(.system(size: CGFloat(settings.terminalFontSize), design: .monospaced))
                    .foregroundStyle(Color(hex: "#DCDFE4"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(hex: "#282C34"), in: .rect(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            Section("Theme") {
                Picker("Theme", selection: $settings.terminalTheme) {
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Code") {
                Toggle(isOn: $settings.wrapCode) { SettingsLabel("Wrap code and diff lines", symbol: "text.word.spacing") }
                Toggle(isOn: $settings.keyClicks) { SettingsLabel("Key clicks", symbol: "keyboard") }
            }
        }
        .settingsPage("Terminal")
    }
}

struct ComposerPage: View {
    let settings: SettingsStore

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle(isOn: $settings.dismissKeyboardAfterSend) {
                    SettingsLabel("Dismiss keyboard after sending", symbol: "keyboard.chevron.compact.down")
                }
                Picker(selection: $settings.followUp) {
                    ForEach(FollowUpBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("Follow-up while running", symbol: "arrow.turn.down.right")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Queue sends after the current turn. Steer interrupts the agent.")
            }
        }
        .settingsPage("Composer")
    }
}

struct NotificationsPage: View {
    let settings: SettingsStore
    @State private var status: UNAuthorizationStatus?
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Button {
                    if status == .notDetermined {
                        Task {
                            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                            if granted { UIApplication.shared.registerForRemoteNotifications() }
                            await refresh()
                        }
                    } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        SettingsLabel("Allow notifications", symbol: "bell.badge")
                        Spacer()
                        Text(statusText).foregroundStyle(theme.colors.label2)
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.notifyQuestions) { SettingsLabel("Questions and permissions", symbol: "questionmark.bubble") }
                Toggle(isOn: $settings.notifyFinished) { SettingsLabel("Finished tasks", symbol: "checkmark.circle") }
                Toggle(isOn: $settings.notifyErrors) { SettingsLabel("Errors", symbol: "exclamationmark.triangle") }
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Your Macs send these through the cmux service. A notification names the agent and workspace only, never what the agent wrote.")
            }
        }
        .settingsPage("Notifications")
        .task { await refresh() }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        case .notDetermined: "Not set"
        default: ""
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

struct AcknowledgementsPage: View {
    var body: some View {
        List {
            Section {
                Text("Ghostty (MIT)")
                Text("Stack Auth Swift SDK (MIT)")
                Text("swift-crypto (Apache 2.0)")
            }
        }
        .settingsPage("Acknowledgements")
    }
}
#endif
