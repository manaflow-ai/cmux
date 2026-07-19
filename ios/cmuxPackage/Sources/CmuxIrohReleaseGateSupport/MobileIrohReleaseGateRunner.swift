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
        let terminalRoundTripVerified: Bool
        let workspaceMutationVerified: Bool
        let independentEventsVerified: Bool
        let notificationReconcileVerified: Bool
        let chatSessionsVerified: Bool
        let artifactScanCountVerified: Bool
        let routeKind: String?
        let selectedPath: String?
        let failure: String?
    }

    private struct Readiness: Equatable, Sendable {
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
        case pathPolicyMismatch = "path_policy_mismatch"
        case unknownProbeFailure = "unknown_probe_failure"
    }

    private let configuration: Configuration
    private let fileManager: FileManager
    private let settingsController: any CmxIrohSettingsControlling
    private var observationID: UUID?

    init(
        configuration: Configuration,
        settingsController: any CmxIrohSettingsControlling,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.settingsController = settingsController
        self.fileManager = fileManager
    }

    func run(store: CMUXMobileShellStore) async {
        try? fileManager.removeItem(at: configuration.reportURL)
        let report = await boundedReport(store: store)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(
                to: configuration.reportURL,
                options: .atomic
            )
            Self.postReportReadyNotification()
            mobileIrohReleaseGateLog.info(
                "release gate completed passed=\(report.passed, privacy: .public)"
            )
        } catch {
            mobileIrohReleaseGateLog.error("release gate report write failed")
        }
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
            let deadlineTask = Task {
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                continuation.yield(Self.failureReport(mode: mode, failure: .timeout))
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
        return Self.failureReport(mode: mode, failure: .unknownProbeFailure)
    }

    private func execute(store: CMUXMobileShellStore) async -> Report {
        let readiness = readinessUpdates(for: store)
        for await state in readiness {
            mobileIrohReleaseGateLog.info(
                "readiness signedIn=\(state.isSignedIn, privacy: .public) connected=\(state.isConnected, privacy: .public) iroh=\(state.usesIroh, privacy: .public) workspace=\(state.hasWorkspaceMutation, privacy: .public) terminal=\(state.hasTerminal, privacy: .public)"
            )
            guard !Task.isCancelled else {
                return Self.failureReport(mode: configuration.mode, failure: .timeout)
            }
            if state.isReady { break }
        }
        guard !Task.isCancelled else {
            return Self.failureReport(mode: configuration.mode, failure: .timeout)
        }

        let marker = "CMUX_IROH_GATE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let probe: MobileIrohReleaseGateProbeResult
        do {
            probe = try await store.runIrohReleaseGateProbe(marker: marker)
        } catch let failure as MobileIrohReleaseGateProbeFailure {
            return Self.probeFailureReport(
                mode: configuration.mode,
                failure: failure
            )
        } catch {
            return Self.failureReport(
                mode: configuration.mode,
                failure: .unknownProbeFailure
            )
        }

        let snapshots = settingsController.irohSettingsUpdates()
        for await snapshot in snapshots {
            guard !Task.isCancelled else {
                return Self.failureReport(mode: configuration.mode, failure: .timeout)
            }
            if let selectedPath = Self.acceptedPath(
                snapshot.selectedTransportPath,
                mode: configuration.mode
            ) {
                observationID = nil
                return Report(
                    schemaVersion: 2,
                    mode: configuration.mode.rawValue,
                    passed: probe.hostStatusVerified
                        && probe.terminalRoundTripVerified
                        && probe.workspaceMutationVerified
                        && probe.independentEventsVerified
                        && probe.notificationReconcileVerified
                        && probe.chatSessionsVerified
                        && probe.artifactScanCountVerified,
                    hostStatusVerified: probe.hostStatusVerified,
                    terminalRoundTripVerified: probe.terminalRoundTripVerified,
                    workspaceMutationVerified: probe.workspaceMutationVerified,
                    independentEventsVerified: probe.independentEventsVerified,
                    notificationReconcileVerified: probe.notificationReconcileVerified,
                    chatSessionsVerified: probe.chatSessionsVerified,
                    artifactScanCountVerified: probe.artifactScanCountVerified,
                    routeKind: CmxAttachTransportKind.iroh.rawValue,
                    selectedPath: selectedPath,
                    failure: nil
                )
            }
        }
        return Self.failureReport(
            mode: configuration.mode,
            failure: .pathPolicyMismatch
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
        failure: MobileIrohReleaseGateProbeFailure
    ) -> Report {
        Report(
            schemaVersion: 2,
            mode: mode.rawValue,
            passed: false,
            hostStatusVerified: false,
            terminalRoundTripVerified: false,
            workspaceMutationVerified: false,
            independentEventsVerified: false,
            notificationReconcileVerified: false,
            chatSessionsVerified: false,
            artifactScanCountVerified: false,
            routeKind: nil,
            selectedPath: nil,
            failure: failure.rawValue
        )
    }

    private nonisolated static func failureReport(
        mode: CmxIrohTransportVerificationMode,
        failure: Failure
    ) -> Report {
        Report(
            schemaVersion: 2,
            mode: mode.rawValue,
            passed: false,
            hostStatusVerified: false,
            terminalRoundTripVerified: false,
            workspaceMutationVerified: false,
            independentEventsVerified: false,
            notificationReconcileVerified: false,
            chatSessionsVerified: false,
            artifactScanCountVerified: false,
            routeKind: nil,
            selectedPath: nil,
            failure: failure.rawValue
        )
    }
}
#endif
