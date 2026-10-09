import Foundation
import OSLog

/// Logs metrics under `dev.cmux.ios` / `onboarding` with public step names.
public struct LogOnboardingMetrics: OnboardingMetricsSink {
    private let logger = Logger(subsystem: "dev.cmux.ios", category: "onboarding")

    public init() {}

    public func record(_ metric: OnboardingMetric) {
        switch metric {
        case .stepShown(let step, let index, let total):
            logger.info("shown \(step.rawValue, privacy: .public) \(index + 1)/\(total)")
        case .stepFinished(let step, let outcome, let duration):
            logger.info("finished \(step.rawValue, privacy: .public) \(outcome.rawValue, privacy: .public) \(Self.ms(duration))ms")
        case .choice(let step, let value):
            logger.info("choice \(step.rawValue, privacy: .public) \(value, privacy: .public)")
        case .finished(let duration, let paired, let mode):
            logger.info("done \(mode.rawValue, privacy: .public) paired=\(paired) \(Self.ms(duration))ms")
        }
    }

    private static func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
