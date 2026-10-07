public import CmuxiOSPlatform
public import Foundation
public import Observation

/// State behind the diagnostics screen: the crash-report consent toggle, the
/// log's size, export, copy and clear.
@MainActor
@Observable
public final class DiagnosticsModel {
    public private(set) var lineCount = 0
    public var crashReportsEnabled: Bool {
        didSet { defaults.set(crashReportsEnabled, forKey: consentKey) }
    }
    @ObservationIgnored private let sink: DiagnosticLogSink
    @ObservationIgnored private let supportInfo: @MainActor () -> DiagnosticSupportInfo
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let consentKey: String

    /// - Parameter consentKey: the shared telemetry opt-out key
    ///   (`UserDefaultsAnalyticsConsentProvider.telemetryKey`); a missing
    ///   value means enabled.
    public init(sink: DiagnosticLogSink, supportInfo: @escaping @MainActor () -> DiagnosticSupportInfo,
                defaults: UserDefaults = .standard, consentKey: String) {
        self.sink = sink
        self.supportInfo = supportInfo
        self.defaults = defaults
        self.consentKey = consentKey
        crashReportsEnabled = defaults.object(forKey: consentKey) as? Bool ?? true
    }

    public var export: DiagnosticsExport { DiagnosticsExport(sink: sink, header: supportInfo()) }

    public var supportText: String { supportInfo().rendered }

    public func refresh() async {
        lineCount = await sink.lines().count
    }

    public func clear() async {
        await sink.clear()
        sink.info("diagnostics", "log cleared")
        await refresh()
    }
}
