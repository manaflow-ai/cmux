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
    private static let requiredReadyObservations = 2
    private static let readinessSettlingDuration: Duration = .milliseconds(500)
    private static let standardTimeout: Duration = .seconds(90)

    struct Configuration: Equatable, Sendable {
        static let modeEnvironmentKey = "CMUX_IROH_RELEASE_GATE_MODE"
        static let reportFilename = "cmux-iroh-release-gate.json"
        static let reportReadyNotification = "dev.cmux.ios.iroh-release-gate.report-ready"

        let mode: CmxIrohTransportVerificationMode
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
            self.mode = mode
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
        let passed: Bool
        let hostStatusVerified: Bool
        let rpcMethodInventoryVerified: Bool
        let terminalRoundTripVerified: Bool
        let workspaceMutationVerified: Bool
        let independentEventsVerified: Bool
        let notificationReconcileVerified: Bool
        let chatSessionsVerified: Bool
        let artifactScanCountVerified: Bool
        let routeKind: String?
        let selectedPath: String?
        let failure: String?
        /// Last privacy-safe transport diagnostic observed when readiness timed out.
        /// Raw values belong to the stable ``DiagnosticEventCode`` vocabulary.
        let lastDiagnosticEventCode: UInt16?
        /// Raw ``DiagnosticFailureKind`` carried by that event, when present.
        let lastDiagnosticFailureKind: Int?
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
        case notSignedIn = "not_signed_in"
        case notConnected = "not_connected"
        case nonIrohRoute = "non_iroh_route"
        case workspaceUnavailable = "workspace_unavailable"
        case terminalUnavailable = "terminal_unavailable"
        case pathPolicyMismatch = "path_policy_mismatch"
        case unknownProbeFailure = "unknown_probe_failure"
    }

    private enum Progress: Equatable, Sendable {
        case awaitingReadiness(lastObserved: Readiness?)
        case running
    }

    struct Dependencies {
        let readinessUpdates: (@MainActor (CMUXMobileShellStore) -> AsyncStream<Readiness>)?
        let runProbe: @MainActor (
            CMUXMobileShellStore,
            String
        ) async throws -> MobileIrohReleaseGateProbeResult
        let settingsUpdates: @MainActor () -> AsyncStream<CmxIrohSettingsSnapshot>
        let diagnosticReport: @MainActor () async -> DiagnosticReport
        let writeReport: @MainActor (Report, URL) throws -> Void
        let postReportReady: @MainActor () -> Void
        let timeout: Duration

        init(
            readinessUpdates: (@MainActor (CMUXMobileShellStore) -> AsyncStream<Readiness>)?,
            runProbe: @escaping @MainActor (
                CMUXMobileShellStore,
                String
            ) async throws -> MobileIrohReleaseGateProbeResult,
            settingsUpdates: @escaping @MainActor () -> AsyncStream<CmxIrohSettingsSnapshot>,
            diagnosticReport: @escaping @MainActor () async -> DiagnosticReport = { .empty },
            writeReport: @escaping @MainActor (Report, URL) throws -> Void,
            postReportReady: @escaping @MainActor () -> Void,
            timeout: Duration
        ) {
            self.readinessUpdates = readinessUpdates
            self.runProbe = runProbe
            self.settingsUpdates = settingsUpdates
            self.diagnosticReport = diagnosticReport
            self.writeReport = writeReport
            self.postReportReady = postReportReady
            self.timeout = timeout
        }
    }

    private let configuration: Configuration
    private let fileManager: FileManager
    private let dependencies: Dependencies
    private var observationID: UUID?
    private var runTask: Task<Void, Never>?
    private var completedProbe: MobileIrohReleaseGateProbeResult?
    private var progress: Progress = .awaitingReadiness(lastObserved: nil)

    init(
        configuration: Configuration,
        settingsController: any CmxIrohSettingsControlling,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.dependencies = Dependencies(
            readinessUpdates: nil,
            runProbe: { store, marker in
                try await store.runIrohReleaseGateProbe(marker: marker)
            },
            settingsUpdates: {
                settingsController.irohSettingsUpdates()
            },
            diagnosticReport: {
                await settingsController.irohDiagnosticReport()
            },
            writeReport: { report, url in
                try Self.write(report: report, to: url)
            },
            postReportReady: {
                Self.postReportReadyNotification()
            },
            timeout: Self.standardTimeout
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
        progress = .awaitingReadiness(lastObserved: nil)
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
        let timeout = dependencies.timeout
        let reports = AsyncStream<Report>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let operationTask = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.yield(Self.failureReport(
                        mode: mode,
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
                let deadline = await self.deadlineFailure()
                continuation.yield(Self.failureReport(
                    mode: mode,
                    failure: deadline.failure,
                    completedProbe: self.completedProbe,
                    lastDiagnosticEvent: deadline.lastDiagnosticEvent
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
            failure: .unknownProbeFailure
        )
    }

    private func execute(store: CMUXMobileShellStore) async -> Report {
        var readyObservations = 0
        while readyObservations < Self.requiredReadyObservations {
            let readiness = dependencies.readinessUpdates?(store)
                ?? readinessUpdates(for: store)
            var observedReady = false
            for await state in readiness {
                progress = .awaitingReadiness(lastObserved: state)
                mobileIrohReleaseGateLog.info(
                    "readiness signedIn=\(state.isSignedIn, privacy: .public) connected=\(state.isConnected, privacy: .public) iroh=\(state.usesIroh, privacy: .public) workspace=\(state.hasWorkspaceMutation, privacy: .public) terminal=\(state.hasTerminal, privacy: .public)"
                )
                guard !Task.isCancelled else {
                    return Self.failureReport(
                        mode: configuration.mode,
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
                    failure: .timeout
                )
            }
            guard observedReady else {
                return Self.failureReport(
                    mode: configuration.mode,
                    failure: .readinessUnavailable
                )
            }
            readyObservations += 1
            if readyObservations < Self.requiredReadyObservations,
               dependencies.readinessUpdates == nil {
                do {
                    try await Task.sleep(for: Self.readinessSettlingDuration)
                } catch {
                    return Self.failureReport(
                        mode: configuration.mode,
                        failure: .timeout
                    )
                }
            }
        }
        progress = .running
        guard !Task.isCancelled else {
            return Self.failureReport(
                mode: configuration.mode,
                failure: .timeout
            )
        }
        let marker = "CMUX_IROH_GATE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let probe: MobileIrohReleaseGateProbeResult
        do {
            probe = try await dependencies.runProbe(store, marker)
        } catch let failure as MobileIrohReleaseGateProbeFailure {
            return Self.probeFailureReport(
                mode: configuration.mode,
                failure: failure,
                selectedPath: nil
            )
        } catch {
            return Self.failureReport(
                mode: configuration.mode,
                failure: .unknownProbeFailure
            )
        }
        completedProbe = probe

        let snapshots = dependencies.settingsUpdates()
        for await snapshot in snapshots {
            guard !Task.isCancelled else {
                return Self.failureReport(
                    mode: configuration.mode,
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
                    probe: probe,
                    selectedPath: selectedPath
                )
            }
        }
        return Self.failureReport(
            mode: configuration.mode,
            failure: .pathPolicyMismatch,
            completedProbe: probe
        )
    }

    private struct DeadlineFailure: Sendable {
        let failure: Failure
        let lastDiagnosticEvent: DiagnosticEvent?
    }

    private func deadlineFailure() async -> DeadlineFailure {
        let failure: Failure
        guard case let .awaitingReadiness(lastObserved) = progress,
              let readiness = lastObserved else {
            return DeadlineFailure(failure: .timeout, lastDiagnosticEvent: nil)
        }
        if !readiness.isSignedIn {
            failure = .notSignedIn
        } else if !readiness.isConnected {
            failure = .notConnected
        } else if !readiness.usesIroh {
            failure = .nonIrohRoute
        } else if !readiness.hasWorkspaceMutation {
            failure = .workspaceUnavailable
        } else if !readiness.hasTerminal {
            failure = .terminalUnavailable
        } else {
            failure = .timeout
        }
        guard failure == .notConnected else {
            return DeadlineFailure(failure: failure, lastDiagnosticEvent: nil)
        }
        let report = await dependencies.diagnosticReport()
        return DeadlineFailure(
            failure: failure,
            lastDiagnosticEvent: report.events.last(where: Self.isConnectionDiagnosticEvent)
        )
    }

    private nonisolated static func isConnectionDiagnosticEvent(_ event: DiagnosticEvent) -> Bool {
        switch event.code {
        case .pairFail,
             .pairUnreachable,
             .transportDialStarted,
             .transportDialConnected,
             .transportDialFailed,
             .hostAuthenticated,
             .rpcReady,
             .endpointStarting,
             .endpointActive,
             .endpointStopped,
             .endpointFailed,
             .relayPolicyRefreshStarted,
             .relayPolicyRefreshSucceeded,
             .relayPolicyRefreshFailed,
             .routeUnavailable,
             .discoveryStarted,
             .discoverySucceeded,
             .discoveryFailed,
             .admissionSucceeded,
             .admissionFailed,
             .hostAuthenticationFailed,
             .rpcFailed:
            true
        default:
            false
        }
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
                isConnected: store.hasActiveMacConnection,
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

    private static func completedReport(
        mode: CmxIrohTransportVerificationMode,
        probe: MobileIrohReleaseGateProbeResult,
        selectedPath: String
    ) -> Report {
        Report(
            schemaVersion: 5,
            mode: mode.rawValue,
            passed: probe.hostStatusVerified
                && probe.rpcMethodInventoryVerified
                && probe.terminalRoundTripVerified
                && probe.workspaceMutationVerified
                && probe.independentEventsVerified
                && probe.notificationReconcileVerified
                && probe.chatSessionsVerified
                && probe.artifactScanCountVerified,
            hostStatusVerified: probe.hostStatusVerified,
            rpcMethodInventoryVerified: probe.rpcMethodInventoryVerified,
            terminalRoundTripVerified: probe.terminalRoundTripVerified,
            workspaceMutationVerified: probe.workspaceMutationVerified,
            independentEventsVerified: probe.independentEventsVerified,
            notificationReconcileVerified: probe.notificationReconcileVerified,
            chatSessionsVerified: probe.chatSessionsVerified,
            artifactScanCountVerified: probe.artifactScanCountVerified,
            routeKind: CmxAttachTransportKind.iroh.rawValue,
            selectedPath: selectedPath,
            failure: nil,
            lastDiagnosticEventCode: nil,
            lastDiagnosticFailureKind: nil
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
        failure: MobileIrohReleaseGateProbeFailure,
        selectedPath: String?
    ) -> Report {
        Report(
            schemaVersion: 5,
            mode: mode.rawValue,
            passed: false,
            hostStatusVerified: false,
            rpcMethodInventoryVerified: false,
            terminalRoundTripVerified: false,
            workspaceMutationVerified: false,
            independentEventsVerified: false,
            notificationReconcileVerified: false,
            chatSessionsVerified: false,
            artifactScanCountVerified: false,
            routeKind: CmxAttachTransportKind.iroh.rawValue,
            selectedPath: selectedPath,
            failure: failure.rawValue,
            lastDiagnosticEventCode: nil,
            lastDiagnosticFailureKind: nil
        )
    }

    private nonisolated static func failureReport(
        mode: CmxIrohTransportVerificationMode,
        failure: Failure,
        completedProbe: MobileIrohReleaseGateProbeResult? = nil,
        lastDiagnosticEvent: DiagnosticEvent? = nil
    ) -> Report {
        Report(
            schemaVersion: 5,
            mode: mode.rawValue,
            passed: false,
            hostStatusVerified: completedProbe?.hostStatusVerified ?? false,
            rpcMethodInventoryVerified: completedProbe?.rpcMethodInventoryVerified ?? false,
            terminalRoundTripVerified: completedProbe?.terminalRoundTripVerified ?? false,
            workspaceMutationVerified: completedProbe?.workspaceMutationVerified ?? false,
            independentEventsVerified: completedProbe?.independentEventsVerified ?? false,
            notificationReconcileVerified: completedProbe?.notificationReconcileVerified ?? false,
            chatSessionsVerified: completedProbe?.chatSessionsVerified ?? false,
            artifactScanCountVerified: completedProbe?.artifactScanCountVerified ?? false,
            routeKind: completedProbe == nil ? nil : CmxAttachTransportKind.iroh.rawValue,
            selectedPath: nil,
            failure: failure.rawValue,
            lastDiagnosticEventCode: lastDiagnosticEvent?.code.rawValue,
            lastDiagnosticFailureKind: lastDiagnosticEvent?.diagnosticFailureKind?.rawValue
        )
    }
}
#endif
