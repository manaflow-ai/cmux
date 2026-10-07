public import CmuxiOSOnboardingCore
import Foundation
public import Observation
import UIKit

/// Drives one onboarding run: owns the flow value, persists it after every
/// transition, keeps the context current (auth, permissions, trusted Macs),
/// records metrics and plays haptics. Views call intents; the app listens to
/// `onFinish`.
@MainActor
@Observable
public final class OnboardingModel {
    public private(set) var flow: OnboardingFlow
    public private(set) var direction: OnboardingTransition.Direction = .forward
    public private(set) var pairedMacName: String?
    public private(set) var isFinished = false
    /// Set while a permission prompt is up, so its buttons disable.
    public private(set) var requesting: PermissionKind?

    @ObservationIgnored public var onFinish: (@MainActor (OnboardingResult) -> Void)?
    @ObservationIgnored let dependencies: OnboardingDependencies
    @ObservationIgnored let haptics = OnboardingHaptics()
    @ObservationIgnored private let measure = ContinuousClock()
    @ObservationIgnored private let startedAt: ContinuousClock.Instant
    @ObservationIgnored private var stepStartedAt: ContinuousClock.Instant
    @ObservationIgnored private var shownStep: OnboardingStep?

    public var mode: OnboardingMode { flow.context.mode }

    /// Loads stored progress for a first run (a replay starts fresh in
    /// memory); `start` overrides the step for DEBUG screenshots.
    public init(dependencies: OnboardingDependencies, context: OnboardingContext, start: OnboardingStep? = nil) {
        self.dependencies = dependencies
        var progress = context.mode == .firstRun ? (dependencies.store.load() ?? .fresh) : .fresh
        if let start { progress.current = start }
        flow = OnboardingFlow(progress: progress, context: context)
        startedAt = measure.now
        stepStartedAt = startedAt
        if context.mode == .firstRun { dependencies.store.save(flow.progress) }
    }

    /// Keeps the context current while the onboarding screen is up. Run from
    /// the root view's `.task`, which cancels it when the screen goes away.
    public func run() async {
        haptics.prepare()
        noteShown()
        await refreshPermissions()
        for await snapshot in await dependencies.devices.updates() {
            var context = flow.context
            context.hasTrustedMac = PairingPhase.hasTrustedMac(in: snapshot.value)
            apply(.contextChanged(context))
        }
    }

    // MARK: - Intents

    public func advance() { apply(.advance) }
    public func back() { apply(.back) }
    public func skipIntro() { apply(.skipIntro) }
    public func skipStep() { apply(.skipStep) }

    /// Auth changed (sign-in finished on the sign-in step, or a sign-out).
    public func setSignedIn(_ signedIn: Bool) {
        guard flow.context.isSignedIn != signedIn else { return }
        var context = flow.context
        context.isSignedIn = signedIn
        apply(.contextChanged(context))
        if signedIn { Task { await refreshPermissions() } }
    }

    /// The priming screen's primary button: shows the system prompt, records
    /// the answer, and moves on for the notifications and local network steps.
    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        guard requesting == nil else { return flow.context.status(of: kind) }
        requesting = kind
        let answer = await dependencies.permissions.request(kind)
        requesting = nil
        record(.choice(flow.current, value: "\(kind.rawValue).\(answer.rawValue)"))
        var context = flow.context
        context.setStatus(answer, of: kind)
        apply(.contextChanged(context))
        if kind != .camera { advance() }
        return answer
    }

    /// The header's Close in a replay: ends without touching stored progress.
    public func close() {
        guard mode == .replay else { return }
        finish()
    }

    public func choose(_ value: String) {
        haptics.select()
        record(.choice(flow.current, value: value))
    }

    func paired(name: String) {
        pairedMacName = name
        haptics.success()
    }

    func refreshPermissions() async {
        var context = flow.context
        for kind in PermissionKind.allCases {
            context.setStatus(await dependencies.permissions.status(of: kind), of: kind)
        }
        apply(.contextChanged(context))
    }

    func record(_ metric: OnboardingMetric) {
        dependencies.metrics.record(metric)
    }

    // MARK: - Private

    private func apply(_ event: OnboardingEvent) {
        let transition = flow.send(event)
        if mode == .firstRun { dependencies.store.save(flow.progress) }
        if let outcome = transition.outcome, transition.changedStep {
            record(.stepFinished(transition.from, outcome: outcome, duration: measure.now - stepStartedAt))
        }
        if transition.finished {
            finish()
            return
        }
        guard transition.from != transition.to else { return }
        direction = transition.direction
        if transition.direction == .forward { haptics.advance() }
        if transition.to == .celebrate { haptics.success() }
        noteShown()
    }

    private func noteShown() {
        guard !isFinished, shownStep != flow.current else { return }
        shownStep = flow.current
        stepStartedAt = measure.now
        let position = flow.position
        record(.stepShown(flow.current, index: position.index, total: position.total))
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        record(.finished(duration: measure.now - startedAt, paired: pairedMacName != nil, mode: mode))
        onFinish?(OnboardingResult(pairedMacName: pairedMacName))
    }
}
