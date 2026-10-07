import Foundation

/// Receives onboarding metrics. Today an OSLog sink; the analytics lane
/// (C16) plugs in here.
public protocol OnboardingMetricsSink: Sendable {
    func record(_ metric: OnboardingMetric)
}
