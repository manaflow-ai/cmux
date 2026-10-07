public import Foundation
public import Observation

/// The crash-report and telemetry consent, moved here from Diagnostics
/// (c16-platform.md section 3). Same key as the shipping app
/// (`UserDefaultsAnalyticsConsentProvider.telemetryKey`), missing means on;
/// `CrashReporter` observes `UserDefaults` and starts or stops Sentry.
@MainActor
@Observable
public final class PrivacyPreferences {
    public var shareCrashReports: Bool {
        didSet { defaults.set(shareCrashReports, forKey: consentKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let consentKey: String

    public init(defaults: UserDefaults = .standard, consentKey: String) {
        self.defaults = defaults
        self.consentKey = consentKey
        shareCrashReports = defaults.object(forKey: consentKey) as? Bool ?? true
    }
}
