import CmuxFeedPushCore
import CmuxiOSSettingsCore
import SwiftUI
import UIKit

/// Settings > Notifications: the system permission, then which pushes this
/// device wants. The push owner filters by these once lane C7 syncs them.
struct NotificationSettingsView: View {
    let store: NotificationPreferencesStore
    let authorization: (any NotificationAuthorizationReading)?
    @State private var status: NotificationAuthorization?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if let authorization {
                Section {
                    statusRow(authorization)
                } footer: {
                    if status == .denied { Text(SettingsText.notificationsDeniedFooter) }
                }
            }
            Section {
                ForEach(NotificationKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { store.preferences.isEnabled(kind) },
                        set: { enabled in store.update { $0.set(kind, enabled: enabled) } }
                    )) {
                        Text(SettingsText.title(of: kind))
                        Text(SettingsText.detail(of: kind))
                    }
                    .accessibilityIdentifier("shell.settings.notify." + kind.rawValue)
                }
            } header: {
                Text(SettingsText.notifyAbout)
            } footer: {
                Text(SettingsText.syncFooter(store.syncState))
            }
            Section {
                Toggle(SettingsText.notifySound, isOn: Binding(
                    get: { store.preferences.sound }, set: { value in store.update { $0.sound = value } }))
                Toggle(isOn: Binding(
                    get: { store.preferences.timeSensitive }, set: { value in store.update { $0.timeSensitive = value } })) {
                    Text(SettingsText.timeSensitive)
                    Text(SettingsText.timeSensitiveDetail)
                }
            }
        }
        .navigationTitle(SettingsText.notifications)
        .task { status = await authorization?.status() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { status = await authorization?.status() }
        }
    }

    @ViewBuilder private func statusRow(_ authorization: any NotificationAuthorizationReading) -> some View {
        switch status {
        case .authorized:
            LabeledContent(SettingsText.systemNotifications, value: SettingsText.allowed)
        case .denied:
            LabeledContent(SettingsText.systemNotifications, value: SettingsText.off)
            Button(SettingsText.openIOSSettings) {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
        case .notDetermined:
            Button(SettingsText.turnOnNotifications) {
                Task { status = await authorization.request() }
            }
        case nil:
            LabeledContent(SettingsText.systemNotifications) { ProgressView() }
        }
    }
}
