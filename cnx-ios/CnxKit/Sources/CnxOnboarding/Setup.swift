#if os(iOS)
import CnxAuth
import CnxDesign
import CnxModel
import SwiftUI
import UserNotifications

private let theme = CnxTheme.standard

/// First-run setup after sign-in (SPEC 5.5). Each step is a full page pushed in
/// a `NavigationStack`; progress is implicit.
public struct SetupFlow: View {
    /// A setup step.
    public enum Step: Hashable, Sendable {
        case team, pairMac, notifications
    }

    let steps: [Step]
    let auth: CnxAuthModel
    let store: AppStore
    let finish: () -> Void
    @State private var path: [Step] = []

    public init(steps: [Step], auth: CnxAuthModel, store: AppStore, finish: @escaping () -> Void) {
        self.steps = steps
        self.auth = auth
        self.store = store
        self.finish = finish
    }

    public var body: some View {
        NavigationStack(path: $path) {
            page(steps.first ?? .notifications)
                .navigationDestination(for: Step.self) { page($0) }
        }
        .tint(theme.colors.label.color)
    }

    @ViewBuilder private func page(_ step: Step) -> some View {
        switch step {
        case .team: TeamStep(auth: auth, store: store, next: { advance(from: .team) })
        case .pairMac: PairMacStep(email: auth.user?.email, store: store, next: { advance(from: .pairMac) })
        case .notifications: NotificationsStep(next: { advance(from: .notifications) })
        }
    }

    private func advance(from step: Step) {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            finish()
            return
        }
        path.append(steps[index + 1])
    }
}

private struct SetupPage<Content: View, Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(theme.colors.label)
                .frame(maxWidth: .infinity)
            Text(title)
                .font(theme.type.heroTitle)
                .foregroundStyle(theme.colors.label)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            content().padding(.top, 28)
            Spacer(minLength: 24)
            VStack(spacing: 10) { actions() }
                .padding(.bottom, 8)
        }
        .padding(.horizontal, theme.metrics.sideMargin)
        .background(theme.colors.bg.color.ignoresSafeArea())
    }
}

private struct ExplainerRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 22)
                .foregroundStyle(theme.colors.label)
            Text(text)
                .font(theme.type.body)
                .foregroundStyle(theme.colors.label)
        }
        .padding(.vertical, 8)
    }
}

/// Pick a team when there are several, or create the first one.
private struct TeamStep: View {
    let auth: CnxAuthModel
    let store: AppStore
    let next: () -> Void
    @State private var name = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        if store.teams.isEmpty {
            SetupPage(symbol: "person.2", title: "Create your team") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Team name", text: $name)
                        .font(theme.type.body)
                        .cnxInputField()
                    if let error { Text(error).font(theme.type.meta).foregroundStyle(theme.colors.danger) }
                }
            } actions: {
                PrimaryCapsule("Create team", isLoading: isCreating) { create() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Choose a team")
                    .font(theme.type.heroTitle)
                    .padding(.horizontal, theme.metrics.sideMargin)
                    .padding(.top, 12)
                Text("You can switch teams any time from the sidebar.")
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
                    .padding(.horizontal, theme.metrics.sideMargin)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.teams) { team in
                            let presence = team.macDots()
                            Button {
                                pick(team)
                            } label: {
                                SidebarTeamRow(
                                    name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji,
                                    dots: presence.dots, overflow: presence.overflow,
                                    onlineCount: team.macs.filter(\.isOnline).count, isSelected: false
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, theme.metrics.selectedRowInset)
                        }
                    }
                }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            #if DEBUG
            .onChange(of: DemoDirector.shared.serial) {
                if case .setupPickTeam(let index) = DemoDirector.shared.command, store.teams.indices.contains(index) {
                    pick(store.teams[index])
                }
            }
            #endif
        }
    }

    private func pick(_ team: Team) {
        store.selectTeam(team.id)
        theme.haptics.selection()
        Task { await auth.selectTeam(team.id) }
        next()
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                let team = try await auth.createTeam(named: name)
                store.applyAccountTeams([team], selectedID: team.id)
                theme.haptics.success()
                next()
            } catch {
                self.error = CnxAuthModel.message(for: error) ?? "Couldn't create the team."
                theme.haptics.error()
            }
        }
    }
}

/// "Connect your Mac": no pairing code. A Mac signed in to the same account
/// and team with iPhone connections allowed appears by itself; the status
/// line flips when presence reports it, and Continue appears.
private struct PairMacStep: View {
    let email: String?
    let store: AppStore
    let next: () -> Void

    private var onlineMac: String? {
        store.activeTeam?.macs.first(where: \.isOnline)?.name
    }

    var body: some View {
        SetupPage(symbol: "desktopcomputer", title: "Connect your Mac") {
            ConnectMacSteps(email: email, onlineMac: onlineMac)
        } actions: {
            if onlineMac != nil {
                PrimaryCapsule("Continue", action: next)
            } else {
                TextCTA("Not now", action: next)
            }
        }
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { if DemoDirector.shared.command == .setupNotNow { next() } }
        #endif
    }
}

/// Notification priming before the system prompt.
private struct NotificationsStep: View {
    let next: () -> Void

    var body: some View {
        SetupPage(symbol: "bell.badge", title: "Know when an agent needs you") {
            VStack(alignment: .leading, spacing: 4) {
                ExplainerRow(symbol: "questionmark.bubble", text: "Questions and permission requests")
                ExplainerRow(symbol: "checkmark.circle", text: "Finished tasks")
                ExplainerRow(symbol: "livephoto", text: "Live Activities for running agents")
            }
        } actions: {
            PrimaryCapsule("Turn on notifications") {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                    next()
                }
            }
            TextCTA("Not now", action: next)
        }
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { if DemoDirector.shared.command == .setupNotNow { next() } }
        #endif
    }
}
#endif
