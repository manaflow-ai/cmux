public import CMUXMobileCore
public import Foundation

/// Adapts the active v2 runtime and the app-owned diagnostic log for Settings.
@MainActor
public final class MobileIrxSettingsController: CmxIrohSettingsControlling {
    private let irx: MobileIrxRuntimeComposition
    private let diagnosticLog: DiagnosticLog

    public init(
        irx: MobileIrxRuntimeComposition,
        diagnosticLog: DiagnosticLog
    ) {
        self.irx = irx
        self.diagnosticLog = diagnosticLog
    }

    public func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        await irx.settingsSnapshot()
    }

    public func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        let (stream, continuation) = AsyncStream<CmxIrohSettingsSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let irxTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let changes = await irx.settingsUpdates()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                continuation.yield(await irohSettingsSnapshot())
            }
        }
        continuation.onTermination = { @Sendable _ in irxTask.cancel() }
        return stream
    }

    public func setIrohRelayPreference(
        _ preference: CmxIrohRelayPreferenceDraft
    ) async throws {
        guard case .automatic = preference else {
            throw CmxIrohSettingsControlError.unsupported
        }
    }

    public func setIrohPathPreference(
        _ preference: CmxIrohPathPreference
    ) async throws {
        let active: CmxIrohPathPreference = irx.forceRelayOnly
            ? .relayOnly : .automatic
        guard preference == active else {
            throw CmxIrohSettingsControlError.unsupported
        }
    }

    public func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    public func removeIrohCustomRelay(id: String) async throws {
        throw CmxIrohSettingsControlError.unsupported
    }

    public func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult {
        .incomplete
    }

    public func upsertIrohCustomPrivatePath(
        _ path: CmxIrohCustomPrivatePathDraft
    ) async throws {
        try await irx.upsertCustomPrivatePath(path)
    }

    public func removeIrohCustomPrivatePath(
        macDeviceID: String,
        instanceTag: String?
    ) async throws {
        try await irx.removeCustomPrivatePath(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }

    public func resetIrohSettingsToDefaults() async throws {
        let snapshot = await irohSettingsSnapshot()
        for path in snapshot.customPrivateNetworks where path.isEnabled {
            try await upsertIrohCustomPrivatePath(.init(
                macDeviceID: path.macDeviceID,
                instanceTag: path.instanceTag,
                macDisplayName: path.macDisplayName,
                addresses: path.addresses,
                isEnabled: false
            ))
        }
    }

    public func refreshIrohSettings() async {
        await irx.refreshSettingsSnapshot()
    }

    public func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: await irohSettingsSnapshot(),
            diagnostics: await diagnosticLog.snapshot(),
            relayReachability: .unavailable,
            macDiscovery: .unavailable
        )
    }

    public func irohDiagnosticReport() async -> DiagnosticReport {
        await diagnosticLog.snapshot()
    }

    public func exportIrohDiagnosticReport() async -> Data {
        await diagnosticLog.export()
    }

    public func clearIrohDiagnosticReport() async {
        await diagnosticLog.clear()
    }

    public func irohPreviousLaunchDiagnosticReport() async -> DiagnosticReport? {
        nil
    }
}
