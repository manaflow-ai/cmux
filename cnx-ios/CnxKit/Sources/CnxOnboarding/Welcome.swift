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

/// Signed-out welcome (SPEC 5.2): the cmux mark and one line, centered above
/// the sign-in stack (ChatGPT / Claude composition), legal footer. On a cold
/// launch the mark starts exactly where the launch screen left it and glides up
/// into place while it takes the app icon's gradient.
public struct WelcomeView: View {
    let auth: CnxAuthModel
    let initialEmail: String?
    @State private var showsEmail = false
    /// The mark has left the launch position (drives every intro animation).
    @State private var settled: Bool
    /// The intro overlay has landed; the in-layout hero mark takes over.
    @State private var introDone: Bool
    @State private var screenMidY: CGFloat = 0
    @State private var heroMarkMidY: CGFloat = 0
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `playsLaunchIntro`: the welcome replaces the launch screen (cold launch);
    /// false after sign-out, where the root crossfades it in.
    /// `initialEmail` (DEBUG verification) opens the email sheet on the code step.
    public init(auth: CnxAuthModel, playsLaunchIntro: Bool = true, initialEmail: String? = nil) {
        self.auth = auth
        self.initialEmail = initialEmail
        _settled = State(initialValue: !playsLaunchIntro)
        _introDone = State(initialValue: !playsLaunchIntro)
    }

    public var body: some View {
        ZStack {
            // Full-screen, like the launch screen whose mark the intro continues.
            theme.colors.bg.color.ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { y in
                    screenMidY = y
                    startIntroIfReady()
                }
            VStack(spacing: 0) {
                hero
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .opacity(settled ? 1 : 0)
                    .animation(theme.motion.gentle.animation.delay(0.45), value: settled)
            }
            if !introDone { introMark }
        }
        .sheet(isPresented: $showsEmail) {
            EmailSignInSheet(auth: auth, initialEmail: initialEmail)
        }
        .onAppear {
            if introDone { finishIntro() }
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

    // MARK: Hero

    private static let markSize: CGFloat = 60
    private static let launchMarkSize: CGFloat = 72

    private var hero: some View {
        VStack(spacing: 30) {
            WelcomeMark(gradient: 1, glow: breathe ? 1 : 0.6)
                .frame(width: Self.markSize, height: Self.markSize)
                .opacity(introDone || (reduceMotion && settled) ? 1 : 0)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { y in
                    heroMarkMidY = y
                    startIntroIfReady()
                }
            Text("Your Macs, in your pocket.")
                .font(theme.type.heroTitle)
                .foregroundStyle(theme.colors.label)
                .multilineTextAlignment(.center)
                .padding(.horizontal, theme.metrics.sideMargin)
                .opacity(settled ? 1 : 0)
                .blur(radius: settled || reduceMotion ? 0 : 6)
                .offset(y: settled || reduceMotion ? 0 : 10)
                .animation(theme.motion.gentle.animation.delay(reduceMotion ? 0 : 0.22), value: settled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The launch mark, at the launch screen's size and position on the first
    /// frame, gliding to the hero slot.
    private var introMark: some View {
        let delta = heroMarkMidY - screenMidY
        let moves = settled && !reduceMotion
        return WelcomeMark(gradient: settled ? 1 : 0, glow: settled ? 0.6 : 0, opaqueBase: true)
            .frame(width: Self.launchMarkSize, height: Self.launchMarkSize)
            .scaleEffect(moves ? Self.markSize / Self.launchMarkSize : 1)
            .offset(y: moves ? delta : 0)
            .opacity(reduceMotion && settled ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func startIntroIfReady() {
        guard !settled, screenMidY > 0, heroMarkMidY > 0 else { return }
        let animation = reduceMotion ? theme.motion.snap.animation : Animation.spring(duration: 0.7, bounce: 0).delay(0.12)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            settled = true
        } completion: {
            introDone = true
            finishIntro()
        }
    }

    private func finishIntro() {
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { breathe = true }
        }
        // DEBUG verification opens the sheet the way a tap would.
        if initialEmail != nil, !showsEmail { showsEmail = true }
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            ProviderButton(title: "Continue with Apple", index: 0, visible: settled, isBusy: auth.busyProvider == .apple, kind: .apple) {
                Image(systemName: "apple.logo").font(.system(size: 19, weight: .medium))
            } action: { Task { await auth.signIn(with: .apple) } }
            ProviderButton(title: "Continue with Google", index: 1, visible: settled, isBusy: auth.busyProvider == .google, kind: .provider) {
                Image("GoogleLogo", bundle: .module).resizable().frame(width: 18, height: 18)
            } action: { Task { await auth.signIn(with: .google) } }
            ProviderButton(title: "Continue with GitHub", index: 2, visible: settled, isBusy: auth.busyProvider == .github, kind: .provider) {
                Image("GitHubLogo", bundle: .module).renderingMode(.template).resizable().frame(width: 18, height: 18)
            } action: { Task { await auth.signIn(with: .github) } }
            ProviderButton(title: "Continue with email", index: 3, visible: settled, isBusy: false, kind: .provider) {
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

/// The cmux chevron. `gradient` 0 is the monochrome launch mark (`label`),
/// 1 is the app icon's cyan-to-indigo gradient with a soft glow (`glow` 0...1).
/// `opaqueBase` keeps the `label` chevron fully under the gradient so a
/// crossfade never turns the mark translucent.
struct WelcomeMark: View {
    var gradient: Double
    var glow: Double
    var opaqueBase = false
    @Environment(\.colorScheme) private var colorScheme

    /// Sampled from `AppIcon.icon` (leading edge to the chevron tip).
    private static let iconGradient = LinearGradient(
        colors: [Color(hex: "#06CDFE"), Color(hex: "#2AA0F9"), Color(hex: "#5170F3")],
        startPoint: .leading, endPoint: .trailing
    )

    var body: some View {
        ZStack {
            CmuxMark().fill(theme.colors.label).opacity(opaqueBase ? 1 : 1 - gradient)
            CmuxMark()
                .fill(Self.iconGradient)
                .shadow(color: Color(hex: "#2AA0F9").opacity((colorScheme == .dark ? 0.55 : 0.3) * glow), radius: 10 + 8 * glow)
                .opacity(gradient)
        }
        .accessibilityHidden(true)
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
        .animation(theme.motion.snappy.animation.delay(0.3 + Double(index) * theme.motion.staggerStep), value: visible)
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
#endif
