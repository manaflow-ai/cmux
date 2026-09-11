public import CMUXMobileCore
public import CmuxIrohTransport
public import CmuxIrxTransport
public import CmuxMobileShell
import Foundation

/// Failure reasons for an irx-backed forget, surfaced so the shell keeps the
/// local row instead of claiming a revoke that never reached the server.
public enum MobileIrxForgetError: Error, Equatable {
    case notAuthenticated
    case accountMismatch
    case discoveryUnavailable
}

/// Projects the active v2 directory for the Computers picker and server-authorized forget.
@MainActor
public final class MobileIrxDiscoveryProvider: MobileIrohMacDiscovering,
    MobileIrohMacForgetting
{
    /// Exposed so the scene injects the SAME catalog the provider fills as
    /// `personalIrohRouteCatalog` (known-Mac route lookups read it).
    public let routeCatalog = MobileIrohRouteCatalog()

    private let preferredTag: String
    private let compatibilityPolicy: MobileMacBuildCompatibilityPolicy?
    private let discover: @Sendable () async -> V2Directory?
    private let invalidateSnapshot: @Sendable () async -> Void
    private let revokeBinding: @Sendable (String) async throws -> Void
    private let authenticatedAccountID: @Sendable () async -> String?
    private let authenticatedScopeID: @Sendable () async -> String?
    private var scope: UInt64 = 0
    private var runtimeObservation: Task<Void, Never>?
    private var observedScope: String?
    private var observedDirectory: V2Directory?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    deinit { runtimeObservation?.cancel() }

    public func directoryUpdates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers.removeValue(forKey: id) }
        }
        return stream
    }

    private func observe(_ irx: MobileIrxRuntimeComposition) {
        runtimeObservation = Task { [weak self] in
            for await _ in await irx.changes() {
                guard let self, !Task.isCancelled else { return }
                let owner = await irx.directoryScopeID()
                let directory = await irx.currentDirectory()
                guard owner == (await irx.directoryScopeID()) else { continue }
                guard owner != observedScope || directory != observedDirectory else { continue }
                observedScope = owner
                observedDirectory = directory
                scope &+= 1
                let generation = scope
                await routeCatalog.activate(scope: generation)
                if let directory { await routeCatalog.replace(with: directory, scope: generation) }
                for observer in observers.values { observer.yield(()) }
            }
        }
    }

    /// Closure-injected core, so tests can drive it without the actor stack.
    public init(
        preferredTag: String,
        compatibilityPolicy: MobileMacBuildCompatibilityPolicy?,
        discover: @escaping @Sendable () async -> V2Directory?,
        invalidateSnapshot: @escaping @Sendable () async -> Void,
        revokeBinding: @escaping @Sendable (String) async throws -> Void,
        authenticatedAccountID: @escaping @Sendable () async -> String?,
        authenticatedScopeID: (@Sendable () async -> String?)? = nil
    ) {
        self.preferredTag = preferredTag
        self.compatibilityPolicy = compatibilityPolicy
        self.discover = discover
        self.invalidateSnapshot = invalidateSnapshot
        self.revokeBinding = revokeBinding
        self.authenticatedAccountID = authenticatedAccountID
        self.authenticatedScopeID = authenticatedScopeID ?? authenticatedAccountID
    }

    public convenience init(
        irx: MobileIrxRuntimeComposition,
        preferredTag: String,
        compatibilityPolicy: MobileMacBuildCompatibilityPolicy?
    ) {
        self.init(
            preferredTag: preferredTag,
            compatibilityPolicy: compatibilityPolicy,
            discover: { await irx.freshLiveDiscovery() },
            invalidateSnapshot: { await irx.invalidateDiscoverySnapshot() },
            revokeBinding: { try await irx.revokeBinding($0) },
            authenticatedAccountID: { await irx.authenticatedAccountID() },
            authenticatedScopeID: { await irx.directoryScopeID() }
        )
        observe(irx)
    }

    // MARK: - MobileIrohMacDiscovering

    public func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        let owner = await authenticatedScopeID()
        guard let discovery = await discover(), owner == (await authenticatedScopeID()) else { return [] }
        scope &+= 1
        let currentScope = scope
        await routeCatalog.activate(scope: currentScope)
        await routeCatalog.replace(with: discovery, scope: currentScope)
        return await routeCatalog.liveMacCandidates(
            preferredTag: preferredTag,
            compatibleWith: compatibilityPolicy,
            limit: nil
        )
    }

    public func invalidateDiscovery(forMacDeviceID deviceID: String) async {
        _ = deviceID
        await invalidateSnapshot()
    }

    // MARK: - MobileIrohMacForgetting

    public func forgetComputer(
        macDeviceID: String,
        instanceTag: String?,
        expectedAccountID: String
    ) async throws {
        guard let account = await authenticatedAccountID() else {
            throw MobileIrxForgetError.notAuthenticated
        }
        guard account == expectedAccountID else {
            throw MobileIrxForgetError.accountMismatch
        }
        let owner = await authenticatedScopeID()
        guard let discovery = await discover(), owner == (await authenticatedScopeID()) else {
            throw MobileIrxForgetError.discoveryUnavailable
        }
        let canonicalDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let wantedTag = instanceTag.map {
            CmxMacAppInstanceIdentity(
                macDeviceID: macDeviceID, instanceTag: $0
            ).instanceTag ?? ""
        }
        let matches = discovery.devices.filter { binding in
            cmxCanonicalDeviceID(binding.descriptor.identity.deviceID) == canonicalDeviceID
                && (wantedTag == nil || binding.descriptor.identity.buildTag == wantedTag)
        }
        for binding in matches {
            // Re-verify before each revoke: an account switch landing
            // mid-operation must never revoke another account's binding.
            guard await authenticatedAccountID() == expectedAccountID, owner == (await authenticatedScopeID()) else {
                throw MobileIrxForgetError.accountMismatch
            }
            try await revokeBinding(binding.deviceRecordID)
        }
    }
}
