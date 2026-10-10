#if os(iOS)
import CNAuthUI
import CNDesign
import CNSettingsUI
import SwiftUI

/// The app's root: restoring -> sign-in -> onboarding -> the selected shell.
/// DEBUG `CMUX_NEXT_DEV_SCREEN` short-circuits to one root on the mock host.
public struct AppRoot: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        content
            .preferredColorScheme(model.preferences.appearance.colorScheme)
            .environment(\.cnTerminalFontSize, CGFloat(model.preferences.terminalFontSize))
            .task { await model.start() }
            .task(id: model.auth.state) { await model.authStateChanged() }
            .onChange(of: model.preferences.forceRelay) { model.forceRelayChanged() }
            .onChange(of: model.hosts.hosts) { model.reconcileSelection() }
            .onOpenURL { model.handleOpenURL($0) }
            .onCNStatusBarStyleChange { [model] style in
                // The drawer forwards its content's request itself.
                if model.devScreen != nil || model.shell == .tabs || model.phase != .ready { model.statusBarStyle = style }
            }
    }

    @ViewBuilder
    private var content: some View {
        let roots = ModuleRoots(model: model)
        switch model.devScreen {
        case .conversations: roots.conversations()
        case .agents: roots.agents()
        case .terminal: roots.terminals()
        case .browser: roots.browser()
        case .settings: roots.settings()
        default: flow
        }
    }

    @ViewBuilder
    private var flow: some View {
        ZStack {
            switch model.phase {
            case .restoring, .signedOut:
                SignInView(controller: model.signIn, initialMode: Self.debugSignInMode, initialEmail: Self.debugSignInEmail,
                           notice: model.signInNotice)
                    .transition(.opacity)
            case .loadingHosts:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.cn(\.background))
            case .onboarding:
                OnboardingView(model: model)
                    .transition(.opacity)
            case .ready:
                Group {
                    switch model.shell {
                    case .drawer: DrawerShell(model: model)
                    case .tabs: TabsShell(model: model)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(CNTheme.shared.motion.fade, value: model.phase)
    }

    /// DEBUG captures: `CMUX_NEXT_SIGNIN_MODE=methods|code|emailVerification`.
    private static var debugSignInMode: SignInMode {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_NEXT_SIGNIN_MODE"].flatMap(SignInMode.init(rawValue:)) ?? .methods
        #else
        .methods
        #endif
    }

    private static var debugSignInEmail: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_NEXT_SIGNIN_EMAIL"] ?? ""
        #else
        ""
        #endif
    }
}
#endif
