public import CMUXMobileCore
public import CmuxIrohTransport
public import CmuxMobileShell
import Foundation

/// Failure reasons for an irx-backed forget, surfaced so the shell keeps the
/// local row instead of claiming a revoke that never reached the server.
public enum MobileIrxForgetError: Error, Equatable {
    case notAuthenticated
    case accountMismatch
    case discoveryUnavailable
}

/// Bridges first-pair Mac discovery and forget onto the ACTIVE irx runtime.
///
/// The Computers picker's zero-touch path talks to whatever the scene injects
/// as `personalIrohDiscovery`. When irx became the primary transport the
/// scene kept injecting the dormant legacy runtime, which answers every query
/// with "endpoint unavailable": a freshly installed phone (empty paired-Mac
/// store) therefore listed ZERO Macs while the live irx engine could see the
/// whole fleet (08-28 field incident). This provider implements the same two
/// capabilities on top of irx broker discovery, reusing the legacy route
/// catalog's binding-to-candidate mapping so pairability filtering, build
/// compatibility, ordering, and attach-route construction stay identical
/// between transports.
@MainActor
public final class MobileIrxDiscoveryProvider: MobileIrohMacDiscovering,
    MobileIrohMacForgetting
{
    /// Exposed so the scene injects the SAME catalog the provider fills as
    /// `personalIrohRouteCatalog` (known-Mac route lookups read it).
    public let routeCatalog = MobileIrohRouteCatalog()

    private let preferredTag: String
    private let compatibilityPolicy: MobileMacBuildCompatibilityPolicy?
    private let discover: @Sendable () async -> CmxIrohDiscoveryResponse?
    private let invalidateSnapshot: @Sendable () async -> Void
    private let revokeBinding: @Sendable (String) async throws -> Void
    private let authenticatedAccountID: @Sendable () async -> String?
    private var scope: UInt64 = 0

    /// Closure-injected core, so tests can drive it without the actor stack.
    public init(
        preferredTag: String,
        compatibilityPolicy: MobileMacBuildCompatibilityPolicy?,
        discover: @escaping @Sendable () async -> CmxIrohDiscoveryResponse?,
        invalidateSnapshot: @escaping @Sendable () async -> Void,
        revokeBinding: @escaping @Sendable (String) async throws -> Void,
        authenticatedAccountID: @escaping @Sendable () async -> String?
    ) {
        self.preferredTag = preferredTag
        self.compatibilityPolicy = compatibilityPolicy
        self.discover = discover
        self.invalidateSnapshot = invalidateSnapshot
        self.revokeBinding = revokeBinding
        self.authenticatedAccountID = authenticatedAccountID
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
            authenticatedAccountID: { await irx.authenticatedAccountID() }
        )
    }

    // MARK: - MobileIrohMacDiscovering

    public func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        scope &+= 1
        let currentScope = scope
        await routeCatalog.activate(scope: currentScope)
        guard let discovery = await discover() else { return [] }
        guard scope == currentScope else { return [] }
        await routeCatalog.replace(with: discovery, scope: currentScope)
        return await routeCatalog.liveMacCandidates(
            preferredTag: preferredTag,
            compatibleWith: compatibilityPolicy,
            limit: 4
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
        guard let discovery = await discover() else {
            throw MobileIrxForgetError.discoveryUnavailable
        }
        let canonicalDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let wantedTag = instanceTag.map {
            CmxMacAppInstanceIdentity(
                macDeviceID: macDeviceID, instanceTag: $0
            ).instanceTag ?? ""
        }
        let matches = discovery.bindings.filter { binding in
            cmxCanonicalDeviceID(binding.deviceID) == canonicalDeviceID
                && (wantedTag == nil || binding.tag == wantedTag)
        }
        for binding in matches {
            // Re-verify before each revoke: an account switch landing
            // mid-operation must never revoke another account's binding.
            guard await authenticatedAccountID() == expectedAccountID else {
                throw MobileIrxForgetError.accountMismatch
            }
            try await revokeBinding(binding.bindingID)
        }
    }
}
