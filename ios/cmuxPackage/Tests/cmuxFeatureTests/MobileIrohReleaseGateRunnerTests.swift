#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileShell
import CmuxMobileShellReleaseGateSupport
import Foundation
import Testing
@testable import CmuxIrohReleaseGateSupport

@MainActor
struct MobileIrohReleaseGateRunnerTests {
    @Test
    func taskRestartReusesOneRunAndOneReportWrite() async throws {
        let configuration = try temporaryConfiguration(mode: .relayOnly)
        let probeStarted = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let releaseProbe = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        var probeCalls = 0
        var reportWrites = 0
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            dependencies: .init(
                readinessUpdates: { _ in Self.readyReadinessUpdates() },
                runProbe: { _, _ in
                    probeCalls += 1
                    probeStarted.continuation.yield()
                    var iterator = releaseProbe.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    return Self.successfulProbe
                },
                settingsUpdates: { Self.finishedSettingsUpdates() },
                writeReport: { report, url in
                    reportWrites += 1
                    try Self.write(report: report, to: url)
                },
                postReportReady: {},
                timeout: .seconds(1)
            )
        )
        let store = CMUXMobileShellStore.preview()

        let firstCaller = Task { @MainActor in
            await runner.run(store: store)
        }
        var probeStartedIterator = probeStarted.stream.makeAsyncIterator()
        _ = await probeStartedIterator.next()
        firstCaller.cancel()

        let restartedCaller = Task { @MainActor in
            await runner.run(store: store)
        }
        releaseProbe.continuation.yield()
        releaseProbe.continuation.finish()
        await firstCaller.value
        await restartedCaller.value

        #expect(probeCalls == 1)
        #expect(reportWrites == 1)
        #expect(FileManager.default.fileExists(atPath: configuration.reportURL.path))
    }

    @Test
    func readinessCompletionBeforeReadyFailsWithoutProbing() async throws {
        let configuration = try temporaryConfiguration(mode: .automatic)
        var probeCalls = 0
        var capturedReport: MobileIrohReleaseGateRunner.Report?
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            dependencies: .init(
                readinessUpdates: { _ in Self.finishedReadinessUpdates() },
                runProbe: { _, _ in
                    probeCalls += 1
                    return Self.successfulProbe
                },
                settingsUpdates: { Self.finishedSettingsUpdates() },
                writeReport: { report, url in
                    capturedReport = report
                    try Self.write(report: report, to: url)
                },
                postReportReady: {},
                timeout: .seconds(1)
            )
        )

        await runner.run(store: CMUXMobileShellStore.preview())

        #expect(probeCalls == 0)
        #expect(capturedReport?.passed == false)
        #expect(capturedReport?.failure == "readiness_unavailable")
    }

    @Test(arguments: [
        (
            MobileIrohReleaseGateRunner.Readiness(
                isSignedIn: false,
                isConnected: false,
                usesIroh: false,
                hasWorkspaceMutation: false,
                hasTerminal: false
            ),
            "not_signed_in"
        ),
        (
            MobileIrohReleaseGateRunner.Readiness(
                isSignedIn: true,
                isConnected: false,
                usesIroh: false,
                hasWorkspaceMutation: false,
                hasTerminal: false
            ),
            "not_connected"
        ),
        (
            MobileIrohReleaseGateRunner.Readiness(
                isSignedIn: true,
                isConnected: true,
                usesIroh: false,
                hasWorkspaceMutation: false,
                hasTerminal: false
            ),
            "non_iroh_route"
        ),
        (
            MobileIrohReleaseGateRunner.Readiness(
                isSignedIn: true,
                isConnected: true,
                usesIroh: true,
                hasWorkspaceMutation: false,
                hasTerminal: false
            ),
            "workspace_unavailable"
        ),
        (
            MobileIrohReleaseGateRunner.Readiness(
                isSignedIn: true,
                isConnected: true,
                usesIroh: true,
                hasWorkspaceMutation: true,
                hasTerminal: false
            ),
            "terminal_unavailable"
        ),
    ])
    func readinessTimeoutClassifiesLastObservedState(
        readiness: MobileIrohReleaseGateRunner.Readiness,
        expectedFailure: String
    ) async throws {
        let configuration = try temporaryConfiguration(mode: .automatic)
        var capturedReport: MobileIrohReleaseGateRunner.Report?
        let updates = AsyncStream<MobileIrohReleaseGateRunner.Readiness>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            dependencies: .init(
                readinessUpdates: { _ in updates.stream },
                runProbe: { _, _ in Self.successfulProbe },
                settingsUpdates: { Self.finishedSettingsUpdates() },
                writeReport: { report, url in
                    capturedReport = report
                    try Self.write(report: report, to: url)
                },
                postReportReady: {},
                timeout: .milliseconds(20)
            )
        )

        updates.continuation.yield(readiness)
        await runner.run(store: CMUXMobileShellStore.preview())
        updates.continuation.finish()

        #expect(capturedReport?.failure == expectedFailure)
    }

    @Test
    func probeRequiresTwoReadyObservationsBeforeRunning() async throws {
        let configuration = try temporaryConfiguration(mode: .automatic)
        var readinessPasses = 0
        var probeCalls = 0
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            dependencies: .init(
                readinessUpdates: { _ in
                    readinessPasses += 1
                    return Self.readyReadinessUpdates()
                },
                runProbe: { _, _ in
                    probeCalls += 1
                    return Self.successfulProbe
                },
                settingsUpdates: { Self.managedRelaySettingsUpdates() },
                writeReport: { report, url in
                    try Self.write(report: report, to: url)
                },
                postReportReady: {},
                timeout: .seconds(1)
            )
        )

        await runner.run(store: CMUXMobileShellStore.preview())

        #expect(readinessPasses == 2)
        #expect(probeCalls == 1)
    }

    @Test
    func probeFailureReportsTheBoundedFailureCase() async throws {
        let configuration = try temporaryConfiguration(mode: .relayOnly)
        var capturedReport: MobileIrohReleaseGateRunner.Report?
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            dependencies: .init(
                readinessUpdates: { _ in Self.readyReadinessUpdates() },
                runProbe: { _, _ in
                    throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
                },
                settingsUpdates: { Self.managedRelaySettingsUpdates() },
                writeReport: { report, url in
                    capturedReport = report
                    try Self.write(report: report, to: url)
                },
                postReportReady: {},
                timeout: .seconds(1)
            )
        )

        await runner.run(store: CMUXMobileShellStore.preview())

        let report = try #require(capturedReport)
        #expect(report.passed == false)
        #expect(report.routeKind == CmxAttachTransportKind.iroh.rawValue)
        #expect(report.selectedPath == nil)
        #expect(report.failure == MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed.rawValue)
    }

    @Test
    func pathMismatchPreservesCompletedProbeProofs() async throws {
        let report = try await runLatePathFailure(
            settingsUpdates: Self.finishedSettingsUpdates(),
            timeout: .seconds(1)
        )

        expectCompletedProbeProofs(in: report)
        #expect(report.failure == "path_policy_mismatch")
    }

    @Test
    func pathTimeoutPreservesCompletedProbeProofs() async throws {
        let pendingSettings = AsyncStream<CmxIrohSettingsSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let report = try await runLatePathFailure(
            settingsUpdates: pendingSettings.stream,
            timeout: .milliseconds(20)
        )
        pendingSettings.continuation.finish()

        expectCompletedProbeProofs(in: report)
        #expect(report.failure == "timeout")
    }

    @Test
    func configurationRequiresAnExplicitSupportedMode() throws {
        let cache = URL(fileURLWithPath: "/tmp/iroh-gate-tests", isDirectory: true)

        #expect(MobileIrohReleaseGateRunner.Configuration(
            environment: [:],
            cachesDirectory: cache
        ) == nil)
        #expect(MobileIrohReleaseGateRunner.Configuration(
            environment: ["CMUX_IROH_RELEASE_GATE_MODE": "unsupported"],
            cachesDirectory: cache
        ) == nil)

        let configuration = try #require(MobileIrohReleaseGateRunner.Configuration(
            environment: ["CMUX_IROH_RELEASE_GATE_MODE": "relayOnly"],
            cachesDirectory: cache
        ))
        #expect(configuration.mode == .relayOnly)
        #expect(configuration.reportURL.lastPathComponent == "cmux-iroh-release-gate.json")
    }

    @Test(arguments: [
        (CmxIrohTransportVerificationMode.automatic, CmxIrohSelectedTransportPath.direct, "direct"),
        (.automatic, .privateNetwork, "private_network"),
        (.automatic, .managedRelay(provider: "provider", region: "region"), "managed_relay"),
        (.relayOnly, .managedRelay(provider: "provider", region: "region"), "managed_relay"),
        (.relayOnly, .customRelay(displayName: "name", provider: "provider", region: "region"), "custom_relay"),
        (.directOnly, .direct, "direct"),
        (.directOnly, .privateNetwork, "private_network"),
    ])
    func acceptedPathsAreRedacted(
        mode: CmxIrohTransportVerificationMode,
        path: CmxIrohSelectedTransportPath,
        expected: String
    ) {
        #expect(MobileIrohReleaseGateRunner.acceptedPath(path, mode: mode) == expected)
        #expect(!expected.contains("provider"))
        #expect(!expected.contains("region"))
        #expect(!expected.contains("name"))
    }

    @Test(arguments: [
        (CmxIrohTransportVerificationMode.relayOnly, CmxIrohSelectedTransportPath.direct),
        (.relayOnly, .privateNetwork),
        (.directOnly, .managedRelay(provider: "provider", region: "region")),
        (.directOnly, .customRelay(displayName: "name", provider: "provider", region: "region")),
        (.automatic, .unavailable),
        (.relayOnly, .unavailable),
        (.directOnly, .unavailable),
    ])
    func incompatibleOrUnavailablePathsFail(
        mode: CmxIrohTransportVerificationMode,
        path: CmxIrohSelectedTransportPath
    ) {
        #expect(MobileIrohReleaseGateRunner.acceptedPath(path, mode: mode) == nil)
    }

    @Test
    func encodedReportContainsNoTopologyOrIdentityFields() throws {
        let report = MobileIrohReleaseGateRunner.Report(
            schemaVersion: 5,
            mode: "relayOnly",
            passed: true,
            hostStatusVerified: true,
            rpcMethodInventoryVerified: true,
            terminalRoundTripVerified: true,
            workspaceMutationVerified: true,
            independentEventsVerified: true,
            notificationReconcileVerified: true,
            chatSessionsVerified: true,
            artifactScanCountVerified: true,
            routeKind: "iroh",
            selectedPath: "managed_relay",
            failure: nil,
            lastDiagnosticEventCode: DiagnosticEventCode.discoveryFailed.rawValue,
            lastDiagnosticFailureKind: DiagnosticFailureKind.policyUnavailable.rawValue
        )
        let encoded = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(Set(object.keys) == [
            "schemaVersion",
            "mode",
            "passed",
            "hostStatusVerified",
            "rpcMethodInventoryVerified",
            "terminalRoundTripVerified",
            "workspaceMutationVerified",
            "independentEventsVerified",
            "notificationReconcileVerified",
            "chatSessionsVerified",
            "artifactScanCountVerified",
            "routeKind",
            "selectedPath",
            "lastDiagnosticEventCode",
            "lastDiagnosticFailureKind",
        ])
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        #expect(!encodedString.contains("stream_id"))
        #expect(!encodedString.contains("workspace_id"))
        #expect(!encodedString.contains("session_id"))
        #expect(!encodedString.contains("\"artifacts\""))
    }

    @Test
    func disconnectedTimeoutCarriesOnlyStableDiagnosticTaxonomy() async throws {
        let configuration = try temporaryConfiguration(mode: .automatic)
        var capturedReport: MobileIrohReleaseGateRunner.Report?
        let updates = AsyncStream<MobileIrohReleaseGateRunner.Readiness>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let diagnostics = DiagnosticReport(events: [
            DiagnosticEvent(
                code: .discoveryFailed,
                tNanos: 1,
                b: DiagnosticFailureKind.policyUnavailable.rawValue
            ),
        ])
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            dependencies: .init(
                readinessUpdates: { _ in updates.stream },
                runProbe: { _, _ in Self.successfulProbe },
                settingsUpdates: { Self.finishedSettingsUpdates() },
                diagnosticReport: { diagnostics },
                writeReport: { report, url in
                    capturedReport = report
                    try Self.write(report: report, to: url)
                },
                postReportReady: {},
                timeout: .milliseconds(20)
            )
        )

        let runTask = Task { @MainActor in
            await runner.run(store: CMUXMobileShellStore.preview())
        }
        updates.continuation.yield(.init(
            isSignedIn: true,
            isConnected: false,
            usesIroh: false,
            hasWorkspaceMutation: false,
            hasTerminal: false
        ))
        await runTask.value

        #expect(capturedReport?.failure == "not_connected")
        #expect(capturedReport?.lastDiagnosticEventCode == DiagnosticEventCode.discoveryFailed.rawValue)
        #expect(capturedReport?.lastDiagnosticFailureKind == DiagnosticFailureKind.policyUnavailable.rawValue)
    }

    private static let successfulProbe = MobileIrohReleaseGateProbeResult(
        hostStatusVerified: true,
        rpcMethodInventoryVerified: true,
        terminalRoundTripVerified: true,
        workspaceMutationVerified: true,
        independentEventsVerified: true,
        notificationReconcileVerified: true,
        chatSessionsVerified: true,
        artifactScanCountVerified: true
    )

    private func temporaryConfiguration(
        mode: CmxIrohTransportVerificationMode
    ) throws -> MobileIrohReleaseGateRunner.Configuration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try #require(MobileIrohReleaseGateRunner.Configuration(
            environment: [
                MobileIrohReleaseGateRunner.Configuration.modeEnvironmentKey: mode.rawValue,
            ],
            cachesDirectory: directory
        ))
    }

    private func runLatePathFailure(
        settingsUpdates: AsyncStream<CmxIrohSettingsSnapshot>,
        timeout: Duration
    ) async throws -> MobileIrohReleaseGateRunner.Report {
        let configuration = try temporaryConfiguration(mode: .relayOnly)
        var capturedReport: MobileIrohReleaseGateRunner.Report?
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            dependencies: .init(
                readinessUpdates: { _ in Self.readyReadinessUpdates() },
                runProbe: { _, _ in Self.successfulProbe },
                settingsUpdates: { settingsUpdates },
                writeReport: { report, url in
                    capturedReport = report
                    try Self.write(report: report, to: url)
                },
                postReportReady: {},
                timeout: timeout
            )
        )

        await runner.run(store: CMUXMobileShellStore.preview())

        return try #require(capturedReport)
    }

    private func expectCompletedProbeProofs(
        in report: MobileIrohReleaseGateRunner.Report
    ) {
        #expect(report.passed == false)
        #expect(report.hostStatusVerified)
        #expect(report.rpcMethodInventoryVerified)
        #expect(report.terminalRoundTripVerified)
        #expect(report.workspaceMutationVerified)
        #expect(report.independentEventsVerified)
        #expect(report.notificationReconcileVerified)
        #expect(report.chatSessionsVerified)
        #expect(report.artifactScanCountVerified)
        #expect(report.routeKind == CmxAttachTransportKind.iroh.rawValue)
        #expect(report.selectedPath == nil)
    }

    private static func readyReadinessUpdates(
    ) -> AsyncStream<MobileIrohReleaseGateRunner.Readiness> {
        AsyncStream { continuation in
            continuation.yield(.init(
                isSignedIn: true,
                isConnected: true,
                usesIroh: true,
                hasWorkspaceMutation: true,
                hasTerminal: true
            ))
            continuation.finish()
        }
    }

    private static func finishedReadinessUpdates(
    ) -> AsyncStream<MobileIrohReleaseGateRunner.Readiness> {
        AsyncStream { $0.finish() }
    }

    private static func finishedSettingsUpdates(
    ) -> AsyncStream<CmxIrohSettingsSnapshot> {
        AsyncStream { $0.finish() }
    }

    private static func managedRelaySettingsUpdates(
    ) -> AsyncStream<CmxIrohSettingsSnapshot> {
        AsyncStream { continuation in
            continuation.yield(CmxIrohSettingsSnapshot(
                runtimeStatus: .relayed(provider: "redacted", region: "redacted"),
                selectedTransportPath: .managedRelay(
                    provider: "redacted",
                    region: "redacted"
                ),
                preference: .automatic,
                managedRelays: [],
                customRelays: [],
                policySource: .server
            ))
            continuation.finish()
        }
    }

    private static func write(
        report: MobileIrohReleaseGateRunner.Report,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
#endif
