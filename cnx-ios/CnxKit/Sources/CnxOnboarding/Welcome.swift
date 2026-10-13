#if os(iOS)
import CnxAuth
import CnxDesign
import SwiftUI

private let theme = CnxTheme.standard

/// The launch screen's mark, re-drawn as the first SwiftUI frame so the handoff
/// is seamless (SPEC 5.1): same 72 pt mark, same center, on `bg`.
public struct LaunchMarkView: View {
    public init() {}

    public var body: some View {
        CmuxMark()
            .fill(theme.colors.label)
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
    }
}

/// Signed-out welcome (SPEC 5.2): animated hero, headline, four sign-in pills,
/// legal footer. No carousel.
public struct WelcomeView: View {
    let auth: CnxAuthModel
    @State private var showsEmail = false
    @State private var buttonsVisible = false
    @Environment(\.colorScheme) private var colorScheme

    let initialEmail: String?

    /// `initialEmail` (DEBUG verification) opens the email sheet on the code step.
    public init(auth: CnxAuthModel, initialEmail: String? = nil) {
        self.auth = auth
        self.initialEmail = initialEmail
    }

    public var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                WelcomeHero()
                    .frame(height: proxy.size.height * 0.48)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Macs, in your pocket.")
                        .font(theme.type.heroTitle)
                        .foregroundStyle(theme.colors.label)
                    Text("Run agents, terminals and workspaces from anywhere.")
                        .font(theme.type.body)
                        .foregroundStyle(theme.colors.label2)
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                Spacer(minLength: 16)
                buttons
                    .padding(.horizontal, theme.metrics.sideMargin)
                if let error = auth.errorMessage {
                    Text(error)
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.danger)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, theme.metrics.sideMargin)
                        .transition(.opacity)
                }
                legal
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            }
        }
        .background(theme.colors.bg.color.ignoresSafeArea())
        .sheet(isPresented: $showsEmail) {
            EmailSignInSheet(auth: auth, initialEmail: initialEmail)
        }
        .task {
            // Buttons arrive once the hero's first line has typed (max 400 ms).
            try? await Task.sleep(for: .milliseconds(400))
            buttonsVisible = true
            // DEBUG verification opens the sheet the way a tap would, once the
            // welcome screen is on screen.
            if initialEmail != nil { showsEmail = true }
        }
        .cnxSensoryFeedback(.error, trigger: auth.errorMessage)
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            if DemoDirector.shared.command == .onboardingOpenEmail { showsEmail = true }
        }
        .task {
            if OnboardingDemoScript.isRequested { OnboardingDemoScript.start() }
        }
        #endif
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            ProviderButton(title: "Continue with Apple", index: 0, visible: buttonsVisible, isBusy: auth.busyProvider == .apple, kind: .apple) {
                Image(systemName: "apple.logo").font(.system(size: 19, weight: .medium))
            } action: { Task { await auth.signIn(with: .apple) } }
            ProviderButton(title: "Continue with Google", index: 1, visible: buttonsVisible, isBusy: auth.busyProvider == .google, kind: .provider) {
                Image("GoogleLogo", bundle: .module).resizable().frame(width: 18, height: 18)
            } action: { Task { await auth.signIn(with: .google) } }
            ProviderButton(title: "Continue with GitHub", index: 2, visible: buttonsVisible, isBusy: auth.busyProvider == .github, kind: .provider) {
                Image("GitHubLogo", bundle: .module).renderingMode(.template).resizable().frame(width: 18, height: 18)
            } action: { Task { await auth.signIn(with: .github) } }
            ProviderButton(title: "Continue with email", index: 3, visible: buttonsVisible, isBusy: false, kind: .provider) {
                Image(systemName: "envelope").font(.system(size: 17, weight: .medium))
            } action: { showsEmail = true }
        }
        .disabled(auth.isBusy)
    }

    private var legal: some View {
        Text("By continuing, you agree to the [Terms](https://cmux.com/terms) and [Privacy Policy](https://cmux.com/privacy).")
            .font(theme.type.legal)
            .foregroundStyle(theme.colors.label3)
            .tint(theme.colors.label2.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, theme.metrics.sideMargin)
            .environment(\.openURL, OpenURLAction { _ in .systemAction })
    }
}

/// A 52 pt sign-in pill. Apple's is solid `label` (white in dark), the others
/// use the provider capsule style. Busy shows a spinner in place of the icon.
private struct ProviderButton<Icon: View>: View {
    enum Kind { case apple, provider }

    let title: LocalizedStringKey
    let index: Int
    let visible: Bool
    let isBusy: Bool
    let kind: Kind
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    icon().opacity(isBusy ? 0 : 1)
                    if isBusy { ProgressView().tint(kind == .apple ? theme.colors.onAccent.color : theme.colors.label.color) }
                }
                .frame(width: 22)
                Text(title)
            }
        }
        .buttonStyle(ProviderStyle(isApple: kind == .apple))
        .opacity(isEnabled || isBusy ? 1 : 0.5)
        .opacity(visible ? 1 : 0)
        .offset(y: visible || reduceMotion ? 0 : 12)
        .animation(theme.motion.snappy.animation.delay(Double(index) * theme.motion.staggerStep), value: visible)
    }
}

private struct ProviderStyle: ButtonStyle {
    let isApple: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.type.cta)
            .foregroundStyle(isApple ? theme.colors.onAccent : theme.colors.label)
            .frame(maxWidth: .infinity)
            .frame(height: theme.metrics.ctaLargeHeight)
            .background(isApple ? AnyShapeStyle(theme.colors.accent) : (colorScheme == .dark ? AnyShapeStyle(theme.colors.surface) : AnyShapeStyle(theme.colors.fill)), in: .capsule)
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(theme.motion.snap.animation, value: configuration.isPressed)
    }
}

/// Monochrome "conversation" hero: mono terminal lines type in, then a user
/// bubble and an assistant line appear. Loops every 6 s; static under Reduce Motion.
struct WelcomeHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private let lines = ["$ cmux attach studio", "claude  feat-cnx-ios  working", "14 tests passed"]
    private let charsPerSecond = 35.0
    private let loop = 6.0

    var body: some View {
        VStack(spacing: 24) {
            CmuxMark()
                .fill(theme.colors.label)
                .frame(width: 40, height: 40)
            if reduceMotion {
                frame(at: loop - 0.5)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    frame(at: context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: loop))
                }
            }
        }
        .padding(.horizontal, theme.metrics.sideMargin + 8)
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }

    private func frame(at t: Double) -> some View {
        var cursor = 0.2
        var typed: [String] = []
        for line in lines {
            let duration = Double(line.count) / charsPerSecond
            let count = Int(max(0, min(Double(line.count), (t - cursor) * charsPerSecond)))
            typed.append(String(line.prefix(count)))
            cursor += duration + 0.25
        }
        let bubbleAt = cursor + 0.2
        let replyAt = bubbleAt + 0.7
        let fadeOut = t > loop - 0.4 ? (loop - t) / 0.4 : 1
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(typed.enumerated()), id: \.offset) { index, text in
                    HStack(spacing: 6) {
                        if index == 1, !text.isEmpty { Circle().fill(theme.colors.label2).frame(width: 6, height: 6) }
                        if index == 2, !text.isEmpty { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        Text(text.isEmpty ? " " : text)
                    }
                    .font(theme.type.codeBody)
                    .foregroundStyle(theme.colors.label2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.codeBg, in: .rect(cornerRadius: theme.metrics.cardRadius, style: .continuous))
            Text("Ship the transport switch")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(theme.colors.bubble, in: .rect(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(t > bubbleAt ? 1 : 0)
                .offset(y: t > bubbleAt ? 0 : 8)
                .animation(theme.motion.snappy.animation, value: t > bubbleAt)
            Text("Done. Both dialers are in, and the PR is open.")
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .opacity(t > replyAt ? 1 : 0)
                .animation(theme.motion.smooth.animation, value: t > replyAt)
        }
        .opacity(fadeOut)
    }
}
#endif
