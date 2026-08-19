import CMUXMobileCore
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation

// Custom relays and custom private paths are DEFERRED in the peer-transport
// composition (v3): the snapshot returns empty collections so the Settings UI
// renders those rows inert, and the mutation entrypoints fail with the same
// SettingsError family the previous composition used. The relay Automatic
// preference and the device-local path preference keep working.
extension MobilePeerRuntimeComposition: CmxIrohSettingsControlling {
    public func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let selectedPath = await selectedTransportPath()
        let liveMacs = await routeCatalog.liveMacCandidates(preferredTag: tag)
        var privateNetworkMacsByID: [String: CmxIrohSettingsSnapshot.PrivateNetworkMac] = [:]
        for mac in liveMacs {
            let id = cmxCanonicalDeviceID(mac.deviceID)
            if privateNetworkMacsByID[id] == nil {
                privateNetworkMacsByID[id] = .init(
                    id: id,
                    displayName: mac.displayName ?? "",
                    supportsPrivatePaths: mac.capabilities.contains(
                        "iroh.private_paths.v1"
                    )
                )
            }
        }
        #if DEBUG
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? =
            debugDefaults == nil ? nil : transportVerificationMode
        #else
        let debugTransportVerificationMode: CmxIrohTransportVerificationMode? = nil
        #endif
        let policy = activation?.policy ?? .unavailable
        let connectedRelayURLs = Set(
            await endpointManager.homeRelayStatus().connectedRelayURLs
        )
        return CmxIrohSettingsSnapshot(
            runtimeStatus: settingsRuntimeStatus(selectedPath: selectedPath),
            selectedTransportPath: selectedPath,
            // Managed selections and custom relays are deferred: the active
            // preference is always the safe Automatic default.
            preference: .automatic,
            pathPreference: debugDefaults.map {
                CmxIrohPathPreference.stored(in: $0)
            } ?? .automatic,
            managedRelays: (activation?.managedRelayCatalog ?? []).map { relay in
                CmxIrohSettingsSnapshot.ManagedRelay(
                    id: relay.id,
                    provider: relay.provider,
                    region: relay.region,
                    url: relay.url,
                    isSelected: connectedRelayURLs.contains(relay.url)
                )
            },
            customRelays: [],
            privateNetworkMacs: privateNetworkMacsByID.values.sorted {
                if $0.displayName != $1.displayName {
                    return $0.displayName.localizedCaseInsensitiveCompare(
                        $1.displayName
                    ) == .orderedAscending
                }
                return $0.id < $1.id
            },
            customPrivateNetworks: [],
            policySource: settingsPolicySource(policy),
            policySequence: policy.sequence,
            policyExpiresAt: policy.expiresAt,
            staleRelayIDs: [],
            failureDescription: lastActivationFailureKind.map { String(describing: $0) },
            debugTransportVerificationMode: debugTransportVerificationMode
        )
    }

    public func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            irohSettingsContinuations[id] = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                continuation.yield(await self.irohSettingsSnapshot())
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.irohSettingsContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func setIrohRelayPreference(
        _ preference: CmxIrohRelayPreferenceDraft
    ) async throws {
        let validated = try preference.validated()
        switch validated {
        case .automatic:
            // Automatic is the only supported preference in v3; the relay
            // fleet already follows the broker-minted credential set.
            publishIrohSettingsUpdate()
        case .managed, .custom:
            // Managed selections and custom relays are deferred in v3.
            throw SettingsError.unavailable
        }
    }

    public func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        // Custom relays are deferred in v3.
        _ = relay
        _ = deviceSecret
        throw SettingsError.unavailable
    }

    public func removeIrohCustomRelay(id: String) async throws {
        // Custom relays are deferred in v3.
        _ = id
        throw SettingsError.missingCustomRelay
    }

    public func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult {
        // Custom relays are deferred in v3.
        _ = id
        return .incomplete
    }

    public func runIrohConnectionCheck() async -> CmxIrohConnectionCheckReport {
        await refreshIrohSettings()
        let snapshot = await irohSettingsSnapshot()
        let diagnostics = await irohDiagnosticReport()
        let relayReachability: CmxIrohConnectionCheckReport.RelayReachability
        if transportVerificationMode == .directOnly {
            // Relays are administratively excluded by the transport mode; a
            // failed relay probe here must not send users to corporate IT.
            relayReachability = .notConfigured
        } else if activation?.relayURLs.isEmpty == false {
            relayReachability = await endpointManager.homeRelayStatus().isConnected
                ? .reachable
                : .unavailable
        } else {
            relayReachability = .notConfigured
        }
        let macDiscovery: CmxIrohConnectionCheckReport.MacDiscovery =
            await routeCatalog.liveMacCandidates(preferredTag: tag).isEmpty
                ? .missing
                : .found
        return CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: snapshot,
            diagnostics: diagnostics,
            relayReachability: relayReachability,
            macDiscovery: macDiscovery
        )
    }

    public func upsertIrohCustomPrivatePath(
        _ path: CmxIrohCustomPrivatePathDraft
    ) async throws {
        // Custom private paths are deferred in v3.
        _ = path
        throw SettingsError.unavailableCustomPrivatePath
    }

    public func removeIrohCustomPrivatePath(
        macDeviceID: String
    ) async throws {
        // Custom private paths are deferred in v3.
        _ = macDeviceID
        throw SettingsError.unavailableCustomPrivatePath
    }

    /// Re-mints the endpoint-bound relay credentials on demand and applies
    /// them make-before-break, replacing the previous signed-catalog refresh.
    public func refreshIrohSettings() async {
        guard let activation, let accountBroker else {
            publishIrohSettingsUpdate()
            return
        }
        guard transportVerificationMode != .directOnly else {
            publishIrohSettingsUpdate()
            return
        }
        diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshStarted))
        do {
            let fresh = try await accountBroker.relayToken(
                endpointID: activation.endpointID
            )
            var allowedRelayURLs: Set<String>?
            if let relayPolicyTrustRoot {
                let resolution = await relayPolicyCache.resolve(
                    trustRoot: relayPolicyTrustRoot,
                    now: now()
                )
                if case let .verified(policy) = resolution {
                    allowedRelayURLs = Set(policy.relays.map(\.url))
                }
            }
            let configs = MobilePeerEndpointActivator.relayConfigs(
                from: fresh,
                allowedRelayURLs: allowedRelayURLs
            )
            let stale = Set(activation.relayURLs).subtracting(configs.map(\.url))
            try await endpointManager.applyRelays(
                insert: configs,
                remove: Array(stale).sorted()
            )
            diagnosticLog?.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
        } catch {
            diagnosticLog?.record(DiagnosticEvent(
                .relayPolicyRefreshFailed,
                b: DiagnosticFailureKind.classify(error).rawValue
            ))
        }
        publishIrohSettingsUpdate()
    }

    public func irohDiagnosticReport() async -> DiagnosticReport {
        await diagnosticLog?.snapshot() ?? .empty
    }

    public func exportIrohDiagnosticReport() async -> Data {
        await diagnosticLog?.export() ?? Data()
    }

    public func clearIrohDiagnosticReport() async {
        await diagnosticLog?.clear()
        diagnosticArchive?.clear()
        previousLaunchDiagnosticReport = .some(nil)
        publishIrohSettingsUpdate()
    }

    public func irohPreviousLaunchDiagnosticReport() async -> DiagnosticReport? {
        if let cached = previousLaunchDiagnosticReport { return cached }
        let loaded = diagnosticArchive?.load()
        previousLaunchDiagnosticReport = .some(loaded)
        return loaded
    }

    public func setIrohPathPreference(
        _ preference: CmxIrohPathPreference
    ) async throws {
        guard let defaults = debugDefaults else { throw SettingsError.unavailable }
        defaults.set(
            preference.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #if DEBUG
        defaults.removeObject(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #endif
        await applyTransportVerificationMode(preference.transportVerificationMode)
        publishIrohSettingsUpdate()
    }

    // MARK: - Snapshot pieces

    func publishIrohSettingsUpdate() {
        guard !irohSettingsContinuations.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.irohSettingsSnapshot()
            for continuation in self.irohSettingsContinuations.values {
                continuation.yield(snapshot)
            }
        }
    }

    /// Redacted selected-path attribution from the newest live peer session.
    private func selectedTransportPath() async -> CmxIrohSelectedTransportPath {
        guard let box = sessionsByEndpointID.values.first else {
            return .unavailable
        }
        let diagnostics = box.session.routeDiagnostics()
        switch diagnostics.routeClass {
        case .direct:
            return .direct
        case .relay:
            let selectedRelay = diagnostics.paths.first { $0.isRelay && $0.isSelected }
            let info = activation?.managedRelayCatalog.first {
                selectedRelay?.remoteAddress.contains($0.url) == true
            }
            return .managedRelay(
                provider: info?.provider ?? "",
                region: info?.region ?? ""
            )
        case .unknown:
            return .unavailable
        }
    }

    private func settingsRuntimeStatus(
        selectedPath: CmxIrohSelectedTransportPath
    ) -> CmxIrohSettingsSnapshot.RuntimeStatus {
        switch supervisorState {
        case .idle:
            return .inactive
        case .connecting:
            return .starting
        case .ready:
            return CmxIrohSettingsSnapshot.RuntimeStatus(activePath: selectedPath)
        case .reconnecting, .waitingToRetry, .denied:
            return .degraded
        }
    }

    private func settingsPolicySource(
        _ policy: MobilePeerRelayPolicyState
    ) -> CmxIrohSettingsSnapshot.PolicySource {
        switch policy.source {
        case .server: return .server
        case .cached: return .cached
        case .unavailable: return .unavailable
        }
    }
}

#if DEBUG
extension MobilePeerRuntimeComposition: CmxIrohDebugSettingsControlling {
    public func setIrohDebugTransportVerificationMode(
        _ mode: CmxIrohTransportVerificationMode
    ) async throws {
        guard transportVerificationMode != mode else { return }
        guard let debugDefaults else { throw SettingsError.unavailable }
        debugDefaults.set(
            mode.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        // One endpoint rebind without identity rotation: the supervisor
        // replaces the endpoint runtime and the next activation reads the mode.
        await applyTransportVerificationMode(mode)
    }
}
#endif
