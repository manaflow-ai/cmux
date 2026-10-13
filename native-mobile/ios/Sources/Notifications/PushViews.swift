import SwiftUI
import UIKit

extension View {
    /// Push wiring for the root view: the permission pre-prompt after the
    /// first Mac connects, presence reports to the Mac, Live Activity links,
    /// and token upload after sign-in.
    func pushNotifications(app: AppModel) -> some View {
        modifier(PushRootModifier(app: app))
    }

    /// Consumes notification and Live Activity taps: switches to the right
    /// Mac and opens the agent's terminal (or the feed).
    func pushDeepLinks(app: AppModel, navigator: AppNavigator) -> some View {
        modifier(PushDeepLinkModifier(app: app, navigator: navigator))
    }
}

private struct PushRootModifier: ViewModifier {
    let app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var push = PushManager.shared

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in _ = push.handle(url: url) }
            .onChange(of: connectedHost) { _, host in
                guard host != nil else { return }
                push.considerPrePrompt()
                reportPresence()
            }
            .onChange(of: scenePhase) { _, _ in reportPresence() }
            .onChange(of: app.phase) { _, phase in
                if phase == .ready { Task { await push.uploadRegistration() } }
            }
            .sheet(isPresented: $push.showPrePrompt) {
                PushPrePromptSheet(push: push)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }

    private var connectedHost: String? {
        guard let connection = app.connection, connection.phase == .connected else { return nil }
        return connection.host.id
    }

    private func reportPresence() {
        push.reportPresence(visible: scenePhase == .active, connection: app.connection)
    }
}

private struct PushDeepLinkModifier: ViewModifier {
    let app: AppModel
    let navigator: AppNavigator
    @State private var push = PushManager.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: push.pendingDeepLink, initial: true) { _, link in
                guard let link else { return }
                push.pendingDeepLink = nil
                if app.connection?.host.id != link.hostID, let host = app.hosts.first(where: { $0.id == link.hostID }) {
                    navigator.hostChanged()
                    app.connect(host)
                }
                if let surface = link.surface {
                    navigator.select(.terminal(surface: surface), hostID: link.hostID)
                } else {
                    navigator.select(.feed, hostID: link.hostID)
                }
            }
    }
}

/// Asks before the system alert (Claude and ChatGPT do the same): what the
/// notifications are for, with a sample.
struct PushPrePromptSheet: View {
    let push: PushManager
    @State private var liveActivities = PushManager.shared.liveActivitiesEnabled

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.primary)
                    .padding(.top, 36)
                Text(String(localized: "Know when an agent needs you"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(String(localized: "cmux tells you when an agent on your Mac asks a question, wants permission or finishes, even when the app is closed. Answer right from the notification."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SampleNotification()
            Toggle(isOn: $liveActivities) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Live Activities"))
                    Text(String(localized: "Show running agents on the Lock Screen and in the Dynamic Island."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color(white: 0.45))
            .onChange(of: liveActivities) { _, on in push.liveActivitiesEnabled = on }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    Task { await push.answerPrePrompt(enable: true) }
                } label: {
                    Text(String(localized: "Turn On Notifications"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Capsule().fill(Color.primary))
                }
                .accessibilityIdentifier("push.enable")
                Button(String(localized: "Not Now")) {
                    Task { await push.answerPrePrompt(enable: false) }
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("push.notNow")
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }
}

private struct SampleNotification: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "chevron.forward").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(uiColor: .systemBackground)))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(String(localized: "Claude needs your input")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(localized: "now")).font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: "Claude · cmux").font(.caption).foregroundStyle(.secondary)
                Text(String(localized: "Do you want to make this edit to router.ts?"))
                    .font(.subheadline)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        .accessibilityElement(children: .combine)
    }
}

/// The Live Activities switch for Settings (mirrors Codex's setting).
struct LiveActivitiesToggle: View {
    @State private var on = PushManager.shared.liveActivitiesEnabled

    var body: some View {
        Toggle(String(localized: "Live Activities"), isOn: $on)
            .tint(Color(white: 0.45))
            .onChange(of: on) { _, value in PushManager.shared.liveActivitiesEnabled = value }
            .accessibilityIdentifier("settings.liveActivities")
    }
}
