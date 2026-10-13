#if os(iOS)
import CnxAuth
import CnxDesign
import SwiftUI
#if DEBUG
import os

private let welcomeLog = Logger(subsystem: "dev.cmux.cnx", category: "welcome")
#endif

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

/// Signed-out welcome (SPEC 5.2), composed like Claude's: the cmux lockup at
/// the top, an illustration and one serif line in the middle, the sign-in
/// stack and legal footer at the bottom. On a cold launch it plays a ~5 s intro
/// on one clock: the launch mark glides into the lockup while the text and
/// buttons fade in (usable within 0.3 s), then the illustration draws itself.
/// Afterwards it rests; a short sync pulse runs now and then.
public struct WelcomeView: View {
    let auth: CnxAuthModel
    let initialEmail: String?
    @State private var showsEmail = false
    /// The intro has started (the lockup slot is measured).
    @State private var started: Bool
    /// The timeline runs only while something moves.
    @State private var animating = true
    @State private var pulseStart: Date?
    @State private var lockupMark: CGRect = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `playsLaunchIntro`: the welcome replaces the launch screen (cold launch);
    /// false after sign-out, where the root crossfades it in, settled.
    /// `initialEmail` (DEBUG verification) opens the email sheet on the code step.
    public init(auth: CnxAuthModel, playsLaunchIntro: Bool = true, initialEmail: String? = nil) {
        self.auth = auth
        self.initialEmail = initialEmail
        // The intro's clock is per process: a Welcome rebuilt mid-intro picks
        // it up where it is instead of replaying or skipping to the end.
        let clock = WelcomeIntroClock.shared
        if !playsLaunchIntro, clock.t == nil { clock.t = .infinity }
        _started = State(initialValue: clock.t != nil)
        _lockupMark = State(initialValue: clock.lockupMark)
    }

    private static let lockupMarkSize: CGFloat = 22
    private static let launchMarkSize: CGFloat = 72

    public var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            let t = WelcomeIntroClock.shared.time(at: context.date)
            content(t: t, pulse: pulseTime(at: context.date))
        }
        .sheet(isPresented: $showsEmail) {
            EmailSignInSheet(auth: auth, initialEmail: initialEmail)
        }
        .task(id: started) { await runClock() }
        // Leaving Welcome (signed in) ends the intro; a later sign-out shows it settled.
        .onDisappear { WelcomeIntroClock.shared.t = .infinity }
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

    private func content(t rawT: Double, pulse: Double?) -> some View {
        typealias E = IntroEase
        // Reduce Motion: everything crossfades into its settled state.
        let fade = reduceMotion ? E.seg(rawT, 0, 0.35) : 1
        let t = reduceMotion ? .infinity : rawT
        let text = E.seg(t, 0.08, 0.5)
        return ZStack {
            theme.colors.bg.color.ignoresSafeArea()
            VStack(spacing: 0) {
                lockup(t: t)
                    .opacity(fade)
                    .padding(.top, 6)
                VStack(spacing: 26) {
                    WelcomeArt(t: t, pulse: reduceMotion ? nil : pulse)
                        .opacity(fade)
                    Text("Your Macs, in your pocket.")
                        .font(theme.type.welcomeTitle)
                        .foregroundStyle(theme.colors.label)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, theme.metrics.sideMargin)
                        .opacity(E.out(text) * fade)
                        .blur(radius: 8 * (1 - E.out(text)))
                        .offset(y: 8 * (1 - E.out(text)))
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                buttons(t: t, fade: fade)
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
                    .opacity(E.seg(t, 0.35, 0.75) * fade)
            }
            launchMark(t: rawT)
        }
    }

    // MARK: Lockup

    /// The chevron slot (drawn by `launchMark`) and the "cmux" wordmark.
    private func lockup(t: Double) -> some View {
        typealias E = IntroEase
        let word = E.outQuint(E.seg(t, 0.3, 0.85))
        return HStack(spacing: 7) {
            Color.clear
                .frame(width: Self.lockupMarkSize, height: Self.lockupMarkSize)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    lockupMark = rect
                    let clock = WelcomeIntroClock.shared
                    clock.lockupMark = rect
                    if clock.t == nil, rect.width > 0 { clock.t = -WelcomeIntroClock.debugHold }
                    if !started, clock.t != nil { started = true }
                }
            Text(verbatim: "cmux")
                .font(theme.type.welcomeWordmark)
                .foregroundStyle(theme.colors.label)
                .opacity(word)
                .offset(x: -8 * (1 - word))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "cmux"))
    }

    /// The launch screen's mark (72 pt, centered, `label`) on the first frame,
    /// gliding into the lockup slot while it takes the app icon's gradient.
    /// It stays the lockup's chevron afterwards, so nothing is swapped.
    private func launchMark(t: Double) -> some View {
        typealias E = IntroEase
        return GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let target = CGPoint(x: lockupMark.midX, y: lockupMark.midY)
            let glide = reduceMotion ? 1 : E.outQuint(E.seg(t, 0.04, 0.68))
            let size = E.lerp(Self.launchMarkSize, Self.lockupMarkSize, glide)
            let colour = reduceMotion ? E.seg(t, 0, 0.35) : E.seg(t, 0.12, 0.6)
            ZStack {
                if reduceMotion {
                    WelcomeMark(gradient: 0, glow: 0)
                        .frame(width: Self.launchMarkSize, height: Self.launchMarkSize)
                        .position(center)
                        .opacity(1 - colour)
                }
                WelcomeMark(gradient: colour, glow: 0.3 * colour, opaqueBase: !reduceMotion)
                    .frame(width: size, height: size)
                    .position(lockupMark == .zero ? center : E.lerp(center, target, glide))
                    .opacity(reduceMotion ? colour : 1)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Seconds into the current idle pulse, or nil between pulses.
    private func pulseTime(at date: Date) -> Double? {
        #if DEBUG
        if let frozen = WelcomeIntroClock.debugPulseFreeze { return frozen }
        #endif
        guard let pulseStart else { return nil }
        let u = date.timeIntervalSince(pulseStart)
        return u < WelcomeArt.pulseDuration ? u : nil
    }

    /// Stops the timeline when the intro settles, then wakes it for a short
    /// sync pulse every so often. These are intentional, bounded pauses on the
    /// clock the intro already runs on, not synchronization.
    private func runClock() async {
        guard started else { return }
        let clock = ContinuousClock()
        let end = reduceMotion ? 0.4 : WelcomeArt.introDuration + 0.05
        while let t = WelcomeIntroClock.shared.t, t < end {
            try? await clock.sleep(for: .seconds(end - t))
            guard !Task.isCancelled else { return }
        }
        animating = false
        WelcomeIntroClock.shared.logFramePacing()
        openRequestedEmail()
        if reduceMotion { return }
        var wait: Double = 4
        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            pulseStart = .now
            animating = true
            try? await clock.sleep(for: .seconds(WelcomeArt.pulseDuration + 0.05))
            animating = false
            wait = 9
        }
    }

    /// DEBUG verification opens the sheet the way a tap would.
    private func openRequestedEmail() {
        if initialEmail != nil, !showsEmail { showsEmail = true }
    }

    // MARK: Buttons

    private func buttons(t: Double, fade: Double) -> some View {
        let reveal = { (index: Int) -> Double in
            IntroEase.out(IntroEase.seg(t, 0.12 + Double(index) * 0.045, 0.52 + Double(index) * 0.045)) * fade
        }
        return VStack(spacing: 10) {
            ProviderButton(title: "Continue with Apple", reveal: reveal(0), isBusy: auth.busyProvider == .apple, kind: .apple) {
                Image(systemName: "apple.logo").font(.system(size: 19, weight: .medium))
            } action: { Task { await auth.signIn(with: .apple) } }
            ProviderButton(title: "Continue with Google", reveal: reveal(1), isBusy: auth.busyProvider == .google, kind: .provider) {
                Image("GoogleLogo", bundle: .module).resizable().frame(width: 18, height: 18)
            } action: { Task { await auth.signIn(with: .google) } }
            ProviderButton(title: "Continue with GitHub", reveal: reveal(2), isBusy: auth.busyProvider == .github, kind: .provider) {
                Image("GitHubLogo", bundle: .module).renderingMode(.template).resizable().frame(width: 18, height: 18)
            } action: { Task { await auth.signIn(with: .github) } }
            ProviderButton(title: "Continue with email", reveal: reveal(3), isBusy: false, kind: .provider) {
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

/// When this process's welcome intro started (it plays once per cold launch),
/// and where the lockup's chevron sits.
/// It advances with rendered frames, each step capped at 1/30 s, so a stalled
/// main thread (first launch, font loading) pauses the intro instead of
/// skipping part of it.
@MainActor
private final class WelcomeIntroClock {
    static let shared = WelcomeIntroClock()
    /// Seconds of intro shown; nil until it starts, `.infinity` when settled.
    var t: Double?
    var lockupMark: CGRect = .zero
    private var lastFrame: Date?

    #if DEBUG
    private var frameSteps: [Double] = []
    /// `-cnx-intro-hold <s>` (verification): rest on the launch mark first, so
    /// a screen recorder is past the launch burst when the intro starts.
    static var debugHold: Double {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-cnx-intro-hold"), i + 1 < arguments.count else { return 0 }
        return Double(arguments[i + 1]) ?? 0
    }

    /// Frame pacing of the intro, measured in the app (the simulator's recorder
    /// retimes frames under load, so its timestamps cannot show jank).
    func logFramePacing() {
        guard !frameSteps.isEmpty else { return }
        let sorted = frameSteps.sorted()
        let p50 = sorted[sorted.count / 2], worst = sorted[sorted.count - 1]
        let long = frameSteps.filter { $0 > p50 * 1.5 }.count
        welcomeLog.info("intro pacing: frames=\(self.frameSteps.count, privacy: .public) p50=\(p50 * 1000, privacy: .public)ms max=\(worst * 1000, privacy: .public)ms long=\(long, privacy: .public)")
        frameSteps = []
    }
    /// `-cnx-intro-freeze <s>` (verification): hold the intro at that time, for
    /// exact timeline screenshots.
    static let debugFreeze: Double? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-cnx-intro-freeze"), i + 1 < arguments.count else { return nil }
        return Double(arguments[i + 1])
    }()
    /// `-cnx-pulse-freeze <s>` (verification): hold the idle pulse at that time.
    static let debugPulseFreeze: Double? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-cnx-pulse-freeze"), i + 1 < arguments.count else { return nil }
        return Double(arguments[i + 1])
    }()
    #else
    static let debugHold: Double = 0
    func logFramePacing() {}
    #endif

    func time(at date: Date) -> Double {
        guard var t else { return 0 }
        #if DEBUG
        if let frozen = Self.debugFreeze { return frozen }
        #endif
        if let lastFrame {
            let step = date.timeIntervalSince(lastFrame)
            t += min(max(step, 0), 1.0 / 30)
            #if DEBUG
            if step > 0, t > 0, t < WelcomeArt.introDuration { frameSteps.append(step) }
            #endif
        }
        lastFrame = date
        self.t = t
        return t
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
                .shadow(color: Color(hex: "#2AA0F9").opacity((colorScheme == .dark ? 0.55 : 0.3) * glow), radius: 4 + 8 * glow)
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
    /// Intro progress, 0 (hidden, 14 pt low) to 1 (in place).
    let reveal: Double
    let isBusy: Bool
    let kind: Kind
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

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
        .opacity(reveal)
        .offset(y: 14 * (1 - reveal))
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
