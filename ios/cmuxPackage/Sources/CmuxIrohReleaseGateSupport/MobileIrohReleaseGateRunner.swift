#if os(iOS) && DEBUG
import CMUXMobileCore
import CoreFoundation
import CmuxIrohTransport
import CmuxMobileShell
import CmuxMobileShellReleaseGateSupport
import Foundation
import Observation
import OSLog

private let mobileIrohReleaseGateLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "iroh-release-gate"
)

@MainActor
final class MobileIrohReleaseGateRunner {
    private static let relayRolloverSoakDurationSeconds = 330
    private static let standardTimeout: Duration = .seconds(90)
    private static let extendedTimeout: Duration = .seconds(420)

    struct Configuration: Equatable, Sendable {
        static let modeEnvironmentKey = "CMUX_IROH_RELEASE_GATE_MODE"
        static let scenarioEnvironmentKey = "CMUX_IROH_RELEASE_GATE_SCENARIO"
        static let reportFilename = "cmux-iroh-release-gate.json"
        static let reportReadyNotification = "dev.cmux.ios.iroh-release-gate.report-ready"

        let mode: CmxIrohTransportVerificationMode
        let scenario: MobileIrohReleaseGateScenario
        let reportURL: URL

        init?(
            environment: [String: String],
            cachesDirectory: URL?
        ) {
            guard let rawMode = environment[Self.modeEnvironmentKey],
                  let mode = CmxIrohTransportVerificationMode(rawValue: rawMode),
                  let cachesDirectory else {
                return nil
            }
            let scenario: MobileIrohReleaseGateScenario
            if let rawScenario = environment[Self.scenarioEnvironmentKey] {
                guard let parsed = MobileIrohReleaseGateScenario(rawValue: rawScenario) else {
                    return nil
                }
                scenario = parsed
            } else {
                scenario = .standard
            }
            guard scenario == .standard || mode == .relayOnly else { return nil }
            self.mode = mode
            self.scenario = scenario
            self.reportURL = cachesDirectory.appendingPathComponent(Self.reportFilename)
        }

        static func current(
            processInfo: ProcessInfo = .processInfo,
            fileManager: FileManager = .default
        ) -> Configuration? {
            Configuration(
                environment: processInfo.environment,
                cachesDirectory: fileManager.urls(
                    for: .cachesDirectory,
                    in: .userDomainMask
                ).first
            )
        }
    }

    struct Report: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let mode: String
        let scenario: String
        let passed: Bool
        let hostStatusVerified: Bool
        let terminalRoundTripVerified: Bool
        let workspaceMutationVerified: Bool
        let independentEventsVerified: Bool
        let notificationReconcileVerified: Bool
        let chatSessionsVerified: Bool
        let artifactScanCountVerified: Bool
        let relayCredentialRolloverVerified: Bool
        let endpointContinuityVerified: Bool
        let connectionContinuityVerified: Bool
        let controlStreamContinuityVerified: Bool
        let independentEventsContinuityVerified: Bool
        let artifactLaneVerified: Bool
        let unrefreshedExpiryDisconnectVerified: Bool
        let soakDurationSeconds: Int
        let routeKind: String?
        let selectedPath: String?
        let failure: String?
    }

    struct Readiness: Equatable, Sendable {
        let isSignedIn: Bool
        let isConnected: Bool
        let usesIroh: Bool
        let hasWorkspaceMutation: Bool
        let hasTerminal: Bool

        var isReady: Bool {
            isSignedIn
                && isConnected
                && usesIroh
                && hasWorkspaceMutation
                && hasTerminal
        }
    }

    private enum Failure: String, Sendable {
        case timeout
        case readinessUnavailable = "readiness_unavailable"
        case pathPolicyMismatch = "path_policy_mismatch"
        case unknownProbeFailure = "unknown_probe_failure"
    }

    struct Dependencies {
        let readinessUpdates: (@MainActor (CMUXMobileShellStore) -> AsyncStream<Readiness>)?
        let runProbe: @MainActor (
            CMUXMobileShellStore,
            String
        ) async throws -> MobileIrohReleaseGateProbeResult
        let settingsUpdates: @MainActor () -> AsyncStream<CmxIrohSettingsSnapshot>
        let writeReport: @MainActor (Report, URL) throws -> Void
        let postReportReady: @MainActor () -> Void
        let timeout: Duration
    }

    private let configuration: Configuration
    private let fileManager: FileManager
    private let dependencies: Dependencies
    private var observationID: UUID?
    private var runTask: Task<Void, Never>?
    private var completedProbe: MobileIrohReleaseGateProbeResult?

    init(
        configuration: Configuration,
        settingsController: any CmxIrohSettingsControlling,
        endpointIdentity: @escaping @Sendable () async -> CmxIrohPeerIdentity? = { nil },
        relayCredentialExpiry: @escaping @Sendable () async -> Date? = { nil },
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.dependencies = Dependencies(
            readinessUpdates: nil,
            runProbe: { store, marker in
                try await store.runIrohReleaseGateProbe(
                    marker: marker,
                    scenario: configuration.scenario,
                    soakDurationSeconds: configuration.scenario == .relayRollover
                        ? Self.relayRolloverSoakDurationSeconds
                        : 0,
                    endpointIdentity: endpointIdentity,
                    relayCredentialExpiry: relayCredentialExpiry
                )
            },
            settingsUpdates: {
                settingsController.irohSettingsUpdates()
            },
            writeReport: { report, url in
                try Self.write(report: report, to: url)
            },
            postReportReady: {
                Self.postReportReadyNotification()
            },
            timeout: configuration.scenario == .standard
                ? Self.standardTimeout
                : Self.extendedTimeout
        )
    }

    init(
        configuration: Configuration,
        dependencies: Dependencies,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.dependencies = dependencies
    }

    func run(store: CMUXMobileShellStore) async {
        if let runTask {
            await runTask.value
            return
        }
        let task = Task { @MainActor [self] in
            await runOnce(store: store)
        }
        runTask = task
        await task.value
    }

    private func runOnce(store: CMUXMobileShellStore) async {
        completedProbe = nil
        try? fileManager.removeItem(at: configuration.reportURL)
        let report = await boundedReport(store: store)
        do {
            try dependencies.writeReport(report, configuration.reportURL)
            dependencies.postReportReady()
            mobileIrohReleaseGateLog.info(
                "release gate completed passed=\(report.passed, privacy: .public)"
            )
        } catch {
            mobileIrohReleaseGateLog.error("release gate report write failed")
        }
    }

    private nonisolated static func write(report: Report, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private nonisolated static func postReportReadyNotification() {
        let rawName = Configuration.reportReadyNotification.withCString {
            CFStringCreateWithCString(
                nil,
                $0,
                CFStringBuiltInEncodings.UTF8.rawValue
            )
        }
        guard let rawName else { return }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: rawName),
            nil,
            nil,
            true
        )
    }

    private func boundedReport(store: CMUXMobileShellStore) async -> Report {
        let mode = configuration.mode
        let scenario = configuration.scenario
        let timeout = dependencies.timeout
        let reports = AsyncStream<Report>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let operationTask = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.yield(Self.failureReport(
                        mode: mode,
                        scenario: scenario,
                        failure: .unknownProbeFailure
                    ))
                    continuation.finish()
                    return
                }
                continuation.yield(await self.execute(store: store))
                continuation.finish()
            }
            let deadlineTask = Task { @MainActor [weak self] in
                do {
                    // This is the gate's real deadline; tests inject a shorter duration.
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                continuation.yield(Self.failureReport(
                    mode: mode,
                    scenario: scenario,
                    failure: .timeout,
                    completedProbe: self.completedProbe
                ))
                continuation.finish()
                operationTask.cancel()
            }
            continuation.onTermination = { _ in
                operationTask.cancel()
                deadlineTask.cancel()
            }
        }
        for await report in reports {
            return report
        }
        return Self.failureReport(
            mode: mode,
            scenario: scenario,
            failure: .unknownProbeFailure
        )
    }

    private func execute(store: CMUXMobileShellStore) async -> Report {
        let readiness = dependencies.readinessUpdates?(store)
            ?? readinessUpdates(for: store)
        var observedReady = false
        for await state in readiness {
            mobileIrohReleaseGateLog.info(
                "readiness signedIn=\(state.isSignedIn, privacy: .public) connected=\(state.isConnected, privacy: .public) iroh=\(state.usesIroh, privacy: .public) workspace=\(state.hasWorkspaceMutation, privacy: .public) terminal=\(state.hasTerminal, privacy: .public)"
            )
            guard !Task.isCancelled else {
                return Self.failureReport(
                    mode: configuration.mode,
                    scenario: configuration.scenario,
                    failure: .timeout
                )
            }
            if state.isReady {
                observedReady = true
                break
            }
        }
        guard !Task.isCancelled else {
            return Self.failureReport(
                mode: configuration.mode,
                scenario: configuration.scenario,
                failure: .timeout
            )
        }
        guard observedReady else {
            return Self.failureReport(
                mode: configuration.mode,
                scenario: configuration.scenario,
                failure: .readinessUnavailable
            )
        }

        var pathBeforeProbe: String?
        if configuration.scenario != .standard {
            for await snapshot in dependencies.settingsUpdates() {
                guard !Task.isCancelled else {
                    return Self.failureReport(
                        mode: configuration.mode,
                        scenario: configuration.scenario,
                        failure: .timeout
                    )
                }
                if let accepted = Self.acceptedPath(
                    snapshot.selectedTransportPath,
                    mode: configuration.mode
                ) {
                    pathBeforeProbe = accepted
                    break
                }
            }
            guard !Task.isCancelled else {
                return Self.failureReport(
                    mode: configuration.mode,
                    scenario: configuration.scenario,
                    failure: .timeout
                )
            }
            guard pathBeforeProbe != nil else {
                return Self.failureReport(
                    mode: configuration.mode,
                    scenario: configuration.scenario,
                    failure: .pathPolicyMismatch
                )
            }
        }

        let marker = "CMUX_IROH_GATE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let probe: MobileIrohReleaseGateProbeResult
        do {
            probe = try await dependencies.runProbe(store, marker)
        } catch let failure as MobileIrohReleaseGateProbeFailure {
            return Self.probeFailureReport(
                mode: configuration.mode,
                scenario: configuration.scenario,
                failure: failure,
                selectedPath: pathBeforeProbe
            )
        } catch {
            return Self.failureReport(
                mode: configuration.mode,
                scenario: configuration.scenario,
                failure: .unknownProbeFailure
            )
        }
        completedProbe = probe

        if let pathBeforeProbe {
            return Self.completedReport(
                mode: configuration.mode,
                scenario: configuration.scenario,
                probe: probe,
                selectedPath: pathBeforeProbe
            )
        }

        let snapshots = dependencies.settingsUpdates()
        for await snapshot in snapshots {
            guard !Task.isCancelled else {
                return Self.failureReport(
                    mode: configuration.mode,
                    scenario: configuration.scenario,
                    failure: .timeout,
                    completedProbe: probe
                )
            }
            let diagnosticPath = DiagnosticPathKind(snapshot.selectedTransportPath)
            mobileIrohReleaseGateLog.info(
                "path observation kind=\(diagnosticPath.rawValue, privacy: .public)"
            )
            if let selectedPath = Self.acceptedPath(
                snapshot.selectedTransportPath,
                mode: configuration.mode
            ) {
                observationID = nil
                return Self.completedReport(
                    mode: configuration.mode,
                    scenario: configuration.scenario,
                    probe: probe,
                    selectedPath: selectedPath
                )
            }
        }
        return Self.failureReport(
            mode: configuration.mode,
            scenario: configuration.scenario,
            failure: .pathPolicyMismatch,
            completedProbe: probe
        )
    }

    private func readinessUpdates(
        for store: CMUXMobileShellStore
    ) -> AsyncStream<Readiness> {
        let id = UUID()
        observationID = id
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observeReadiness(store: store, continuation: continuation, id: id)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard self?.observationID == id else { return }
                    self?.observationID = nil
                }
            }
        }
    }

    private func observeReadiness(
        store: CMUXMobileShellStore,
        continuation: AsyncStream<Readiness>.Continuation,
        id: UUID
    ) {
        guard observationID == id else {
            continuation.finish()
            return
        }
        let state = withObservationTracking {
            Readiness(
                isSignedIn: store.isSignedIn,
                isConnected: store.connectionState == .connected,
                usesIroh: store.activeRoute?.kind == .iroh,
                hasWorkspaceMutation: store.selectedWorkspace?
                    .actionCapabilities.supportsWorkspaceActions == true
                    && store.selectedWorkspace?.name
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                hasTerminal: store.selectedTerminalID != nil
            )
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else {
                    continuation.finish()
                    return
                }
                self.observeReadiness(
                    store: store,
                    continuation: continuation,
                    id: id
                )
            }
        }
        continuation.yield(state)
        if state.isReady {
            observationID = nil
            continuation.finish()
        }
    }

    private static func scenarioPassed(
        _ scenario: MobileIrohReleaseGateScenario,
        probe: MobileIrohReleaseGateProbeResult
    ) -> Bool {
        switch scenario {
        case .standard:
            return true
        case .relayRollover:
            return probe.relayCredentialRolloverVerified
                && probe.endpointContinuityVerified
                && probe.connectionContinuityVerified
                && probe.controlStreamContinuityVerified
                && probe.independentEventsContinuityVerified
                && probe.artifactLaneVerified
                && probe.soakDurationSeconds >= relayRolloverSoakDurationSeconds
        case .relayExpiry:
            return probe.unrefreshedExpiryDisconnectVerified
        }
    }

    private static func completedReport(
        mode: CmxIrohTransportVerificationMode,
        scenario: MobileIrohReleaseGateScenario,
        probe: MobileIrohReleaseGateProbeResult,
        selectedPath: String
    ) -> Report {
        Report(
            schemaVersion: 3,
            mode: mode.rawValue,
            scenario: scenario.rawValue,
            passed: probe.hostStatusVerified
                && probe.terminalRoundTripVerified
                && probe.workspaceMutationVerified
                && probe.independentEventsVerified
                && probe.notificationReconcileVerified
                && probe.chatSessionsVerified
                && probe.artifactScanCountVerified
                && scenarioPassed(scenario, probe: probe),
            hostStatusVerified: probe.hostStatusVerified,
            terminalRoundTripVerified: probe.terminalRoundTripVerified,
            workspaceMutationVerified: probe.workspaceMutationVerified,
            independentEventsVerified: probe.independentEventsVerified,
            notificationReconcileVerified: probe.notificationReconcileVerified,
            chatSessionsVerified: probe.chatSessionsVerified,
            artifactScanCountVerified: probe.artifactScanCountVerified,
            relayCredentialRolloverVerified: probe.relayCredentialRolloverVerified,
            endpointContinuityVerified: probe.endpointContinuityVerified,
            connectionContinuityVerified: probe.connectionContinuityVerified,
            controlStreamContinuityVerified: probe.controlStreamContinuityVerified,
            independentEventsContinuityVerified: probe.independentEventsContinuityVerified,
            artifactLaneVerified: probe.artifactLaneVerified,
            unrefreshedExpiryDisconnectVerified: probe.unrefreshedExpiryDisconnectVerified,
            soakDurationSeconds: probe.soakDurationSeconds,
            routeKind: CmxAttachTransportKind.iroh.rawValue,
            selectedPath: selectedPath,
            failure: nil
        )
    }

    static func acceptedPath(
        _ path: CmxIrohSelectedTransportPath,
        mode: CmxIrohTransportVerificationMode
    ) -> String? {
        switch (mode, path) {
        case (.automatic, .direct), (.directOnly, .direct):
            return "direct"
        case (.automatic, .privateNetwork), (.directOnly, .privateNetwork):
            return "private_network"
        case (.automatic, .managedRelay), (.relayOnly, .managedRelay):
            return "managed_relay"
        case (.automatic, .customRelay), (.relayOnly, .customRelay):
            return "custom_relay"
        case (_, .unavailable), (.relayOnly, .direct), (.relayOnly, .privateNetwork),
             (.directOnly, .managedRelay), (.directOnly, .customRelay):
            return nil
        }
    }

    private static func probeFailureReport(
        mode: CmxIrohTransportVerificationMode,
        scenario: MobileIrohReleaseGateScenario,
        failure: MobileIrohReleaseGateProbeFailure,
        selectedPath: String?
    ) -> Report {
        Report(
            schemaVersion: 3,
            mode: mode.rawValue,
            scenario: scenario.rawValue,
            passed: false,
            hostStatusVerified: false,
            terminalRoundTripVerified: false,
            workspaceMutationVerified: false,
            independentEventsVerified: false,
            notificationReconcileVerified: false,
            chatSessionsVerified: false,
            artifactScanCountVerified: false,
            relayCredentialRolloverVerified: false,
            endpointContinuityVerified: false,
            connectionContinuityVerified: false,
            controlStreamContinuityVerified: false,
            independentEventsContinuityVerified: false,
            artifactLaneVerified: false,
            unrefreshedExpiryDisconnectVerified: false,
            soakDurationSeconds: 0,
            routeKind: CmxAttachTransportKind.iroh.rawValue,
            selectedPath: selectedPath,
            failure: failure.rawValue
        )
    }

    private nonisolated static func failureReport(
        mode: CmxIrohTransportVerificationMode,
        scenario: MobileIrohReleaseGateScenario,
        failure: Failure,
        completedProbe: MobileIrohReleaseGateProbeResult? = nil
    ) -> Report {
        Report(
            schemaVersion: 3,
            mode: mode.rawValue,
            scenario: scenario.rawValue,
            passed: false,
            hostStatusVerified: completedProbe?.hostStatusVerified ?? false,
            terminalRoundTripVerified: completedProbe?.terminalRoundTripVerified ?? false,
            workspaceMutationVerified: completedProbe?.workspaceMutationVerified ?? false,
            independentEventsVerified: completedProbe?.independentEventsVerified ?? false,
            notificationReconcileVerified: completedProbe?.notificationReconcileVerified ?? false,
            chatSessionsVerified: completedProbe?.chatSessionsVerified ?? false,
            artifactScanCountVerified: completedProbe?.artifactScanCountVerified ?? false,
            relayCredentialRolloverVerified: completedProbe?.relayCredentialRolloverVerified ?? false,
            endpointContinuityVerified: completedProbe?.endpointContinuityVerified ?? false,
            connectionContinuityVerified: completedProbe?.connectionContinuityVerified ?? false,
            controlStreamContinuityVerified: completedProbe?.controlStreamContinuityVerified ?? false,
            independentEventsContinuityVerified: completedProbe?.independentEventsContinuityVerified ?? false,
            artifactLaneVerified: completedProbe?.artifactLaneVerified ?? false,
            unrefreshedExpiryDisconnectVerified: completedProbe?.unrefreshedExpiryDisconnectVerified ?? false,
            soakDurationSeconds: completedProbe?.soakDurationSeconds ?? 0,
            routeKind: completedProbe == nil ? nil : CmxAttachTransportKind.iroh.rawValue,
            selectedPath: nil,
            failure: failure.rawValue
        )
    }
}
#endif
